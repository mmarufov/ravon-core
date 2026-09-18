"""Crash injection: transaction atomicity.

Not `ROLLBACK`. These tests kill the backend process with
pg_terminate_backend(), so the database sees what it would see if the machine
had lost power mid-posting: a connection that stops existing with work in
flight. A test that called ROLLBACK would be testing that PostgreSQL implements
ROLLBACK, which nobody doubts.

The claim under test: a partial posting is impossible. Kill a backend between
the first leg and the second and the result is not a half-posted transaction —
it is no transaction at all, an unmoved balance cache, and a deferred check that
never ran.
"""

from __future__ import annotations

import json
from uuid import uuid4

import psycopg
from hypothesis import given, settings
from hypothesis import strategies as st

from chart import CURRENCY, escrow_for, open_chart
from conftest import reset_ledger
from ledger_api import Ledger, authorize_entries, fingerprint_of


def kill(admin: psycopg.Connection, pid: int) -> None:
    """Terminate a backend and wait for it to actually be gone.

    The two-argument form waits up to the timeout for the process to exit, so
    the assertions that follow cannot race the abort.
    """
    with admin.cursor() as cur:
        cur.execute("SELECT pg_terminate_backend(%s, 5000)", (pid,))
        assert cur.fetchone()[0] is True, "backend did not terminate"


def backend_pid(conn: psycopg.Connection) -> int:
    with conn.cursor() as cur:
        cur.execute("SELECT pg_backend_pid()")
        return cur.fetchone()[0]


def fires(admin: psycopg.Connection) -> int:
    with admin.cursor() as cur:
        cur.execute("SELECT ledger_deferred_check_count()")
        return cur.fetchone()[0]


def snapshot(admin: psycopg.Connection) -> dict:
    with admin.cursor() as cur:
        cur.execute("""
            SELECT (SELECT count(*) FROM ledger_entries),
                   (SELECT count(*) FROM ledger_transactions),
                   (SELECT COALESCE(jsonb_object_agg(account_id::text, balance_minor), '{}'::jsonb)
                      FROM ledger_balances),
                   (SELECT count(*) FROM ledger_verify_balances())
        """)
        entries, txns, balances, mismatches = cur.fetchone()
    return {"entries": entries, "transactions": txns,
            "balances": balances, "mismatches": mismatches}


def _die_quietly(conn: psycopg.Connection) -> None:
    try:
        conn.close()
    except psycopg.Error:
        pass


# ===========================================================================
# Transaction atomicity
# ===========================================================================

def test_a_crash_between_the_two_legs_leaves_no_partial_posting(
        ledger: Ledger, admin_conn: psycopg.Connection, ledger_db: str):
    """The core claim. Insert leg one, kill the backend, inspect the wreckage."""
    chart = open_chart(ledger)
    before = snapshot(admin_conn)
    tx_id = uuid4()

    victim = psycopg.connect(ledger_db)
    pid = backend_pid(victim)
    with victim.cursor() as cur:
        cur.execute(
            "INSERT INTO ledger_transactions "
            "(id, business_event_type, business_event_id, idempotency_key, request_fingerprint) "
            "VALUES (%s, 'authorize', %s, %s, 'fp')", (tx_id, uuid4(), f"k:{tx_id}"))
        cur.execute(
            "INSERT INTO ledger_entries (transaction_id, account_id, direction, amount_minor, currency) "
            "VALUES (%s, %s, 'debit', 5000, %s)", (tx_id, chart.receivable, CURRENCY))
        # Leg one is in, and inside this transaction the ledger is unbalanced.
        cur.execute("SELECT count(*) FROM ledger_entries WHERE transaction_id = %s", (tx_id,))
        assert cur.fetchone()[0] == 1

    fires_before = fires(admin_conn)
    kill(admin_conn, pid)                       # <- the crash, between the legs
    _die_quietly(victim)

    after = snapshot(admin_conn)
    assert after["entries"] == before["entries"] == 0
    assert after["transactions"] == before["transactions"] == 0
    assert after["balances"] == before["balances"]
    assert after["mismatches"] == 0
    assert fires(admin_conn) == fires_before, \
        "the deferred check must never have run: the transaction never reached COMMIT"

    with admin_conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM ledger_entries WHERE transaction_id = %s", (tx_id,))
        assert cur.fetchone()[0] == 0


def test_the_fire_counter_is_not_vacuous(ledger: Ledger, admin_conn: psycopg.Connection):
    """Control for the assertion above.

    "The deferred check never fired" only means something if the counter moves
    when it does fire. Commit a real posting and require it to move.
    """
    chart = open_chart(ledger)
    escrow = escrow_for(ledger, uuid4())
    before = fires(admin_conn)

    entries = authorize_entries(chart.receivable, escrow, 5000, CURRENCY)
    ledger.post(f"k:{uuid4()}", fingerprint_of(entries), "authorize", uuid4(), entries)

    assert fires(admin_conn) == before + len(entries), \
        "one fire per inserted row, at COMMIT"


