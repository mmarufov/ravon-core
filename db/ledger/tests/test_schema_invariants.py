"""The six invariants, each tested directly against PostgreSQL.

Every claim in db/ledger/README.md has a test in here or in one of the sibling
files, and each test is written so that it fails if the claim stops being true —
not merely if the code changes.
"""

from __future__ import annotations

from uuid import uuid4

import psycopg
import pytest

from chart import CURRENCY, escrow_for, open_chart, wallet_for
from ledger_api import (Ledger, LedgerError, authorize_entries, credit, debit,
                        fingerprint_of, refund_entries)


def _post(ledger: Ledger, entries, event="test", key=None):
    key = key or f"k:{uuid4()}"
    return ledger.post(key, fingerprint_of(entries), event, uuid4(), entries)


# ===========================================================================
# INVARIANT 1 — balanced at COMMIT
# ===========================================================================

def test_balanced_posting_commits(ledger: Ledger):
    chart = open_chart(ledger)
    order = uuid4()
    escrow = escrow_for(ledger, order)

    result = _post(ledger, authorize_entries(chart.receivable, escrow, 5000, CURRENCY))

    assert result.replayed is False
    assert ledger.natural_balance(escrow) == 5000
    assert ledger.natural_balance(chart.receivable) == 5000


def test_unbalanced_posting_is_rejected(ledger: Ledger):
    chart = open_chart(ledger)
    escrow = escrow_for(ledger, uuid4())
    entries = [debit(chart.receivable, 5000, CURRENCY), credit(escrow, 4999, CURRENCY)]

    with pytest.raises(LedgerError) as exc:
        _post(ledger, entries)

    assert exc.value.reason == "UNBALANCED_TRANSACTION"
    assert exc.value.detail["delta_minor"] == 1
    assert ledger.scalar("SELECT count(*) FROM ledger_entries") == 0


def test_the_check_is_deferred_to_commit_not_run_at_insert(ledger: Ledger):
    """The deferral is the design, so it gets its own test.

    Inside the transaction, a half-posted (therefore unbalanced) set of entries
    is perfectly visible. Only COMMIT rejects it. If someone "fixed" the trigger
    by making it immediate, this test fails — and so would every legal posting.
    """
    chart = open_chart(ledger)
    escrow = escrow_for(ledger, uuid4())
    tx_id = uuid4()
    conn = ledger.conn

    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO ledger_transactions "
            "(id, business_event_type, business_event_id, idempotency_key, request_fingerprint) "
            "VALUES (%s, 'authorize', %s, %s, 'fp')",
            (tx_id, uuid4(), f"k:{tx_id}"))
        cur.execute(
            "INSERT INTO ledger_entries (transaction_id, account_id, direction, amount_minor, currency) "
            "VALUES (%s, %s, 'debit', 5000, %s)",
            (tx_id, chart.receivable, CURRENCY))

        # One leg in, unbalanced, and the database is perfectly happy about it.
        cur.execute("SELECT count(*) FROM ledger_entries WHERE transaction_id = %s", (tx_id,))
        assert cur.fetchone()[0] == 1

    fires_before = _deferred_fires(conn)

    with pytest.raises(psycopg.Error) as exc:
        conn.commit()
    conn.rollback()

    assert LedgerError.from_psycopg(exc.value).reason == "UNBALANCED_TRANSACTION"
    assert _deferred_fires(conn) > fires_before, "the deferred trigger should have run at COMMIT"
    assert ledger.scalar("SELECT count(*) FROM ledger_entries") == 0


