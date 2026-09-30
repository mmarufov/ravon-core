"""Fixtures for the Temporal side of the comparison.

The ledger fixtures are not copied. They are loaded from db/ledger/tests/
conftest.py, so both implementations run against the same real PostgreSQL,
the same schema.sql, and the same TRUNCATE-between-tests reset.

On top of that this adds the three things the hand-built saga does not need:
a Temporal server, worker processes, and something that restarts a worker when
it dies.
"""

from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import signal
import socket
import subprocess
import sys
import time
from dataclasses import dataclass, field
from typing import Iterator
from uuid import uuid4

import psycopg
import pytest
from psycopg import sql

HERE = pathlib.Path(__file__).resolve().parents[1]
LEDGER_TESTS = HERE.parent / "ledger" / "tests"

_spec = importlib.util.spec_from_file_location("ledger_conftest", LEDGER_TESTS / "conftest.py")
ledger_conftest = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ledger_conftest)

# Re-exported so pytest registers them, and so `from conftest import
# reset_ledger` inside the hand-built test modules resolves when imported here.
admin_dsn = ledger_conftest.admin_dsn
ledger_db = ledger_conftest.ledger_db
conn = ledger_conftest.conn
ledger = ledger_conftest.ledger
admin_conn = ledger_conftest.admin_conn
reset_ledger = ledger_conftest.reset_ledger

import provider  # noqa: E402

TEMPORAL_PORT = int(os.environ.get("PAYOUT_TEMPORAL_PORT", "7239"))
PROVIDER_DB = "ravon_fake_provider_test"
RESULTS = os.environ.get("PAYOUT_RESULTS")      # compare.py collects evidence here


def _port_open(port: int) -> bool:
    with socket.socket() as s:
        s.settimeout(0.2)
        return s.connect_ex(("127.0.0.1", port)) == 0


@pytest.fixture(scope="session")
def temporal_address(tmp_path_factory) -> Iterator[str]:
    """`temporal server start-dev`: one process, in-memory SQLite, no UI.

    A local dev server. Nothing here says anything about a production cluster.
    """
    if _port_open(TEMPORAL_PORT):
        pytest.fail(f"port {TEMPORAL_PORT} is taken; set PAYOUT_TEMPORAL_PORT")
    log = open(tmp_path_factory.mktemp("temporal") / "server.log", "w")
    server = subprocess.Popen(
        ["temporal", "server", "start-dev", "--headless", "--ip", "127.0.0.1",
         "--port", str(TEMPORAL_PORT), "--log-level", "error"],
        stdout=log, stderr=subprocess.STDOUT)
    deadline = time.monotonic() + 30
    while not _port_open(TEMPORAL_PORT):
        if server.poll() is not None or time.monotonic() > deadline:
            pytest.fail(f"temporal dev server did not start; see {log.name}")
        time.sleep(0.1)
    yield f"127.0.0.1:{TEMPORAL_PORT}"
    server.terminate()
    server.wait(10)


@pytest.fixture(scope="session")
def provider_dsn(admin_dsn: str) -> Iterator[str]:
    """The fake provider lives in its own database: it is not part of the ledger."""
    with psycopg.connect(admin_dsn, autocommit=True) as c:
        c.execute(sql.SQL("DROP DATABASE IF EXISTS {} WITH (FORCE)").format(sql.Identifier(PROVIDER_DB)))
        c.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(PROVIDER_DB)))
    dsn = ledger_conftest._dsn_for(admin_dsn, PROVIDER_DB)
    with psycopg.connect(dsn, autocommit=True) as c:
        c.execute(provider.SCHEMA)
    yield dsn
    with psycopg.connect(admin_dsn, autocommit=True) as c:
        c.execute(sql.SQL("DROP DATABASE IF EXISTS {} WITH (FORCE)").format(sql.Identifier(PROVIDER_DB)))


@dataclass
class Workers:
    """Worker processes for one test, plus the supervisor duty of restarting them."""
    env: dict
    fault_dir: pathlib.Path
    procs: list[subprocess.Popen] = field(default_factory=list)
    restarts: int = 0
    logs: dict[int, pathlib.Path] = field(default_factory=dict)

    def start(self, n: int = 1) -> list[subprocess.Popen]:
        started = []
        for _ in range(n):
            log = self.fault_dir / f"worker-{len(self.logs)}.log"
            p = subprocess.Popen([sys.executable, str(HERE / "worker.py")], env=self.env,
                                 cwd=HERE, stdout=open(log, "w"), stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 30
            while "worker ready" not in log.read_text():
                assert p.poll() is None and time.monotonic() < deadline, \
                    f"worker failed to start:\n{log.read_text()}"
                time.sleep(0.02)
            self.logs[p.pid] = log
            self.procs.append(p)
            started.append(p)
        return started

    def wait_for_death(self, timeout: float = 30) -> subprocess.Popen:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for p in self.procs:
                if p.poll() is not None:
                    return p
            time.sleep(0.02)
        raise AssertionError("no worker died; the fault never fired")

    def restart_dead(self) -> None:
        for p in [p for p in self.procs if p.poll() is not None]:
            self.procs.remove(p)
            self.start()
            self.restarts += 1

    def arm(self, request_id: str, at: str, action: str) -> None:
        (self.fault_dir / "plans" / f"{request_id}.json").write_text(
            json.dumps({"at": at, "action": action}))

    def fired_pid(self, request_id: str) -> int | None:
        path = self.fault_dir / "fired" / request_id
        return int(path.read_text()) if path.exists() else None

    def evidence(self, request_id: str) -> list[dict]:
        path = self.fault_dir / "evidence.jsonl"
        if not path.exists():
            return []
        rows = [json.loads(line) for line in path.read_text().splitlines() if line]
        return [r for r in rows if r.get("request_id") == request_id]

    def stop(self) -> None:
        for p in self.procs:
            if p.poll() is None:
                os.kill(p.pid, signal.SIGCONT)          # a frozen worker ignores SIGTERM
                p.terminate()
        for p in self.procs:
            try:
                p.wait(10)
            except subprocess.TimeoutExpired:
                p.kill()


@pytest.fixture
def workers(temporal_address: str, ledger_db: str, provider_dsn: str,
            tmp_path) -> Iterator[Workers]:
    fault_dir = tmp_path / "faults"
    (fault_dir / "plans").mkdir(parents=True)
    (fault_dir / "fired").mkdir()
    env = {
        **os.environ,
        "TEMPORAL_ADDRESS": temporal_address,
        "LEDGER_TEMPORAL_DSN": ledger_db,
        "PROVIDER_DSN": provider_dsn,
        "PAYOUT_TASK_QUEUE": f"payout-{uuid4()}",       # a fresh queue per test
        "PAYOUT_FAULT_DIR": str(fault_dir),
        "PYTHONPATH": os.pathsep.join([str(HERE), str(LEDGER_TESTS)]),
        "PYTHONDONTWRITEBYTECODE": "1",
    }
    pool = Workers(env, fault_dir)
    yield pool
    pool.stop()


@pytest.fixture(autouse=True)
def _reset_provider(provider_dsn: str) -> None:
    with psycopg.connect(provider_dsn, autocommit=True) as c:
        c.execute("TRUNCATE provider_payouts")


@pytest.fixture
def record(request):
    """Append one evidence row per test for compare.py to turn into the matrix."""
    rows: list[dict] = []
    yield lambda **row: rows.append(row)
    if RESULTS:
        with open(RESULTS, "a") as f:
            for row in rows:
                f.write(json.dumps({"test": request.node.nodeid, **row}, default=str) + "\n")
