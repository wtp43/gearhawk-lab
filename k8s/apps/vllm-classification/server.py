import asyncio
import base64
import io
import os
import time
from contextlib import asynccontextmanager
from typing import Any

import torch
from fastapi import FastAPI, HTTPException
from PIL import Image
from pydantic import BaseModel, Field
from transformers import AutoModel
from transformers.image_utils import load_image

MODEL = os.environ.get("MODEL", "LiquidAI/d1-3B")
REVISION = os.environ.get("MODEL_REVISION", "main")
MAX_BATCH = int(os.environ.get("MAX_BATCH", "64"))
BATCH_WAIT_MS = float(os.environ.get("BATCH_WAIT_MS", "5"))
MAX_IMAGES = int(os.environ.get("MAX_IMAGES", "8"))


class DecideRequest(BaseModel):
    state: Any = None
    questions: dict[str, dict[str, Any]]
    images: list[str] = Field(default_factory=list)


class BatchRequest(BaseModel):
    requests: list[DecideRequest]


def decode_image(src: str) -> Image.Image:
    if src.startswith("data:"):
        return Image.open(io.BytesIO(base64.b64decode(src.split(",", 1)[1]))).convert("RGB")
    if src.startswith(("http://", "https://")):
        return load_image(src)
    raise ValueError("images must be data: URIs or http(s) URLs")


def to_job(req: DecideRequest) -> tuple:
    if not req.questions:
        raise ValueError("questions is empty")
    if len(req.images) > MAX_IMAGES:
        raise ValueError(f"at most {MAX_IMAGES} images per request")
    if req.state is None and not req.images:
        raise ValueError("state is required when there are no images")
    return (req.state, req.questions, [decode_image(i) for i in req.images])


model = None
queue: asyncio.Queue = asyncio.Queue()
stats = {"batches": 0, "requests": 0}


def run_batch(jobs: list[tuple]) -> list[dict | Exception]:
    try:
        return model.system_one_batch(jobs)
    except Exception:
        out: list[dict | Exception] = []
        for job in jobs:
            try:
                out.append(model.system_one_batch([job])[0])
            except Exception as e:
                out.append(e)
        return out


async def batcher():
    loop = asyncio.get_running_loop()
    while True:
        items = [await queue.get()]
        deadline = loop.time() + BATCH_WAIT_MS / 1000
        while len(items) < MAX_BATCH:
            timeout = deadline - loop.time()
            if timeout <= 0:
                break
            try:
                items.append(await asyncio.wait_for(queue.get(), timeout))
            except asyncio.TimeoutError:
                break
        results = await asyncio.to_thread(run_batch, [job for job, _ in items])
        stats["batches"] += 1
        stats["requests"] += len(items)
        for (_, fut), res in zip(items, results):
            if fut.done():
                continue
            if isinstance(res, Exception):
                fut.set_exception(res)
            else:
                fut.set_result(res)


async def submit(job: tuple) -> dict:
    fut = asyncio.get_running_loop().create_future()
    await queue.put((job, fut))
    try:
        return await fut
    except (ValueError, KeyError, TypeError) as e:
        raise HTTPException(400, str(e))


@asynccontextmanager
async def lifespan(_: FastAPI):
    global model
    model = AutoModel.from_pretrained(
        MODEL, revision=REVISION, trust_remote_code=True, dtype=torch.bfloat16
    ).to("cuda")
    model.system_one("warm up", {"ok": {"type": "noul", "instructions": "Is this a test?"}})
    task = asyncio.create_task(batcher())
    yield
    task.cancel()


app = FastAPI(lifespan=lifespan)


@app.get("/health")
async def health():
    return {"status": "ok", "model": MODEL, "revision": REVISION, **stats}


@app.post("/v1/decide")
async def decide(req: DecideRequest):
    try:
        job = await asyncio.to_thread(to_job, req)
    except Exception as e:
        raise HTTPException(400, str(e))
    t = time.perf_counter()
    res = await submit(job)
    return {**res, "latency_ms": round((time.perf_counter() - t) * 1000, 2)}


@app.post("/v1/decide/batch")
async def decide_batch(req: BatchRequest):
    try:
        jobs = await asyncio.gather(*(asyncio.to_thread(to_job, r) for r in req.requests))
    except Exception as e:
        raise HTTPException(400, str(e))
    t = time.perf_counter()
    results = await asyncio.gather(*(submit(j) for j in jobs), return_exceptions=True)
    return {
        "results": [
            {"error": str(r.detail if isinstance(r, HTTPException) else r)} if isinstance(r, Exception) else r
            for r in results
        ],
        "latency_ms": round((time.perf_counter() - t) * 1000, 2),
    }