def test_forcing_the_constraint_immediate_moves_the_error_earlier(ledger: Ledger):
    """The escape hatch documented for the service tier.

    A caller that would rather fail at post time than at commit time can promote
    the constraint. HANDOFF-for-kotlin.md tells the Kotlin service this exists.
    """
    chart = open_chart(ledger)
    escrow = escrow_for(ledger, uuid4())
    conn = ledger.conn

    with conn.cursor() as cur:
        cur.execute("SET CONSTRAINTS ledger_entries_balanced_at_commit IMMEDIATE")
        with pytest.raises(psycopg.Error) as exc:
            cur.execute(
                "SELECT transaction_id FROM ledger_post(%s, 'fp', 'authorize', %s::uuid, %s::jsonb)",
                (f"k:{uuid4()}", uuid4(),
                 '[{"account_id":"%s","direction":"debit","amount_minor":10,"currency":"%s"},'
                 ' {"account_id":"%s","direction":"credit","amount_minor":9,"currency":"%s"}]'
                 % (chart.receivable, CURRENCY, escrow, CURRENCY)))
    conn.rollback()

    assert LedgerError.from_psycopg(exc.value).reason == "UNBALANCED_TRANSACTION"


def test_transaction_with_no_entries_is_rejected(ledger: Ledger):
    """A transaction row with zero entries would satisfy "debits = credits"
    vacuously. It is caught by its own deferred trigger."""
    conn = ledger.conn
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO ledger_transactions "
            "(business_event_type, business_event_id, idempotency_key, request_fingerprint) "
            "VALUES ('orphan', %s, %s, 'fp')", (uuid4(), f"k:{uuid4()}"))

    with pytest.raises(psycopg.Error) as exc:
        conn.commit()
    conn.rollback()

    assert LedgerError.from_psycopg(exc.value).reason == "DEGENERATE_TRANSACTION"


# ===========================================================================
# INVARIANT 2 — one currency per transaction
# ===========================================================================

def test_mixed_currency_transaction_is_rejected(ledger: Ledger):
    """Both legs match their own account's currency, and the minor units even
    cancel out — so only a transaction-level check can catch this."""
    tjs_clearing = ledger.open_account("psp_clearing", None, "TJS", allow_negative=True)
    usd_clearing = ledger.open_account("psp_clearing", None, "USD", allow_negative=True)

    with pytest.raises(LedgerError) as exc:
        _post(ledger, [debit(tjs_clearing, 100, "TJS"), credit(usd_clearing, 100, "USD")])

    assert exc.value.reason == "MIXED_CURRENCY_TRANSACTION"
    assert sorted(exc.value.detail["currencies"]) == ["TJS", "USD"]
    assert ledger.scalar("SELECT count(*) FROM ledger_entries") == 0


def test_entry_currency_must_match_its_account(ledger: Ledger):
    chart = open_chart(ledger)
    escrow = escrow_for(ledger, uuid4())

    with pytest.raises(LedgerError) as exc:
        _post(ledger, [debit(chart.receivable, 100, "USD"), credit(escrow, 100, "USD")])

    assert exc.value.reason == "CURRENCY_MISMATCH_ACCOUNT"


# ===========================================================================
# INVARIANT 3 — immutability
# ===========================================================================

@pytest.mark.parametrize("statement", [
    "UPDATE ledger_entries SET amount_minor = 1",
    "DELETE FROM ledger_entries",
    "UPDATE ledger_transactions SET request_fingerprint = 'tampered'",
    "DELETE FROM ledger_transactions",
])
def test_history_cannot_be_mutated_even_by_the_owner(ledger: Ledger, statement: str):
    """The REVOKEs stop the application role. This trigger stops everyone —
    including the connection running these tests, which is a superuser."""
    chart = open_chart(ledger)
    escrow = escrow_for(ledger, uuid4())
    _post(ledger, authorize_entries(chart.receivable, escrow, 5000, CURRENCY))

    with pytest.raises(psycopg.Error) as exc:
        with ledger.conn.cursor() as cur:
            cur.execute(statement)
    ledger.conn.rollback()

    assert LedgerError.from_psycopg(exc.value).reason == "LEDGER_IMMUTABLE"
    assert ledger.scalar("SELECT count(*) FROM ledger_entries") == 2


