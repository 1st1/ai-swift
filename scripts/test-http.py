#!/usr/bin/env python3
"""Run Swift's real URLSession tests against a credential-free loopback server."""
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

release = threading.Event()
disconnected = threading.Event()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == "/release":
            release.set()
        body = json.dumps({"cancelled": disconnected.is_set()}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        assert self.path == "/v1/chat/completions"
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert body["stream"] is True
        if body["model"] == "http-error":
            self.send_response(401)
            self.end_headers()
            self.wfile.write(b'{"error":"fixture unauthorized"}')
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        def send(payload):
            self.wfile.write(f"data: {payload}\r\n\r\n".encode())
            self.wfile.flush()

        send(json.dumps({"choices": [{"index": 0, "delta": {"content": "early 🌍"}}]}))
        if body["model"] == "cancel":
            import select

            if select.select([self.connection], [], [], 10)[0]:
                if self.connection.recv(1) == b"":
                    disconnected.set()
            return
        if not release.wait(timeout=10):
            return  # A buffered client cannot release us: its test must fail.
        send(json.dumps({"choices": [{"index": 0, "delta": {"content": " late"}, "finish_reason": "stop"}]}))
        send('[DONE]')


if __name__ == "__main__":
    root = Path(__file__).resolve().parents[1]
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, AI_HTTP_FIXTURE_URL=f"http://127.0.0.1:{server.server_port}")
    try:
        result = subprocess.run(
            [env.get("SWIFT_EXECUTABLE", "swift"), "test", "--filter", "HTTPIntegration"]
            + sys.argv[1:],
            cwd=root, env=env, timeout=180,
        )
    finally:
        server.shutdown()
        server.server_close()
    raise SystemExit(result.returncode)
