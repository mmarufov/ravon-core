"""The server-side kill counter, checked against kills it did and did not see.

    cd db/ledger && LEDGER_DSN=... PYTHONPATH=tools python -m pytest tools -p pytester

A counter that always reports what the README says is worthless, so each
positive has a negative control: a connection closed normally must count 0, and
an --expect-kills that disagrees with the run must fail the session.
"""

from __future__ import annotations

import os
import pathlib

import psycopg
import pytest
from psycopg import sql
from psycopg.conninfo import conninfo_to_dict, make_conninfo

from pg_killcount import DEFAULT_DSN, sessions_killed

ADMIN_DSN = os.environ.get("LEDGER_DSN", DEFAULT_DSN)
SCRATCH_DB = "ravon_killcount_selftest"

SYNTHETIC_SUITE = f'''
import psycopg
from psycopg.conninfo import conninfo_to_dict, make_conninfo

DSN = make_conninfo(**{{**conninfo_to_dict({ADMIN_DSN!r}), "dbname": {SCRATCH_DB!r}}})

def _kill_one(admin):
    victim = psycopg.connect(DSN)
    pid = victim.info.backend_pid
    assert admin.execute("SELECT pg_terminate_backend(%s, 5000)", (pid,)).fetchone()[0]

def test_kills_twice():
    with psycopg.connect(DSN, autocommit=True) as admin:
        _kill_one(admin)
        _kill_one(admin)

def test_kills_once():
    with psycopg.connect(DSN, autocommit=True) as admin:
        _kill_one(admin)

def test_closes_normally():
    psycopg.connect(DSN).close()
'''


@pytest.fixture
def scratch_db():
    with psycopg.connect(ADMIN_DSN, autocommit=True) as c:
        c.execute(sql.SQL("DROP DATABASE IF EXISTS {} WITH (FORCE)").format(sql.Identifier(SCRATCH_DB)))
        c.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(SCRATCH_DB)))
    yield make_conninfo(**{**conninfo_to_dict(ADMIN_DSN), "dbname": SCRATCH_DB})
    with psycopg.connect(ADMIN_DSN, autocommit=True) as c:
        c.execute(sql.SQL("DROP DATABASE IF EXISTS {} WITH (FORCE)").format(sql.Identifier(SCRATCH_DB)))


RECREATING_CONFTEST = f'''
import psycopg
import pytest
from psycopg import sql

@pytest.fixture(scope="session", autouse=True)
def fresh_database():
    # What tests/conftest.py's ledger_db does: drop and recreate the database
    # in the first test's setup, which resets its statistics row.
    with psycopg.connect({ADMIN_DSN!r}, autocommit=True) as c:
        c.execute(sql.SQL("DROP DATABASE IF EXISTS {{}} WITH (FORCE)").format(sql.Identifier({SCRATCH_DB!r})))
        c.execute(sql.SQL("CREATE DATABASE {{}}").format(sql.Identifier({SCRATCH_DB!r})))
    yield
'''


def _run(pytester: pytest.Pytester, monkeypatch, *args: str) -> pytest.RunResult:
    monkeypatch.setenv("LEDGER_TEST_DB", SCRATCH_DB)
    monkeypatch.setenv("PYTHONPATH", str(pathlib.Path(__file__).resolve().parent))
    pytester.makepyfile(test_synthetic=SYNTHETIC_SUITE)
    return pytester.runpytest_subprocess("-p", "pg_killcount", "--kill-report", *args)


def test_a_terminated_backend_counts_and_a_closed_one_does_not(scratch_db):
    with psycopg.connect(ADMIN_DSN, autocommit=True) as admin:
        start = sessions_killed(admin, SCRATCH_DB)
        psycopg.connect(scratch_db).close()                       # negative control
        assert sessions_killed(admin, SCRATCH_DB) == start
        victim = psycopg.connect(scratch_db)
        admin.execute("SELECT pg_terminate_backend(%s, 5000)", (victim.info.backend_pid,))
        assert sessions_killed(admin, SCRATCH_DB) == start + 1


def test_the_plugin_attributes_kills_to_the_test_that_made_them(pytester, monkeypatch, scratch_db):
    result = _run(pytester, monkeypatch, "--expect-kills", "2:3")
    result.assert_outcomes(passed=3)
    assert result.ret == 0
    result.stdout.fnmatch_lines([
        "pg-killcount: 2 of 3 tests killed a backend; 3 kills in total",
        "*2  test_synthetic.py::test_kills_twice",
        "*1  test_synthetic.py::test_kills_once",
    ])
    result.stdout.no_fnmatch_line("*test_closes_normally*")


def test_a_wrong_expectation_fails_the_session(pytester, monkeypatch, scratch_db):
    # Negative control for the CI gate: every test passes, the count disagrees,
    # and the session must still exit non-zero.
    result = _run(pytester, monkeypatch, "--expect-kills", "2:4")
    result.assert_outcomes(passed=3)
    assert result.ret == pytest.ExitCode.TESTS_FAILED
    result.stdout.fnmatch_lines(["pg-killcount MISMATCH: expected 2 tests / 4 kills, got 2 / 3"])


def test_a_stale_database_from_an_earlier_run_does_not_leak_into_the_count(
        pytester, monkeypatch, scratch_db):
    # Regression: an aborted run leaves the database behind with kills already
    # counted. The suite's session fixture recreates it during the first test's
    # setup, so a "before" read taken ahead of fixture setup saw the stale count
    # and the first test came out negative.
    with psycopg.connect(ADMIN_DSN, autocommit=True) as admin:
        for _ in range(5):
            victim = psycopg.connect(scratch_db)
            admin.execute("SELECT pg_terminate_backend(%s, 5000)", (victim.info.backend_pid,))
        assert sessions_killed(admin, SCRATCH_DB) >= 5
    pytester.makeconftest(RECREATING_CONFTEST)
    result = _run(pytester, monkeypatch, "--expect-kills", "2:3")
    result.assert_outcomes(passed=3)
    assert result.ret == 0, result.stdout.str()

