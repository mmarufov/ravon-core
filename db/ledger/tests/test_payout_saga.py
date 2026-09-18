"""Crash injection: saga resumability.

A payout is not one database transaction. It is:

    create pending  ->  call the provider  ->  mark submitted  ->  post entries

The provider call is outside the database and can be lost, so the saga has real
boundaries where a crash leaves durable half-finished state. These tests kill
the backend at *every* one of those boundaries, run the resume path, and require
the same thing each time: exactly one ledger effect, identified by the payout's
idempotency key.

"Exactly one" is the whole point. Paying a courier twice because a retry ran is
the failure this design exists to prevent.
"""

from __future__ import annotations

from uuid import UUID, uuid4

import psycopg
import pytest

from chart import CURRENCY, courier_payable_for, open_chart
from ledger_api import Ledger, LedgerError, credit, debit, fingerprint_of
from test_crash_atomicity import _die_quietly, backend_pid, kill

# Every boundary at which the process can die, in order.
CRASH_POINTS = [
    "during_begin",           # the pending row was never durably written
    "after_begin",            # pending exists, provider never called
    "after_provider_call",    # provider accepted it, we never recorded that
    "after_mark_submitted",   # submitted, entries never posted
    "during_post",            # entries inserted but the commit never landed
    "after_post",             # fully done; resume must be a no-op
    "never",                  # control: no crash at all
]

AMOUNT = 4_200
FUNDING = 10_000


def _fund_courier(ledger: Ledger, chart, courier_id: UUID) -> UUID:
    """Give the courier something to be paid out of."""
    payable = courier_payable_for(ledger, courier_id)
    entries = [debit(chart.revenue, FUNDING, CURRENCY), credit(payable, FUNDING, CURRENCY)]
    ledger.post(f"fund:{uuid4()}", fingerprint_of(entries), "settlement", uuid4(), entries)
    return payable


def _payout_transactions(ledger: Ledger, payout_id: UUID) -> list[UUID]:
    return [row[0] for row in ledger.query(
        "SELECT id FROM ledger_transactions "
        "WHERE business_event_type = 'payout' AND business_event_id = %s", (payout_id,))]