def test_corrections_are_reversing_entries(ledger: Ledger):
    """The supported way to undo a posting: a new transaction with the legs
    swapped. History grows; it never shrinks."""
    chart = open_chart(ledger)
    order = uuid4()
    escrow = escrow_for(ledger, order)

    _post(ledger, authorize_entries(chart.receivable, escrow, 5000, CURRENCY))
    _post(ledger, [credit(chart.receivable, 5000, CURRENCY), debit(escrow, 5000, CURRENCY)])

    assert ledger.natural_balance(escrow) == 0
    assert ledger.natural_balance(chart.receivable) == 0
    assert ledger.scalar("SELECT count(*) FROM ledger_entries") == 4, "nothing was erased"


def test_truncate_bypasses_the_row_level_trigger(ledger: Ledger):
    """A negative result, kept as a test because it explains a line in schema.sql.

    TRUNCATE does not fire row-level DELETE triggers. The immutability trigger
    therefore does NOT protect against it, and the only thing standing between a
    misconfigured role and an erased ledger is the explicit REVOKE TRUNCATE.
    If PostgreSQL ever changes this, this test fails and the REVOKE can be
    relaxed to a comment.
    """
    chart = open_chart(ledger)
    escrow = escrow_for(ledger, uuid4())
    _post(ledger, authorize_entries(chart.receivable, escrow, 5000, CURRENCY))

    with ledger.conn.cursor() as cur:
        cur.execute("TRUNCATE ledger_entries CASCADE")     # succeeds — no trigger fires
    ledger.conn.commit()

    assert ledger.scalar("SELECT count(*) FROM ledger_entries") == 0


# ===========================================================================
# INVARIANT 4 — no negative balances
# ===========================================================================

def test_over_refund_is_rejected(ledger: Ledger):
    chart = open_chart(ledger)
    order = uuid4()
    escrow = escrow_for(ledger, order)
    _post(ledger, authorize_entries(chart.receivable, escrow, 5000, CURRENCY))

    with pytest.raises(LedgerError) as exc:
        _post(ledger, refund_entries(escrow, chart.clearing, 5001, CURRENCY), event="refund")

    assert exc.value.reason == "NEGATIVE_BALANCE_NOT_ALLOWED"
    assert exc.value.http_status == 409
    assert exc.value.detail["attempted_balance_minor"] == -1
    assert ledger.natural_balance(escrow) == 5000, "the rejected refund left no trace"


def test_refund_of_exactly_the_balance_is_allowed(ledger: Ledger):
    """The boundary, because off-by-one here is the whole bug class."""
    chart = open_chart(ledger)
    escrow = escrow_for(ledger, uuid4())
    _post(ledger, authorize_entries(chart.receivable, escrow, 5000, CURRENCY))

    _post(ledger, refund_entries(escrow, chart.clearing, 5000, CURRENCY), event="refund")

    assert ledger.natural_balance(escrow) == 0


def test_allow_negative_accounts_may_go_negative(ledger: Ledger):
    """The flag is not decoration: a clearing account really does go negative."""
    chart = open_chart(ledger)
    escrow = escrow_for(ledger, uuid4())
    _post(ledger, [debit(escrow, 100, CURRENCY), credit(chart.clearing, 100, CURRENCY)])

    assert ledger.natural_balance(chart.clearing) == -100


def test_a_posting_that_dips_and_recovers_within_itself_is_allowed(ledger: Ledger):
    """The balance check sees the whole posting, not intermediate states: one
    transaction may debit an account to below zero and credit it back."""
    chart = open_chart(ledger)
    escrow = escrow_for(ledger, uuid4())
    entries = [
        debit(escrow, 100, CURRENCY),            # escrow starts at 0 — this alone is illegal
        credit(escrow, 300, CURRENCY),
        debit(chart.receivable, 200, CURRENCY),
    ]
    _post(ledger, entries)

    assert ledger.natural_balance(escrow) == 200


