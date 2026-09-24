"""Deterministic mock downstream API for the examples.

It stands in for the third-party service a workflow calls, and fails on
purpose so retry, backoff, dead-letter, and idempotency behavior can be
observed without real accounts. Standard library only.

POST /deliver
    Body: any JSON object. Optional "simulate" field:
      "ok"                   200 (default)
      "fail_times:N"         503 for the first N calls per Idempotency-Key, then 200
      "rate_limit_times:N"   429 with Retry-After: 2 for the first N calls, then 200
      "permanent"            422 on every call
      "slow:S"               sleep S seconds, then 200
    Header: Idempotency-Key. A key that was already delivered successfully
    returns 200 with "duplicate": true and is not counted as a new delivery.

GET  /tasks    Sample budget records for the delta-gate example.
               ?fail=1 returns 503 so the error branch can be exercised.
GET  /config/<name>
               Configuration lookups for the errors-as-data example:
                 mfa             200, enabled
                 logging         200, disabled
                 password_policy 404 NoSuchEntity (an expected, meaningful answer)
                 flaky           503 on the first call, 200 afterwards
                 broken          500 on every call
GET  /stats    Calls and successful deliveries per key.
POST /reset    Clears all counters.
GET  /health   Liveness check.
"""

import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TASKS = [
    {"id": "task-a", "name": "Onboarding flow", "budget_hours": 40, "time_spent_ms": 20 * 3_600_000},
    {"id": "task-b", "name": "Billing export", "budget_hours": 10, "time_spent_ms": 9 * 3_600_000},
    {"id": "task-c", "name": "Search rewrite", "budget_hours": 25, "time_spent_ms": 30 * 3_600_000},
    {"id": "task-d", "name": "No budget set", "budget_hours": 0, "time_spent_ms": 2 * 3_600_000},
]

_lock = threading.Lock()
_calls: dict[str, int] = {}
_delivered: dict[str, int] = {}


def _reset() -> None:
    with _lock:
        _calls.clear()
        _delivered.clear()


class Handler(BaseHTTPRequestHandler):
    server_version = "resilience-mock/1.0"

    def _send(self, status: int, body: dict, headers: dict | None = None) -> None:
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt: str, *args) -> None:  # quieter logs
        if os.environ.get("MOCK_API_LOG", "1") == "1":
            super().log_message(fmt, *args)

    def do_GET(self) -> None:
        path, _, query = self.path.partition("?")
        if path == "/tasks":
            if "fail=1" in query:
                self._send(503, {"error": "task source unavailable"})
            else:
                self._send(200, {"tasks": TASKS})
            return
        if path.startswith("/config/"):
            name = path.removeprefix("/config/")
            with _lock:
                _calls["config:" + name] = _calls.get("config:" + name, 0) + 1
                call_no = _calls["config:" + name]
            if name == "mfa":
                self._send(200, {"enabled": True})
            elif name == "logging":
                self._send(200, {"enabled": False})
            elif name == "password_policy":
                self._send(404, {"error": "NoSuchEntity", "message": "no password policy configured"})
            elif name == "flaky" and call_no == 1:
                self._send(503, {"error": "temporarily unavailable"})
            elif name == "flaky":
                self._send(200, {"enabled": True})
            elif name == "broken":
                self._send(500, {"error": "internal error"})
            else:
                self._send(404, {"error": "unknown config"})
            return
        if self.path == "/health":
            self._send(200, {"ok": True})
        elif self.path == "/stats":
            with _lock:
                self._send(200, {"calls": dict(_calls), "delivered": dict(_delivered)})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self) -> None:
        if self.path == "/reset":
            _reset()
            self._send(200, {"ok": True})
            return
        if self.path != "/deliver":
            self._send(404, {"error": "not found"})
            return

        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self._send(400, {"error": "body must be JSON"})
            return

        key = self.headers.get("Idempotency-Key") or "(none)"
        simulate = str(body.get("simulate", "ok")) if isinstance(body, dict) else "ok"

        with _lock:
            _calls[key] = _calls.get(key, 0) + 1
            call_no = _calls[key]
            already = _delivered.get(key, 0) > 0

        if already and key != "(none)":
            self._send(200, {"ok": True, "duplicate": True, "key": key})
            return

        mode, _, arg = simulate.partition(":")
        if mode == "fail_times" and call_no <= int(arg or 0):
            self._send(503, {"error": "temporarily unavailable", "call": call_no})
            return
        if mode == "rate_limit_times" and call_no <= int(arg or 0):
            self._send(429, {"error": "rate limited", "call": call_no}, {"Retry-After": "2"})
            return
        if mode == "permanent":
            self._send(422, {"error": "payload rejected by validation", "call": call_no})
            return
        if mode == "slow":
            time.sleep(float(arg or 1))

        with _lock:
            _delivered[key] = _delivered.get(key, 0) + 1
        self._send(200, {"ok": True, "duplicate": False, "key": key, "call": call_no})


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    print(f"mock API listening on :{port}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