@pytest.mark.parametrize("crash_point", CRASH_POINTS)
def test_payout_survives_a_crash_at_every_step_boundary(
        ledger: Ledger, admin_conn: psycopg.Connection, ledger_db: str, crash_point: str):
    chart = open_chart(ledger)
    courier_id = uuid4()
    payable = _fund_courier(ledger, chart, courier_id)
    request_id = f"payout-req:{uuid4()}"
    provider_ref = f"provider-ref:{uuid4()}"

    def crash_now(run) -> None:
        """Do `run` on a doomed connection, then kill it before it commits."""
        victim = psycopg.connect(ledger_db)
        pid = backend_pid(victim)
        run(victim)
        kill(admin_conn, pid)
        _die_quietly(victim)

    # ---- step 1: reserve the payout --------------------------------------
    if crash_point == "during_begin":
        crash_now(lambda c: c.execute(
            "SELECT ledger_payout_begin(%s, %s::uuid, %s::uuid, %s::bigint, %s::char(3))",
            (request_id, payable, chart.clearing, AMOUNT, CURRENCY)))
        assert ledger.scalar(
            "SELECT count(*) FROM ledger_payouts WHERE request_id = %s", (request_id,)) == 0

    payout_id = ledger.payout_begin(request_id, payable, chart.clearing, AMOUNT, CURRENCY)
    assert ledger.payout_state(payout_id) == "pending"
    assert _payout_transactions(ledger, payout_id) == [], "reserving moves no money"

    if crash_point == "after_begin":
        # Recovery asks the provider "did you ever see this?" and is told no.
        # Nothing was ever posted, so the payout just fails.
        assert ledger.payout_resume(payout_id, None) == "failed"
        assert _payout_transactions(ledger, payout_id) == []
        assert ledger.natural_balance(payable) == FUNDING
        return

    # ---- step 2: the external provider call (simulated) -------------------
    if crash_point == "after_provider_call":
        # The provider accepted it but we died before writing that down. Recovery
        # learns the ref by asking the provider, and drives the saga forward.
        assert ledger.payout_state(payout_id) == "pending"
        assert ledger.payout_resume(payout_id, provider_ref) == "posted"
        _assert_settled_exactly_once(ledger, payout_id, payable)
        return

    # ---- step 3: record that the provider accepted it --------------------
    assert ledger.payout_mark_submitted(payout_id, provider_ref) == "submitted"
    assert _payout_transactions(ledger, payout_id) == [], "submitting moves no money either"

    if crash_point == "after_mark_submitted":
        assert ledger.payout_resume(payout_id, provider_ref) == "posted"
        _assert_settled_exactly_once(ledger, payout_id, payable)
        return

    # ---- step 4: post the money movement ---------------------------------
    if crash_point == "during_post":
        crash_now(lambda c: c.execute("SELECT transaction_id FROM ledger_payout_post(%s::uuid)",
                                      (payout_id,)))
        assert ledger.payout_state(payout_id) == "submitted", "the crash rolled the state back too"
        assert _payout_transactions(ledger, payout_id) == []
        assert ledger.natural_balance(payable) == FUNDING

        assert ledger.payout_resume(payout_id, provider_ref) == "posted"
        _assert_settled_exactly_once(ledger, payout_id, payable)
        return

    result = ledger.payout_post(payout_id)
    assert result.replayed is False

    if crash_point == "after_post":
        # A recovery job that cannot tell whether it already ran must be safe to
        # run again. Several times.
        for _ in range(3):
            assert ledger.payout_resume(payout_id, provider_ref) == "posted"

    _assert_settled_exactly_once(ledger, payout_id, payable)


def _assert_settled_exactly_once(ledger: Ledger, payout_id: UUID, payable: UUID) -> None:
    transactions = _payout_transactions(ledger, payout_id)
    assert len(transactions) == 1, f"expected exactly one ledger effect, got {transactions}"
    assert ledger.payout_state(payout_id) == "posted"
    assert ledger.natural_balance(payable) == FUNDING - AMOUNT
    assert ledger.verify_balances() == []
    assert ledger.scalar(
        "SELECT COALESCE(SUM(CASE WHEN direction='debit' THEN amount_minor "
        "ELSE -amount_minor END), 0) FROM ledger_entries") == 0


def test_resuming_a_posted_payout_many_times_is_free(ledger: Ledger):
    """Idempotency at the saga level, not just the posting level."""
    chart = open_chart(ledger)
    courier_id = uuid4()
    payable = _fund_courier(ledger, chart, courier_id)
    payout_id = ledger.payout_begin(f"r:{uuid4()}", payable, chart.clearing, AMOUNT, CURRENCY)
    ledger.payout_mark_submitted(payout_id, "ref")
    first = ledger.payout_post(payout_id)

    for _ in range(5):
        again = ledger.payout_post(payout_id)
        assert again.replayed is True
        assert again.transaction_id == first.transaction_id

    _assert_settled_exactly_once(ledger, payout_id, payable)


def test_beginning_the_same_payout_twice_reserves_it_once(ledger: Ledger):
    chart = open_chart(ledger)
    payable = _fund_courier(ledger, chart, uuid4())
    request_id = f"r:{uuid4()}"

    first = ledger.payout_begin(request_id, payable, chart.clearing, AMOUNT, CURRENCY)
    second = ledger.payout_begin(request_id, payable, chart.clearing, AMOUNT, CURRENCY)

    assert first == second
    assert ledger.scalar("SELECT count(*) FROM ledger_payouts") == 1


