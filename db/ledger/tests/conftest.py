"""Fixtures: a real PostgreSQL database with schema.sql applied.

There is no mock and no in-memory substitute anywhere in this suite, by design.
The claims being tested — that a deferred constraint trigger rejects an
unbalanced COMMIT, that a killed backend leaves no partial posting — are claims
about PostgreSQL. A fake that reproduced them would be testing the fake.
"""

from __future__ import annotations

import os
import pathlib
from typing import Iterator

import psycopg
import pytest
from hypothesis import HealthCheck, settings
from psycopg import sql
from psycopg.conninfo import conninfo_to_dict, make_conninfo

from ledger_api import Ledger

SCHEMA_PATH = pathlib.Path(__file__).resolve().parents[1] / "schema.sql"

# Matches the docker one-liner in db/ledger/README.md. Override with LEDGER_DSN.
DEFAULT_DSN = "postgresql://postgres:ledger@127.0.0.1:5433/postgres"
ADMIN_DSN = os.environ.get("LEDGER_DSN", DEFAULT_DSN)

TEST_DB = os.environ.get("LEDGER_TEST_DB", "ravon_ledger_test")
APP_PASSWORD = "ledger_app_pw"
ANON_PASSWORD = "ledger_anon_pw"

LEDGER_TABLES = (
    "ledger_payouts",
    "ledger_entries",
    "ledger_transactions",
    "ledger_balances",
    "ledger_accounts",
)

# ---------------------------------------------------------------------------
# Hypothesis profiles
#
# The repo's Swift property tests are SplitMix64-seeded so that a failure
# reproduces from a printed seed. The equivalent here is `derandomize`:
# Hypothesis derives its randomness from the test itself, so a given commit
# explores the same sequences on every machine and a CI failure reproduces
# locally with nothing to copy across. A failing run additionally prints a
# @reproduce_failure blob that replays the exact failing case.
#
# There is deliberately no seed environment variable. Hypothesis does not expose
# a seed argument on run_state_machine_as_test, so a LEDGER_SEED knob could only
# have turned `derandomize` off — which makes runs *less* reproducible, not more,
# while appearing to do the opposite. LEDGER_MAX_EXAMPLES and LEDGER_STEP_COUNT
# are the real dials for exploring further.
#
# max_examples is the CI runtime dial. Each example runs `stateful_step_count`
# database round trips plus one invariant query per step, so wall-clock is
# roughly linear in max_examples * step_count. The default is sized to keep the
# ledger-invariants job under ~60s on a GitHub runner; raise LEDGER_MAX_EXAMPLES
# locally when hunting.
# ---------------------------------------------------------------------------
_MAX_EXAMPLES = int(os.environ.get("LEDGER_MAX_EXAMPLES", "120"))
_STEP_COUNT = int(os.environ.get("LEDGER_STEP_COUNT", "40"))
_COMMON = dict(
    max_examples=_MAX_EXAMPLES,
    stateful_step_count=_STEP_COUNT,
    deadline=None,                              # a DB round trip is not a timing bug
    suppress_health_check=[HealthCheck.too_slow, HealthCheck.data_too_large],
)

settings.register_profile("ci", derandomize=True, **_COMMON)
settings.register_profile("dev", derandomize=False, **_COMMON)
settings.load_profile(os.environ.get("HYPOTHESIS_PROFILE", "ci"))

MAX_EXAMPLES = _MAX_EXAMPLES
STEP_COUNT = _STEP_COUNT


def _dsn_for(dsn: str, dbname: str, user: str | None = None,
             password: str | None = None) -> str:
    parts = conninfo_to_dict(dsn)
    parts["dbname"] = dbname
    if user is not None:
        parts["user"] = user
        parts["password"] = password
    return make_conninfo(**parts)


def reset_ledger(conn: psycopg.Connection) -> None:
    """Truncate every ledger table back to empty.

    TRUNCATE, not DELETE, and that is worth a note: DELETE would be blocked by
    the immutability trigger, which is the point of the trigger. TRUNCATE is not
    blocked by it — row-level triggers do not fire for TRUNCATE — which is
    exactly why schema.sql revokes TRUNCATE from the application role rather
    than trusting the trigger to cover it. See test_truncate_bypasses_row_trigger.
    """
    with conn.cursor() as cur:
        cur.execute(sql.SQL("TRUNCATE {} RESTART IDENTITY CASCADE").format(
            sql.SQL(", ").join(sql.Identifier(t) for t in LEDGER_TABLES)))
    conn.commit()


@pytest.fixture(scope="session")
def admin_dsn() -> str:
    try:
        with psycopg.connect(ADMIN_DSN, connect_timeout=5):
            pass
    except psycopg.Error as exc:
        pytest.fail(
            f"cannot reach PostgreSQL at {ADMIN_DSN}: {exc}\n"
            "Start one with:  docker run --rm -e POSTGRES_PASSWORD=ledger "
            "-p 5433:5432 postgres:16\n"
            "or point LEDGER_DSN at your own instance. See db/ledger/README.md.")
    return ADMIN_DSN


@pytest.fixture(scope="session")
def ledger_db(admin_dsn: str) -> Iterator[str]:
    """Create a throwaway database, apply schema.sql, yield its DSN."""
    with psycopg.connect(admin_dsn, autocommit=True) as conn, conn.cursor() as cur:
        cur.execute(sql.SQL("DROP DATABASE IF EXISTS {} WITH (FORCE)").format(
            sql.Identifier(TEST_DB)))
        cur.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(TEST_DB)))

    dsn = _dsn_for(admin_dsn, TEST_DB)
    with psycopg.connect(dsn, autocommit=True) as conn, conn.cursor() as cur:
        cur.execute(SCHEMA_PATH.read_text())
        # schema.sql creates both roles NOLOGIN, as a deployment would. The
        # privilege tests need to actually connect as them.
        cur.execute(sql.SQL("ALTER ROLE ravon_ledger_app LOGIN PASSWORD {}").format(
            sql.Literal(APP_PASSWORD)))
        cur.execute(sql.SQL("ALTER ROLE ravon_ledger_anon LOGIN PASSWORD {}").format(
            sql.Literal(ANON_PASSWORD)))

    yield dsn

    with psycopg.connect(admin_dsn, autocommit=True) as conn, conn.cursor() as cur:
        cur.execute(sql.SQL("DROP DATABASE IF EXISTS {} WITH (FORCE)").format(
            sql.Identifier(TEST_DB)))


@pytest.fixture
def conn(ledger_db: str) -> Iterator[psycopg.Connection]:
    with psycopg.connect(ledger_db) as connection:
        reset_ledger(connection)
        yield connection


@pytest.fixture
def ledger(conn: psycopg.Connection) -> Ledger:
    return Ledger(conn)


@pytest.fixture
def admin_conn(ledger_db: str) -> Iterator[psycopg.Connection]:
    """A second connection, used to observe and to kill the first one."""
    with psycopg.connect(ledger_db, autocommit=True) as connection:
        yield connection


@pytest.fixture
def app_dsn(ledger_db: str) -> str:
    """DSN for the least-privilege service role."""
    return _dsn_for(ledger_db, TEST_DB, "ravon_ledger_app", APP_PASSWORD)


@pytest.fixture
def anon_dsn(ledger_db: str) -> str:
    """DSN for an untrusted client role — the iOS `anon` equivalent."""
    return _dsn_for(ledger_db, TEST_DB, "ravon_ledger_anon", ANON_PASSWORD)


@pytest.fixture(scope="session")
def state_machine_dsn(ledger_db: str) -> str:
    return ledger_db
