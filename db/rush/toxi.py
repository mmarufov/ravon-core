"""Minimal Toxiproxy client: one proxy, one latency toxic. Standard library only.

Toxiproxy (github.com/Shopify/toxiproxy) sits between the harness and
PostgreSQL. `set_latency(ms)` adds one `latency` toxic on the downstream stream
(database to client) with jitter 0, so every round trip gains exactly `ms`
once. `set_latency(0)` removes it; the 0 ms cells still go through the proxy.

    toxiproxy-server -host 127.0.0.1 -port 8474 &
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request


class Proxy:
    def __init__(self, api: str, name: str, listen: str, upstream: str):
        self.api, self.name, self.listen, self.upstream = api.rstrip("/"), name, listen, upstream
        self.latency_ms = 0

    def _req(self, method: str, path: str, body: dict | None = None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.api + path, data=data, method=method,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=10) as r:
            raw = r.read()
            return json.loads(raw) if raw else None

    def create(self) -> None:
        try:
            self._req("DELETE", f"/proxies/{self.name}")
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise
        self._req("POST", "/proxies", {"name": self.name, "listen": self.listen,
                                       "upstream": self.upstream, "enabled": True})

    def set_latency(self, ms: int) -> None:
        if self.latency_ms:
            self._req("DELETE", f"/proxies/{self.name}/toxics/latency_down")
            self.latency_ms = 0
        if ms:
            self._req("POST", f"/proxies/{self.name}/toxics",
                      {"name": "latency_down", "type": "latency", "stream": "downstream",
                       "toxicity": 1.0, "attributes": {"latency": ms, "jitter": 0}})
            self.latency_ms = ms

    def delete(self) -> None:
        self._req("DELETE", f"/proxies/{self.name}")
