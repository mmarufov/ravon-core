"""A stand-in for the external payout provider.

The hand-built suite never models the provider: its tests pass a provider_ref
string in, as if recovery had already asked the provider. A Temporal activity
has to actually call something, and Temporal will call it more than once, so
this fake is a set of real tables in its own database.

Two tables, because a real provider keeps two different things:

  provider_payouts   the idempotency-key cache: request_id -> the payout it
                     created. Keys can expire (`ttl`); after that the same
                     request_id is a new request.
  provider_objects   the payouts themselves, permanent. `status(request_id)`
                     reads these, so it still answers after the key is gone.
                     That is an assumption about the provider (a lookup by
                     client reference that outlives the idempotency window),
                     and it is the one the status-first saga depends on.

Being idempotent on request_id is not a courtesy. It is the property that makes
an at-least-once activity safe, and Temporal does not provide it. It holds only
while the key is retained, which is the point of the `key_expiry` fault.

Faults (`arm()`) apply to the first call for a payout and model a lost reply:
the caller gets ProviderTimeout, and what happened at the provider depends on
the mode. Time is whatever `now` the caller passes, in seconds or ticks, so the
matrix can run on a logical clock and the Temporal tests on the wall clock.
"""

from __future__ import annotations

import time
from contextlib import contextmanager
from dataclasses import dataclass
from typing import Iterator

import psycopg

# Amounts above this are declined, so the workflow's failure branch is reachable.
DECLINE_ABOVE = 1_000_000

FAULT_MODES = ("none", "commit_then_timeout", "timeout_before_commit",
               "async_pending_then_paid", "async_pending_then_failed",
               "returned_after_delay", "key_expiry")

SCHEMA = """
CREATE TABLE IF NOT EXISTS provider_payouts (
  request_id   text PRIMARY KEY,
  provider_ref text NOT NULL,
  amount_minor bigint NOT NULL,
  currency     char(3) NOT NULL,
  calls        int NOT NULL DEFAULT 1,
  expires_at   double precision            -- NULL: the key is kept forever
);
CREATE TABLE IF NOT EXISTS provider_objects (
  provider_ref text PRIMARY KEY DEFAULT 'prv_' || gen_random_uuid(),
  request_id   text NOT NULL,
  payout_key   text NOT NULL,              -- the caller's logical payout, across request ids
  amount_minor bigint NOT NULL,
  currency     char(3) NOT NULL,
  created_at   double precision NOT NULL,
  status       text NOT NULL CHECK (status IN ('paid', 'pending', 'failed')),
  failure_code text CHECK (failure_code IN ('declined', 'returned')),
  resolve_at   double precision,           -- pending -> resolve_to at this time
  resolve_to   text CHECK (resolve_to IN ('paid', 'failed')),
  returned_at  double precision            -- paid -> failed/returned at this time
);
CREATE INDEX IF NOT EXISTS provider_objects_request_id ON provider_objects (request_id);
CREATE INDEX IF NOT EXISTS provider_objects_payout_key ON provider_objects (payout_key);
CREATE TABLE IF NOT EXISTS provider_faults (
  payout_key    text PRIMARY KEY,
  mode          text NOT NULL,
  resolve_after double precision,
  return_after  double precision,
  fired         boolean NOT NULL DEFAULT false
);
"""


class ProviderTimeout(Exception):
    """The reply was lost. The caller cannot tell whether money moved."""


@dataclass(frozen=True)
class Reply:
    provider_ref: str
    status: str                 # 'paid' | 'pending' | 'failed'


@dataclass(frozen=True)
class Status:
    state: str                  # 'paid' | 'pending' | 'failed' | 'not_found'
    provider_ref: str | None
    failure_code: str | None    # 'declined' | 'returned' when state == 'failed'


@contextmanager
def _connect(target) -> Iterator[psycopg.Connection]:
    """A DSN opens and closes a connection per call, which is what a worker
    process does. The matrix passes one open connection instead; each call is
    still its own transaction."""
    if isinstance(target, psycopg.Connection):
        try:
            yield target
            target.commit()
        except BaseException:
            target.rollback()
            raise
    else:
        with psycopg.connect(target) as conn:
            yield conn


def _effective(row: tuple, now: float) -> tuple[str, str | None]:
    """An object's status at `now`, applying its scheduled transitions."""
    status, failure_code, resolve_at, resolve_to, returned_at = row
    if status == "pending" and resolve_at is not None and now >= resolve_at:
        status = resolve_to
        failure_code = "declined" if resolve_to == "failed" else None
    if status == "paid" and returned_at is not None and now >= returned_at:
        status, failure_code = "failed", "returned"
    return status, failure_code


def arm(dsn: str, payout_key: str, mode: str, *, resolve_after: float | None = None,
        return_after: float | None = None) -> None:
    """Make the first call for `payout_key` fail in `mode`."""
    assert mode in FAULT_MODES, mode
    with _connect(dsn) as conn:
        conn.execute(
            "INSERT INTO provider_faults (payout_key, mode, resolve_after, return_after) "
            "VALUES (%s, %s, %s, %s)", (payout_key, mode, resolve_after, return_after))


