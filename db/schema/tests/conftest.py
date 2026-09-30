"""Fixtures: a fresh database with db/schema applied and seeded, per test.

The schema is applied once into a template database, then every test gets its
own copy (`CREATE DATABASE ... TEMPLATE`), so tests cannot see each other's
orders or stock.

RAVON_SCHEMA_DIR points the suite at a different copy of db/schema. That is how
the negative control runs: the same tests against the schema as it was at
65ad66c, extracted with `git archive`, must fail.

    RAVON_DSN=postgresql://postgres@127.0.0.1:5437/postgres python -m pytest
"""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import uuid
from typing import Iterator

import psycopg
import pytest
from psycopg.conninfo import conninfo_to_dict, make_conninfo

HERE = pathlib.Path(__file__).resolve().parent
SCHEMA_DIR = pathlib.Path(os.environ.get("RAVON_SCHEMA_DIR", HERE.parent)).resolve()

# Matches the db-invariants CI job. Override with RAVON_DSN.
ADMIN_DSN = os.environ.get("RAVON_DSN", "postgresql://postgres:ravon@127.0.0.1:5434/postgres")
TEMPLATE_DB = "ravon_schema_test_template"

# Seeded actors and objects (db/schema/seed.sql).
CONSUMER = "11111111-1111-1111-1111-111111111111"
MERCHANT = "22222222-2222-2222-2222-222222222222"
RESTAURANT = "aaaaaaaa-0000-0000-0000-000000000001"
ADDRESS = "dddddddd-0000-0000-0000-000000000001"
PLOV = "cccccccc-0000-0000-0000-000000000001"      # stock 40
SHASHLIK = "cccccccc-0000-0000-0000-000000000002"  # stock 30
LAGMAN = "cccccccc-0000-0000-0000-000000000003"    # untracked (NULL stock)


def dsn_for(dbname: str) -> str:
    params = conninfo_to_dict(ADMIN_DSN)
    params["dbname"] = dbname
    return make_conninfo(**params)


def _psql_args(dbname: str) -> tuple[list[str], dict[str, str]]:
    p = conninfo_to_dict(ADMIN_DSN)
    args = ["-h", p.get("host", "127.0.0.1"), "-p", str(p.get("port", 5432)),
            "-U", p.get("user", "postgres"), "-d", dbname]
    env = dict(os.environ)
    if p.get("password"):
        env["PGPASSWORD"] = p["password"]
    return args, env


def _admin() -> psycopg.Connection:
    return psycopg.connect(ADMIN_DSN, autocommit=True)


def _drop(conn: psycopg.Connection, name: str) -> None:
    conn.execute(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)')


@pytest.fixture(scope="session")
def template_db() -> Iterator[str]:
    with _admin() as a:
        _drop(a, TEMPLATE_DB)
        a.execute(f'CREATE DATABASE "{TEMPLATE_DB}"')
    args, env = _psql_args(TEMPLATE_DB)
    subprocess.run([str(SCHEMA_DIR / "apply.sh"), *args, "--local"],
                   check=True, env=env, capture_output=True)
    subprocess.run(["psql", *args, "-v", "ON_ERROR_STOP=1", "-q", "-f",
                    str(SCHEMA_DIR / "seed.sql")],
                   check=True, env=env, capture_output=True)
    yield TEMPLATE_DB
    with _admin() as a:
        _drop(a, TEMPLATE_DB)


@pytest.fixture
def db(template_db: str) -> Iterator[str]:
    name = f"ravon_t_{uuid.uuid4().hex[:12]}"
    with _admin() as a:
        a.execute(f'CREATE DATABASE "{name}" TEMPLATE "{template_db}"')
    yield dsn_for(name)
    with _admin() as a:
        _drop(a, name)


class Rejected(Exception):
    """A typed refusal from an RPC: SQLSTATE plus the decoded DETAIL reason."""

    def __init__(self, err: psycopg.Error):
        self.sqlstate = err.diag.sqlstate
        self.message = err.diag.message_primary
        try:
            self.detail = json.loads(err.diag.message_detail or "{}")
        except ValueError:
            self.detail = {}
        self.reason = self.detail.get("reason")
        super().__init__(f"{self.sqlstate} {self.message} {self.detail}")


def actor(dsn: str, uid: str) -> psycopg.Connection:
    """A connection that looks like PostgREST calling on behalf of `uid`."""
    c = psycopg.connect(dsn, autocommit=True)
    c.execute("SELECT set_config('request.jwt.claims', %s, false)", (json.dumps({"sub": uid}),))
    c.execute("SET ROLE authenticated")
    return c


def create_order(conn: psycopg.Connection, items: list[tuple[str, int]], scheduled_for=None) -> str:
    lines = json.dumps([{"menu_item_id": i, "quantity": q} for i, q in items])
    try:
        row = conn.execute("SELECT public.create_order(%s, %s, %s::jsonb, NULL, %s)",
                           (RESTAURANT, ADDRESS, lines, scheduled_for)).fetchone()
    except psycopg.Error as e:
        raise Rejected(e) from None
    return str(row[0])
