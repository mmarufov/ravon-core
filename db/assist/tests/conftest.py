"""Fixtures: a fresh database with db/schema, the ledger and db/assist applied,
then seeded with the 40 synthetic eval cases.

Like db/ledger/tests, there is no mock anywhere. Every claim here is about
PostgreSQL privileges, row-level security and row locks, so it is tested
against PostgreSQL.
"""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
from typing import Iterator

import psycopg
import pytest
from psycopg import sql
from psycopg.conninfo import conninfo_to_dict, make_conninfo

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "db" / "assist"))
sys.path.insert(0, str(ROOT / "db" / "ledger" / "tests"))

from seed import Seeder  # noqa: E402

# Matches the CI service in .github/workflows/ci.yml. Override with ASSIST_DSN.
ADMIN_DSN = os.environ.get("ASSIST_DSN", "postgresql://postgres:ravon@127.0.0.1:5436/postgres")
TEST_DB = os.environ.get("ASSIST_TEST_DB", "ravon_assist_test")
AGENT_PASSWORD = "assist_agent_pw"


def dsn_for(dsn: str, dbname: str, user: str | None = None, password: str | None = None) -> str:
    parts = conninfo_to_dict(dsn)
    parts["dbname"] = dbname
    if user is not None:
        parts["user"], parts["password"] = user, password
    return make_conninfo(**parts)


def apply_stack(dsn: str) -> None:
    """The same three steps as db/assist/README.md, so a broken file fails
    here with psql's own error."""
    parts = conninfo_to_dict(dsn)
    env = dict(os.environ, PGPASSWORD=parts.get("password", "") or "")
    args = ["-h", parts.get("host", "127.0.0.1"), "-p", str(parts.get("port", 5432)),
            "-U", parts.get("user", "postgres"), "-d", parts["dbname"]]
    subprocess.run([str(ROOT / "db/schema/apply.sh"), *args, "--local"], check=True, env=env,
                   capture_output=True)
    for f in ("db/ledger/schema.sql", "db/assist/01_assist.sql"):
        subprocess.run(["psql", *args, "-v", "ON_ERROR_STOP=1", "-q", "-f", str(ROOT / f)],
                       check=True, env=env, capture_output=True)


@pytest.fixture(scope="session")
def seeded_db() -> Iterator[tuple[str, dict]]:
    try:
        with psycopg.connect(ADMIN_DSN, connect_timeout=5):
            pass
    except psycopg.Error as exc:
        pytest.fail(f"cannot reach PostgreSQL at {ADMIN_DSN}: {exc}\nSee db/assist/README.md.")

    with psycopg.connect(ADMIN_DSN, autocommit=True) as conn:
        conn.execute(sql.SQL("DROP DATABASE IF EXISTS {} WITH (FORCE)").format(sql.Identifier(TEST_DB)))
        conn.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(TEST_DB)))
    dsn = dsn_for(ADMIN_DSN, TEST_DB)
    apply_stack(dsn)
    with psycopg.connect(dsn, autocommit=True) as conn:
        conn.execute(sql.SQL("ALTER ROLE assist_agent LOGIN PASSWORD {}").format(sql.Literal(AGENT_PASSWORD)))

    seeder = Seeder(dsn, "eval")
    cases = {c.case_id: c.__dict__ for c in seeder.run()}
    yield dsn, cases

    with psycopg.connect(ADMIN_DSN, autocommit=True) as conn:
        conn.execute(sql.SQL("DROP DATABASE IF EXISTS {} WITH (FORCE)").format(sql.Identifier(TEST_DB)))


@pytest.fixture(scope="session")
def dsn(seeded_db) -> str:
    return seeded_db[0]


@pytest.fixture(scope="session")
def cases(seeded_db) -> dict:
    return seeded_db[1]


@pytest.fixture(scope="session")
def agent_dsn(dsn) -> str:
    """The agent process's own login. It holds reader and proposer WITH
    INHERIT FALSE, so it can do nothing until it SETs one of them."""
    return dsn_for(dsn, TEST_DB, "assist_agent", AGENT_PASSWORD)


@pytest.fixture
def admin(dsn) -> Iterator[psycopg.Connection]:
    with psycopg.connect(dsn, autocommit=True) as conn:
        yield conn


def as_merchant(conn: psycopg.Connection, role: str, merchant: str | None) -> None:
    """What every agent tool does before its one query: one role, one merchant,
    both transaction-local."""
    conn.execute(sql.SQL("SET LOCAL ROLE {}").format(sql.Identifier(role)))
    conn.execute("SELECT set_config('assist.merchant_id', %s, true)", (merchant or "",))


def by_cause(cases: dict, cause: str) -> list[dict]:
    return [c for c in cases.values() if c["cause"] == cause]


def reason_of(exc: psycopg.Error) -> str | None:
    raw = exc.diag.message_detail if exc.diag else None
    try:
        return json.loads(raw).get("reason") if raw else None
    except ValueError:
        return None