def test_negative_balance_check_uses_the_natural_sign(ledger: Ledger):
    """A funded consumer wallet has a *negative* signed balance, because it is a
    liability funded by credits. allow_negative must not trip on that."""
    chart = open_chart(ledger)
    wallet = wallet_for(ledger, uuid4())
    _post(ledger, [debit(chart.promo_expense, 2500, CURRENCY), credit(wallet, 2500, CURRENCY)])

    assert ledger.signed_balance(wallet) == -2500
    assert ledger.natural_balance(wallet) == 2500


# ===========================================================================
# INVARIANT 5 — the cache equals the truth
# ===========================================================================

def test_verify_balances_is_clean_after_normal_use(ledger: Ledger):
    chart = open_chart(ledger)
    escrow = escrow_for(ledger, uuid4())
    for amount in (100, 250, 999):
        _post(ledger, authorize_entries(chart.receivable, escrow, amount, CURRENCY))

    assert ledger.verify_balances() == []


def test_verify_balances_actually_detects_a_corrupted_cache(ledger: Ledger):
    """Without this test, ledger_verify_balances() could be `SELECT` of nothing
    and every other test would still pass. Corrupt the cache on purpose and
    require the function to name the account and the exact drift."""
    chart = open_chart(ledger)
    escrow = escrow_for(ledger, uuid4())
    _post(ledger, authorize_entries(chart.receivable, escrow, 5000, CURRENCY))

    with ledger.conn.cursor() as cur:
        cur.execute("UPDATE ledger_balances SET balance_minor = balance_minor + 7 "
                    "WHERE account_id = %s", (escrow,))
    ledger.conn.commit()

    mismatches = ledger.verify_balances()
    assert len(mismatches) == 1
    account_id, kind, cached, actual, delta = mismatches[0]
    assert account_id == escrow
    assert kind == "order_escrow"
    assert cached - actual == 7
    assert delta == 7


def test_balance_cache_cannot_be_written_around(ledger: Ledger):
    """Entries and cache move together because a trigger, not the caller, moves
    the cache. Even a direct INSERT of a balanced pair updates it."""
    chart = open_chart(ledger)
    escrow = escrow_for(ledger, uuid4())
    tx_id = uuid4()

    with ledger.conn.cursor() as cur:
        cur.execute(
            "INSERT INTO ledger_transactions "
            "(id, business_event_type, business_event_id, idempotency_key, request_fingerprint) "
            "VALUES (%s, 'raw', %s, %s, 'fp')", (tx_id, uuid4(), f"k:{tx_id}"))
        cur.execute(
            "INSERT INTO ledger_entries (transaction_id, account_id, direction, amount_minor, currency) "
            "VALUES (%s, %s, 'debit', 77, %s), (%s, %s, 'credit', 77, %s)",
            (tx_id, chart.receivable, CURRENCY, tx_id, escrow, CURRENCY))
    ledger.conn.commit()

    assert ledger.natural_balance(escrow) == 77
    assert ledger.verify_balances() == []


# ===========================================================================
# Schema-level guarantees
# ===========================================================================

def test_no_floating_point_columns_anywhere(ledger: Ledger):
    """Integer minor units only. Binary floating point cannot represent 0.10,
    and a ledger that cannot represent ten cents is not a ledger."""
    rows = ledger.query("""
        SELECT c.table_name, c.column_name, c.data_type
        FROM information_schema.columns c
        JOIN information_schema.tables t
          ON t.table_name = c.table_name AND t.table_schema = c.table_schema
        WHERE c.table_schema = 'public'
          AND t.table_type = 'BASE TABLE'
          AND c.table_name LIKE 'ledger_%'
          AND c.data_type IN ('real', 'double precision', 'numeric', 'money')
    """)
    assert rows == []


