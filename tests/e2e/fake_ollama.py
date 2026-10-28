#!/usr/bin/env python3
"""Minimal fake of the Ollama HTTP API, for smoke-testing gpu-ai-check without a GPU.

Implements only what the tool calls: GET /api/version, GET /api/ps, POST /api/generate.
Response fields follow the Ollama API documentation (durations in nanoseconds).
It generates no real text and says nothing about real hardware or real Ollama behaviour.
"""
import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

MODEL = "fake-model"


class Handler(BaseHTTPRequestHandler):
    calls = 0
    drift = False
    vary = False

    def log_message(self, fmt, *args):  # keep test output quiet
        pass

    def _send(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/api/version":
            self._send(200, {"version": "0.0.0-fake"})
        elif self.path == "/api/ps":
            self._send(200, {"models": [{
                "name": MODEL + ":latest", "model": MODEL + ":latest",
                "size": 9500000000, "size_vram": 9500000000,
            }]})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/api/generate":
            self._send(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        req = json.loads(self.rfile.read(length).decode("utf-8"))
        name = req.get("model", "")
        if name.split(":")[0] != MODEL:
            self._send(404, {"error": "model '%s' not found" % name})
            return
        time.sleep(0.5)
        Handler.calls += 1
        n = Handler.calls
        tps = 33.0 - (0.5 * n if Handler.drift else 0.0)
        eval_count = 100
        eval_ns = int(eval_count / tps * 1e9)
        text = "fake output"
        if Handler.vary:
            text += " %d" % n
        self._send(200, {
            "model": name, "response": text, "done": True,
            "total_duration": eval_ns + 1000000, "load_duration": 1000000,
            "prompt_eval_count": 10, "prompt_eval_duration": 1000000,
            "eval_count": eval_count, "eval_duration": eval_ns,
        })


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--drift", action="store_true", help="tokens/s falls on every call")
    ap.add_argument("--vary", action="store_true", help="response text differs on every call")
    a = ap.parse_args()
    Handler.drift = a.drift
    Handler.vary = a.vary
    HTTPServer(("127.0.0.1", a.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