def test_posting_before_the_provider_accepted_is_refused(ledger: Ledger):
    """The ordering constraint is enforced, not assumed: no money moves until
    the provider has said yes."""
    chart = open_chart(ledger)
    payable = _fund_courier(ledger, chart, uuid4())
    payout_id = ledger.payout_begin(f"r:{uuid4()}", payable, chart.clearing, AMOUNT, CURRENCY)

    with pytest.raises(LedgerError) as exc:
        ledger.payout_post(payout_id)

    assert exc.value.reason == "PAYOUT_NOT_SUBMITTED"
    assert _payout_transactions(ledger, payout_id) == []


def test_payout_failure_before_posting_has_no_ledger_effect(ledger: Ledger):
    chart = open_chart(ledger)
    payable = _fund_courier(ledger, chart, uuid4())
    payout_id = ledger.payout_begin(f"r:{uuid4()}", payable, chart.clearing, AMOUNT, CURRENCY)
    ledger.payout_mark_submitted(payout_id, "ref")

    assert ledger.payout_fail(payout_id, "provider declined") == "failed"

    assert ledger.scalar("SELECT count(*) FROM ledger_entries") == 2  # only the funding
    assert ledger.natural_balance(payable) == FUNDING


def test_payout_reversal_after_posting_is_a_reversing_entry(ledger: Ledger):
    """A payout that fails after it was posted is corrected the only way the
    ledger permits: a new transaction with the legs swapped."""
    chart = open_chart(ledger)
    payable = _fund_courier(ledger, chart, uuid4())
    payout_id = ledger.payout_begin(f"r:{uuid4()}", payable, chart.clearing, AMOUNT, CURRENCY)
    ledger.payout_mark_submitted(payout_id, "ref")
    posted = ledger.payout_post(payout_id)
    assert ledger.natural_balance(payable) == FUNDING - AMOUNT

    assert ledger.payout_fail(payout_id, "bank returned it") == "failed"

    assert ledger.natural_balance(payable) == FUNDING, "the courier is whole again"
    reversal = ledger.scalar(
        "SELECT reversal_transaction_id FROM ledger_payouts WHERE id = %s", (payout_id,))
    assert reversal is not None and reversal != posted.transaction_id
    assert ledger.scalar(
        "SELECT count(*) FROM ledger_entries WHERE transaction_id = %s",
        (posted.transaction_id,)) == 2, "the original posting was not touched"
    assert ledger.verify_balances() == []


def test_failing_a_payout_twice_reverses_it_once(ledger: Ledger):
    chart = open_chart(ledger)
    payable = _fund_courier(ledger, chart, uuid4())
    payout_id = ledger.payout_begin(f"r:{uuid4()}", payable, chart.clearing, AMOUNT, CURRENCY)
    ledger.payout_mark_submitted(payout_id, "ref")
    ledger.payout_post(payout_id)

    for _ in range(4):
        assert ledger.payout_fail(payout_id, "bank returned it") == "failed"

    assert ledger.natural_balance(payable) == FUNDING
    assert ledger.scalar(
        "SELECT count(*) FROM ledger_transactions WHERE business_event_type = 'payout_reversal'") == 1


def test_a_payout_larger_than_the_balance_is_refused(ledger: Ledger):
    """Over-paying a courier is the same structural impossibility as
    over-refunding an order: the payable account may not go negative."""
    chart = open_chart(ledger)
    payable = _fund_courier(ledger, chart, uuid4())
    payout_id = ledger.payout_begin(
        f"r:{uuid4()}", payable, chart.clearing, FUNDING + 1, CURRENCY)
    ledger.payout_mark_submitted(payout_id, "ref")

    with pytest.raises(LedgerError) as exc:
        ledger.payout_post(payout_id)

    assert exc.value.reason == "NEGATIVE_BALANCE_NOT_ALLOWED"
    assert ledger.natural_balance(payable) == FUNDING
    assert ledger.payout_state(payout_id) == "submitted", "still resumable once funded"
