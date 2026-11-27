import asyncio
import json
import urllib.error
import urllib.request

DAEMON_URL = "http://127.0.0.1:47620"


def _http_get(path: str, timeout: float = 2.5):
    with urllib.request.urlopen(f"{DAEMON_URL}{path}", timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _http_post(path: str, payload: dict, timeout: float = 3.5):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        f"{DAEMON_URL}{path}",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


class Plugin:
    async def _main(self):
        pass

    async def get_state(self):
        return await asyncio.to_thread(_http_get, "/api/state", 2.5)

    async def post_action(self, path: str, payload: dict):
        timeout = 6.0 if path == "/api/refresh" else 3.5
        return await asyncio.to_thread(_http_post, path, payload or {}, timeout)
