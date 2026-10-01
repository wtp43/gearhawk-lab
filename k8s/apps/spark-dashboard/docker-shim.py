import http.client
import json
import os
import re
import socket
import socketserver
import ssl
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler

SOCKET_PATH = os.environ.get("SHIM_SOCKET", "/run/docker-shim/docker.sock")
NAMESPACE = os.environ.get("VLLM_NAMESPACE", "vllm-openai")
SELECTOR = os.environ.get("VLLM_SELECTOR", "app=vllm-openai")
CONTAINER = os.environ.get("VLLM_CONTAINER", "vllm-openai")
UPSTREAM_HOST, UPSTREAM_PORT = os.environ.get(
    "VLLM_UPSTREAM", "vllm-openai-svc.vllm-openai.svc.cluster.local:8000"
).rsplit(":", 1)
PROXY_PORT = int(os.environ.get("PROXY_PORT", "8000"))
KUBE_API = os.environ.get("KUBE_API")
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
CONTAINER_ID = "vllm-openai"


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


def current_pod():
    query = urllib.parse.urlencode({"labelSelector": SELECTOR})
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
            if parts == ["containers", CONTAINER_ID, "top"]:
                return self.send_json(200, {"Titles": ["PID", "CMD"], "Processes": []})
            if parts == ["containers", CONTAINER_ID, "logs"]:
                return self.stream_logs(urllib.parse.parse_qs(url.query))
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
        pod = current_pod()
        if pod is None:
            return self.send_json(200, [])
        self.send_json(
            200,
            [
                {
                    "Id": CONTAINER_ID,
                    "Names": [f"/{CONTAINER_ID}"],
                    "Image": "vllm",
                    "Command": "vllm serve",
                    "State": "running",
                    "Status": "Up",
                    "Ports": [
                        {
                            "IP": "127.0.0.1",
                            "PrivatePort": PROXY_PORT,
                            "PublicPort": PROXY_PORT,
                            "Type": "tcp",
                        }
                    ],
                    "Labels": {"io.kubernetes.pod.name": pod["metadata"]["name"]},
                }
            ],
        )

    def stream_logs(self, query):
        pod = current_pod()
        if pod is None:
            return self.send_json(404, {"message": "no running vllm pod"})
        params = {"container": CONTAINER}
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


class Proxy(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            upstream = socket.create_connection((UPSTREAM_HOST, int(UPSTREAM_PORT)), 5)
        except OSError:
            return
        upstream.settimeout(None)
        with upstream:
            threading.Thread(target=pipe, args=(self.request, upstream), daemon=True).start()
            pipe(upstream, self.request)


class ProxyServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    proxy = ProxyServer(("127.0.0.1", PROXY_PORT), Proxy)
    threading.Thread(target=proxy.serve_forever, daemon=True).start()
    if os.path.exists(SOCKET_PATH):
        os.unlink(SOCKET_PATH)
    print(f"docker api on {SOCKET_PATH}, proxy 127.0.0.1:{PROXY_PORT} -> {UPSTREAM_HOST}:{UPSTREAM_PORT}", flush=True)
    UnixServer(SOCKET_PATH, DockerApi).serve_forever()
