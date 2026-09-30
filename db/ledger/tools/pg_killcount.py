"""Count, per test, how many PostgreSQL backends the suite killed, as the server saw it.

    cd db/ledger
    LEDGER_DSN=... PYTHONPATH=tools python -m pytest tests -p no:cacheprovider \
        -p pg_killcount --kill-report --expect-kills 7:18

(`pythonpath` in pytest.ini does not cover tools/, hence `PYTHONPATH=tools`.)

tests/killcount.py counts calls into the harness's kill() helper. This counts
from the other side: PostgreSQL's `pg_stat_database.sessions_killed`, which is
incremented for every session ended by operator intervention, which is what
pg_terminate_backend() is. The two are independent, so agreement between them
is evidence and not an echo. A test that only closes its connection, or that
simulates a driver stopping by not calling the next step, adds nothing to
either.

`--expect-kills TESTS:KILLS` fails the session if the server's count differs,
which is how CI keeps db/ledger/README.md's number honest.

The suite's kill() helper calls pg_terminate_backend(pid, 5000), which waits for
the backend to exit. A backend flushes its session statistics before it leaves
the process array, so the counter has moved by the time the test continues.

Needs PostgreSQL 14 or newer (sessions_killed was added in 14).
"""

from __future__ import annotations

import os

import psycopg
import pytest

DEFAULT_DSN = "postgresql://postgres:ledger@127.0.0.1:5433/postgres"


def sessions_killed(conn: psycopg.Connection, dbname: str) -> int:
    # Statistics reads are cached per transaction; clear the snapshot so each
    # read sees the current shared-memory value. One database only: the suite
    # drops and recreates databases, and a dropped database's row vanishes
    # from the view, which would make a sum over all of them go backwards.
    conn.execute("SELECT pg_stat_clear_snapshot()")
    row = conn.execute("SELECT sessions_killed FROM pg_stat_database WHERE datname = %s",
                       (dbname,)).fetchone()
    return int(row[0]) if row else 0


def pytest_addoption(parser: pytest.Parser) -> None:
    group = parser.getgroup("pg_killcount")
    group.addoption("--kill-report", action="store_true",
                    help="print every test that killed a backend, and how many times")
    group.addoption("--expect-kills", metavar="TESTS:KILLS",
                    help="fail the session unless exactly TESTS tests killed KILLS backends")


class KillCounter:
    def __init__(self, dsn: str, dbname: str) -> None:
        self.conn = psycopg.connect(dsn, autocommit=True)
        self.dbname = dbname
        self.per_test: dict[str, int] = {}

    # Setup through call, not teardown: the session fixture drops the test
    # database during the last test's teardown, and its statistics row goes
    # with it. No fixture in the suite kills a backend on teardown.
    @pytest.hookimpl(hookwrapper=True)
    def pytest_runtest_setup(self, item: pytest.Item):
        self._before = sessions_killed(self.conn, self.dbname)
        yield

    @pytest.hookimpl(hookwrapper=True)
    def pytest_runtest_call(self, item: pytest.Item):
        yield
        self.per_test[item.nodeid] = sessions_killed(self.conn, self.dbname) - self._before

    def totals(self) -> tuple[int, int]:
        killing = [n for n in self.per_test.values() if n]
        return len(killing), sum(killing)


def pytest_configure(config: pytest.Config) -> None:
    dsn = os.environ.get("LEDGER_DSN", DEFAULT_DSN)
    # The database the ledger fixtures create; LEDGER_TEST_DB as in tests/conftest.py.
    config._killcounter = KillCounter(dsn, os.environ.get("LEDGER_TEST_DB", "ravon_ledger_test"))
    config.pluginmanager.register(config._killcounter, "killcounter")


def pytest_terminal_summary(terminalreporter, exitstatus, config: pytest.Config) -> None:
    kc: KillCounter = config._killcounter
    tests, kills = kc.totals()
    terminalreporter.write_line(
        f"pg-killcount: {tests} of {len(kc.per_test)} tests killed a backend; {kills} kills in total")
    if config.getoption("kill_report"):
        for nodeid, n in kc.per_test.items():
            if n:
                terminalreporter.write_line(f"  {n:3d}  {nodeid}")


def pytest_sessionfinish(session: pytest.Session, exitstatus) -> None:
    config = session.config
    expected = config.getoption("expect_kills")
    if not expected:
        return
    want = tuple(int(x) for x in expected.split(":"))
    got = config._killcounter.totals()
    if got != want:
        config._killcounter_mismatch = f"expected {want[0]} tests / {want[1]} kills, got {got[0]} / {got[1]}"
        session.exitstatus = pytest.ExitCode.TESTS_FAILED


def pytest_unconfigure(config: pytest.Config) -> None:
    msg = getattr(config, "_killcounter_mismatch", None)
    if msg:
        print(f"pg-killcount MISMATCH: {msg}")
    config._killcounter.conn.close()