def pay(dsn: str, request_id: str, amount_minor: int, currency: str, *,
        payout_key: str | None = None, now: float | None = None,
        ttl: float | None = None) -> Reply:
    """Submit a payout. Idempotent on request_id while the key is retained.

    Raises ProviderTimeout when an armed fault fires. Returns a Reply otherwise;
    a declined payout comes back as status 'failed'.
    """
    payout_key = payout_key or request_id
    now = time.time() if now is None else now
    with _connect(dsn) as conn:
        # One provider, one request at a time per key: the row lock on the key
        # is what makes two concurrent identical requests create one payout.
        conn.execute("SELECT pg_advisory_xact_lock(hashtext(%s))", (request_id,))
        key = conn.execute(
            "SELECT provider_ref, expires_at FROM provider_payouts WHERE request_id = %s",
            (request_id,)).fetchone()
        if key and (key[1] is None or now < key[1]):
            conn.execute("UPDATE provider_payouts SET calls = calls + 1 WHERE request_id = %s",
                         (request_id,))
            row = conn.execute(
                "SELECT status, failure_code, resolve_at, resolve_to, returned_at "
                "FROM provider_objects WHERE provider_ref = %s", (key[0],)).fetchone()
            return Reply(key[0], _effective(row, now)[0])

        fault = conn.execute(
            "UPDATE provider_faults SET fired = true WHERE payout_key = %s AND NOT fired "
            "RETURNING mode, resolve_after, return_after", (payout_key,)).fetchone()
        mode, resolve_after, return_after = fault or ("none", None, None)

        if mode == "timeout_before_commit":
            conn.commit()                     # the fault is spent; nothing else is recorded
            raise ProviderTimeout(request_id)

        status, failure_code, resolve_at, resolve_to, returned_at = "paid", None, None, None, None
        if amount_minor > DECLINE_ABOVE:
            status, failure_code = "failed", "declined"
        elif mode == "async_pending_then_paid":
            status, resolve_at, resolve_to = "pending", now + resolve_after, "paid"
        elif mode == "async_pending_then_failed":
            status, resolve_at, resolve_to = "pending", now + resolve_after, "failed"
        elif mode == "returned_after_delay":
            returned_at = now + return_after

        ref = conn.execute(
            "INSERT INTO provider_objects (request_id, payout_key, amount_minor, currency, "
            "created_at, status, failure_code, resolve_at, resolve_to, returned_at) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s) RETURNING provider_ref",
            (request_id, payout_key, amount_minor, currency, now, status, failure_code,
             resolve_at, resolve_to, returned_at)).fetchone()[0]
        conn.execute(
            "INSERT INTO provider_payouts (request_id, provider_ref, amount_minor, currency, "
            "expires_at) VALUES (%s, %s, %s, %s, %s) "
            "ON CONFLICT (request_id) DO UPDATE SET provider_ref = EXCLUDED.provider_ref, "
            "calls = provider_payouts.calls + 1, expires_at = EXCLUDED.expires_at",
            (request_id, ref, amount_minor, currency, None if ttl is None else now + ttl))
        conn.commit()
        if mode != "none":
            raise ProviderTimeout(request_id)    # it happened; the caller will never hear
        return Reply(ref, status)


def submit(dsn: str, request_id: str, amount_minor: int, currency: str) -> str | None:
    """The original contract: pay once per request_id, forever. None if declined."""
    reply = pay(dsn, request_id, amount_minor, currency)
    return None if reply.status == "failed" else reply.provider_ref


def status(dsn: str, request_id: str, now: float | None = None) -> Status:
    """What the provider knows about every payout it created for `request_id`.

    Reads the permanent records, not the key cache. If several objects exist
    (the key expired and the request was re-sent), `paid` wins over `pending`
    over `failed`, and the reference returned is the one in that state.
    """
    now = time.time() if now is None else now
    with _connect(dsn) as conn:
        rows = conn.execute(
            "SELECT provider_ref, status, failure_code, resolve_at, resolve_to, returned_at "
            "FROM provider_objects WHERE request_id = %s ORDER BY created_at, provider_ref",
            (request_id,)).fetchall()
    if not rows:
        return Status("not_found", None, None)
    seen = [(r[0], *_effective(r[1:], now)) for r in rows]
    for want in ("paid", "pending", "failed"):
        for ref, state, code in seen:
            if state == want:
                return Status(state, ref, code)
    raise AssertionError(seen)


def status_by_ref(dsn: str, provider_ref: str, now: float | None = None) -> Status:
    now = time.time() if now is None else now
    with _connect(dsn) as conn:
        row = conn.execute(
            "SELECT status, failure_code, resolve_at, resolve_to, returned_at "
            "FROM provider_objects WHERE provider_ref = %s", (provider_ref,)).fetchone()
    if row is None:
        return Status("not_found", None, None)
    state, code = _effective(row, now)
    return Status(state, provider_ref, code)


def eventual_paid(dsn: str, payout_key: str) -> tuple[int, int]:
    """(objects that end paid, objects still pending with no resolution) for one payout,
    after every scheduled transition has happened. The matrix's ground truth."""
    with _connect(dsn) as conn:
        rows = conn.execute(
            "SELECT status, failure_code, resolve_at, resolve_to, returned_at "
            "FROM provider_objects WHERE payout_key = %s", (payout_key,)).fetchall()
    finals = [_effective(r, float("inf"))[0] for r in rows]
    return finals.count("paid"), finals.count("pending")