def test_amount_must_be_strictly_positive(ledger: Ledger):
    """Direction carries the sign. A zero or negative amount_minor would let the
    same movement be expressed two ways, which is how sign bugs start."""
    chart = open_chart(ledger)
    escrow = escrow_for(ledger, uuid4())

    for bad in (0, -1):
        with pytest.raises(LedgerError) as exc:
            _post(ledger, [debit(chart.receivable, bad, CURRENCY),
                           credit(escrow, bad, CURRENCY)])
        assert exc.value.reason in {"INVALID_ENTRY", "INVALID_ENTRY_SET"}


def test_single_leg_posting_is_rejected(ledger: Ledger):
    chart = open_chart(ledger)
    with pytest.raises(LedgerError) as exc:
        _post(ledger, [debit(chart.receivable, 100, CURRENCY)])
    assert exc.value.reason == "INVALID_ENTRY_SET"


def test_unknown_account_is_a_404_not_a_constraint_violation(ledger: Ledger):
    chart = open_chart(ledger)
    with pytest.raises(LedgerError) as exc:
        _post(ledger, [debit(chart.receivable, 100, CURRENCY),
                       credit(uuid4(), 100, CURRENCY)])
    assert exc.value.reason == "UNKNOWN_ACCOUNT"
    assert exc.value.http_status == 404


def test_malformed_entries_are_structured_errors_not_cast_failures(ledger: Ledger):
    """PostgreSQL does not promise left-to-right evaluation of an OR chain, so a
    ::bigint in the validation predicate could raise 22P02 on junk before the
    guard meant to reject it ever ran. These must all come back as INVALID_ENTRY."""
    chart = open_chart(ledger)
    escrow = escrow_for(ledger, uuid4())
    good = {"account_id": str(escrow), "direction": "credit",
            "amount_minor": 100, "currency": CURRENCY}
    bad_legs = [
        {"account_id": str(chart.receivable), "direction": "debit",
         "amount_minor": "abc", "currency": CURRENCY},
        {"account_id": "not-a-uuid", "direction": "debit",
         "amount_minor": 100, "currency": CURRENCY},
        {"account_id": str(chart.receivable), "direction": "debit",
         "amount_minor": 100.5, "currency": CURRENCY},
        {"account_id": str(chart.receivable), "direction": "sideways",
         "amount_minor": 100, "currency": CURRENCY},
        {"account_id": str(chart.receivable), "direction": "debit",
         "amount_minor": 100, "currency": "TOOLONG"},
        {"account_id": str(chart.receivable), "direction": "debit",
         "amount_minor": 10 ** 19, "currency": CURRENCY},
    ]

    import json
    for leg in bad_legs:
        with pytest.raises(psycopg.Error) as exc:
            with ledger.conn.cursor() as cur:
                cur.execute(
                    "SELECT transaction_id FROM ledger_post(%s, 'fp', 'x', %s::uuid, %s::jsonb)",
                    (f"k:{uuid4()}", uuid4(), json.dumps([leg, good])))
        ledger.conn.rollback()
        err = LedgerError.from_psycopg(exc.value)
        assert err.reason == "INVALID_ENTRY", f"{leg} produced {err.sqlstate}/{err.reason}"


def test_one_account_per_party_and_currency(ledger: Ledger):
    """Two wallets for one consumer in one currency would silently halve their
    balance, so opening is idempotent rather than merely discouraged."""
    consumer = uuid4()
    first = wallet_for(ledger, consumer)
    second = wallet_for(ledger, consumer)
    assert first == second

    other_currency = ledger.open_account("consumer_wallet", consumer, "USD")
    assert other_currency != first


def _deferred_fires(conn: psycopg.Connection) -> int:
    """Read the non-transactional trigger-fire counter without disturbing the
    caller's transaction state."""
    with conn.cursor() as cur:
        cur.execute("SELECT ledger_deferred_check_count()")
        return cur.fetchone()[0]