def test_a_crash_after_a_complete_valid_posting_still_loses_it(
        ledger: Ledger, admin_conn: psycopg.Connection, ledger_db: str):
    """A posting that was valid and complete but never committed is not money.
    Durability starts at COMMIT, not at the last INSERT."""
    chart = open_chart(ledger)
    escrow = escrow_for(ledger, uuid4())
    entries = authorize_entries(chart.receivable, escrow, 5000, CURRENCY)
    before = snapshot(admin_conn)
    fires_before = fires(admin_conn)

    victim = psycopg.connect(ledger_db)
    pid = backend_pid(victim)
    with victim.cursor() as cur:
        cur.execute(
            "SELECT transaction_id FROM ledger_post(%s, %s, 'authorize', %s::uuid, %s::jsonb)",
            (f"k:{uuid4()}", fingerprint_of(entries), uuid4(),
             json.dumps([e.as_json() for e in entries])))
        # Both legs are in and the balance cache has already moved — inside this
        # transaction.
        cur.execute("SELECT balance_minor FROM ledger_balances WHERE account_id = %s", (escrow,))
        assert cur.fetchone()[0] == -5000

    kill(admin_conn, pid)
    _die_quietly(victim)

    assert snapshot(admin_conn) == before
    assert fires(admin_conn) == fires_before, "COMMIT never happened, so no check ran"


def test_a_crash_leaves_the_balance_cache_exactly_where_it_was(
        ledger: Ledger, admin_conn: psycopg.Connection, ledger_db: str):
    """The cache is the thing most likely to be left inconsistent by a crash,
    because it is derived state. It is updated by a trigger inside the same
    transaction, so it rolls back with everything else."""
    chart = open_chart(ledger)
    order = uuid4()
    escrow = escrow_for(ledger, order)
    entries = authorize_entries(chart.receivable, escrow, 7500, CURRENCY)
    ledger.post(f"k:{uuid4()}", fingerprint_of(entries), "authorize", order, entries)
    committed = snapshot(admin_conn)
    assert committed["balances"][str(escrow)] == -7500

    victim = psycopg.connect(ledger_db)
    pid = backend_pid(victim)
    more = authorize_entries(chart.receivable, escrow, 1234, CURRENCY)
    with victim.cursor() as cur:
        cur.execute(
            "SELECT transaction_id FROM ledger_post(%s, %s, 'authorize', %s::uuid, %s::jsonb)",
            (f"k:{uuid4()}", fingerprint_of(more), order, json.dumps([e.as_json() for e in more])))
    kill(admin_conn, pid)
    _die_quietly(victim)

    after = snapshot(admin_conn)
    assert after == committed
    assert after["mismatches"] == 0


def test_a_crash_frees_the_idempotency_key_it_had_claimed(
        ledger: Ledger, admin_conn: psycopg.Connection, ledger_db: str):
    """A crashed attempt must not poison its own retry. The uniqueness of the
    idempotency key is transactional, so the key is free again afterwards and
    the retry writes the posting for real."""
    chart = open_chart(ledger)
    escrow = escrow_for(ledger, uuid4())
    entries = authorize_entries(chart.receivable, escrow, 5000, CURRENCY)
    key, fp = f"k:{uuid4()}", fingerprint_of(entries)

    victim = psycopg.connect(ledger_db)
    pid = backend_pid(victim)
    with victim.cursor() as cur:
        cur.execute(
            "SELECT transaction_id FROM ledger_post(%s, %s, 'authorize', %s::uuid, %s::jsonb)",
            (key, fp, uuid4(), json.dumps([e.as_json() for e in entries])))
    kill(admin_conn, pid)
    _die_quietly(victim)

    retry = ledger.post(key, fp, "authorize", uuid4(), entries)
    assert retry.replayed is False, "the crashed attempt left nothing to replay"
    assert ledger.natural_balance(escrow) == 5000
    assert ledger.verify_balances() == []


# ===========================================================================
# Randomised crash point
# ===========================================================================

@settings(max_examples=12, deadline=None)
@given(committed=st.integers(min_value=0, max_value=6),
       amounts=st.lists(st.integers(min_value=1, max_value=50_000),
                        min_size=7, max_size=7))
def test_crashing_at_any_point_in_a_run_of_postings_loses_only_the_last(
        ledger_db: str, committed: int, amounts: list[int]):
    """Post `committed` transactions successfully, then start one more and die.

    Whatever the crash point, the ledger contains exactly the postings that
    committed, balances match their sum, and conservation still holds.
    """
    with psycopg.connect(ledger_db) as conn, psycopg.connect(ledger_db, autocommit=True) as admin:
        reset_ledger(conn)
        ledger = Ledger(conn)
        chart = open_chart(ledger)
        order = uuid4()
        escrow = escrow_for(ledger, order)

        for amount in amounts[:committed]:
            entries = authorize_entries(chart.receivable, escrow, amount, CURRENCY)
            ledger.post(f"k:{uuid4()}", fingerprint_of(entries), "authorize", order, entries)

        expected = sum(amounts[:committed])
        assert ledger.natural_balance(escrow) == expected

        victim = psycopg.connect(ledger_db)
        pid = backend_pid(victim)
        doomed = authorize_entries(chart.receivable, escrow, amounts[committed], CURRENCY)
        with victim.cursor() as cur:
            cur.execute(
                "SELECT transaction_id FROM ledger_post(%s, %s, 'authorize', %s::uuid, %s::jsonb)",
                (f"k:{uuid4()}", fingerprint_of(doomed), order,
                 json.dumps([e.as_json() for e in doomed])))
        fires_before = fires(admin)
        kill(admin, pid)
        _die_quietly(victim)

        assert fires(admin) == fires_before
        assert ledger.natural_balance(escrow) == expected
        assert ledger.scalar("SELECT count(*) FROM ledger_entries") == 2 * committed
        assert ledger.verify_balances() == []
        assert ledger.scalar(
            "SELECT COALESCE(SUM(CASE WHEN direction='debit' THEN amount_minor "
            "ELSE -amount_minor END), 0) FROM ledger_entries") == 0
