import http.client
import json
import os
import re
import socket
import socketserver
import ssl
import subprocess
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler

SOCKET_PATH = os.environ.get("SHIM_SOCKET", "/run/docker-shim/docker.sock")
NAMESPACE = os.environ.get("VLLM_NAMESPACE", "vllm-openai")
ENGINES = json.loads(
    os.environ.get(
        "ENGINES",
        '[{"id": "vllm-openai", "selector": "app=vllm-openai", "container": "vllm-openai",'
        ' "upstream": "vllm-openai-svc.vllm-openai.svc.cluster.local:8000", "port": 8000}]',
    )
)
KUBE_API = os.environ.get("KUBE_API")
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
BY_ID = {e["id"]: e for e in ENGINES}


def upstream(engine):
    host, port = engine["upstream"].rsplit(":", 1)
    return host, int(port)


def kube_get(path, timeout):
    if KUBE_API:
        url = urllib.parse.urlsplit(KUBE_API)
        conn = http.client.HTTPConnection(url.hostname, url.port, timeout=timeout)
        headers = {}
    else:
        ctx = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt")
        conn = http.client.HTTPSConnection(
            "kubernetes.default.svc", 443, context=ctx, timeout=timeout
        )
        with open(f"{SA_DIR}/token") as f:
            headers = {"Authorization": f"Bearer {f.read().strip()}"}
    conn.request("GET", path, headers=headers)
    return conn, conn.getresponse()


def current_pod(engine):
    query = urllib.parse.urlencode({"labelSelector": engine["selector"]})
    conn, resp = kube_get(f"/api/v1/namespaces/{NAMESPACE}/pods?{query}", 10)
    try:
        if resp.status != 200:
            return None
        pods = json.load(resp)["items"]
    finally:
        conn.close()
    running = [
        p
        for p in pods
        if p["status"].get("phase") == "Running"
        and not p["metadata"].get("deletionTimestamp")
    ]

    def rank(p):
        ready = any(
            c["type"] == "Ready" and c["status"] == "True"
            for c in p["status"].get("conditions", [])
        )
        return (ready, p["metadata"]["creationTimestamp"])

    return max(running, key=rank, default=None)


def pinned_gpus(pod, engine):
    for c in pod["spec"]["containers"]:
        if c["name"] != engine["container"]:
            continue
        for e in c.get("env", []):
            if e["name"] == "NVIDIA_VISIBLE_DEVICES" and "value" in e:
                return {u.strip() for u in e["value"].split(",") if u.strip()}
    return set()


def gpu_pids(uuids):
    if not uuids:
        return []
    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-compute-apps=pid,gpu_uuid", "--format=csv,noheader"],
            capture_output=True, text=True, timeout=10,
        ).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    pids = []
    for line in out.splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) == 2 and parts[0].isdigit() and parts[1] in uuids:
            pids.append(parts[0])
    return pids


def model_root(engine):
    conn = http.client.HTTPConnection(*upstream(engine), timeout=5)
    try:
        conn.request("GET", "/v1/models")
        resp = conn.getresponse()
        if resp.status != 200:
            return None
        models = json.load(resp)["data"]
        return models[0].get("root") or models[0]["id"] if models else None
    except (OSError, ValueError, KeyError):
        return None
    finally:
        conn.close()


class DockerApi(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        parts = url.path.strip("/").split("/")
        if parts and re.fullmatch(r"v\d+\.\d+", parts[0]):
            parts = parts[1:]
        try:
            if parts == ["_ping"]:
                return self.send_body(200, b"OK", "text/plain")
            if parts == ["containers", "json"]:
                return self.list_containers()
            if len(parts) == 3 and parts[0] == "containers" and parts[1] in BY_ID:
                engine = BY_ID[parts[1]]
                if parts[2] == "top":
                    return self.top(engine)
                if parts[2] == "logs":
                    return self.stream_logs(engine, urllib.parse.parse_qs(url.query))
            self.send_json(404, {"message": "not found"})
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True
        except Exception as e:
            self.send_json(500, {"message": str(e)})

    def send_body(self, code, body, content_type):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, code, obj):
        self.send_body(code, json.dumps(obj).encode(), "application/json")

    def list_containers(self):
        containers = []
        for engine in ENGINES:
            pod = current_pod(engine)
            if pod is None:
                continue
            root = model_root(engine)
            containers.append(
                {
                    "Id": engine["id"],
                    "Names": [f"/{engine['id']}"],
                    "Image": "vllm",
                    "Command": f"vllm serve {root}" if root else "vllm serve",
                    "State": "running",
                    "Status": "Up",
                    "Ports": [
                        {
                            "IP": "127.0.0.1",
                            "PrivatePort": engine["port"],
                            "PublicPort": engine["port"],
                            "Type": "tcp",
                        }
                    ],
                    "Labels": {"io.kubernetes.pod.name": pod["metadata"]["name"]},
                }
            )
        self.send_json(200, containers)

    def top(self, engine):
        pod = current_pod(engine)
        pids = gpu_pids(pinned_gpus(pod, engine)) if pod else []
        self.send_json(
            200,
            {"Titles": ["PID", "COMMAND"], "Processes": [[p, "vllm serve"] for p in pids]},
        )

    def stream_logs(self, engine, query):
        pod = current_pod(engine)
        if pod is None:
            return self.send_json(404, {"message": f"no running {engine['id']} pod"})
        params = {"container": engine["container"]}
        if query.get("follow", ["false"])[0] in ("1", "true"):
            params["follow"] = "true"
        tail = query.get("tail", ["all"])[0]
        if tail.isdigit():
            params["tailLines"] = tail
        name = pod["metadata"]["name"]
        conn, resp = kube_get(
            f"/api/v1/namespaces/{NAMESPACE}/pods/{name}/log?{urllib.parse.urlencode(params)}",
            None,
        )
        try:
            if resp.status != 200:
                return self.send_json(resp.status, {"message": resp.read().decode()})
            self.send_response(200)
            self.send_header("Content-Type", "application/vnd.docker.multiplexed-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            while data := resp.read1(65536):
                frame = b"\x01\x00\x00\x00" + len(data).to_bytes(4, "big") + data
                self.wfile.write(b"%x\r\n%s\r\n" % (len(frame), frame))
            self.wfile.write(b"0\r\n\r\n")
        finally:
            conn.close()
            self.close_connection = True


class UnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def pipe(src, dst):
    try:
        while data := src.recv(65536):
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def proxy_handler(engine):
    class Proxy(socketserver.BaseRequestHandler):
        def handle(self):
            try:
                up = socket.create_connection(upstream(engine), 5)
            except OSError:
                return
            up.settimeout(None)
            with up:
                threading.Thread(target=pipe, args=(self.request, up), daemon=True).start()
                pipe(up, self.request)

    return Proxy


class ProxyServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    for engine in ENGINES:
        proxy = ProxyServer(("127.0.0.1", engine["port"]), proxy_handler(engine))
        threading.Thread(target=proxy.serve_forever, daemon=True).start()
        print(f"proxy 127.0.0.1:{engine['port']} -> {engine['upstream']} ({engine['id']})", flush=True)
    if os.path.exists(SOCKET_PATH):
        os.unlink(SOCKET_PATH)
    print(f"docker api on {SOCKET_PATH}", flush=True)
    UnixServer(SOCKET_PATH, DockerApi).serve_forever()
