"""A provider reply that is lost after the money may have moved.

The dangerous case is not a crash but a timeout: the provider may have paid, may
be holding the payout pending, or may never have seen it, and "retry" and "give
up" can each be wrong. These tests pin the pieces that make the status-first
saga safe, and two negative controls that show the checks can fail:

  * schema: a payout cannot be failed without the provider's verdict, and resume
    refuses to guess
  * provider: every fault mode leaves the state it claims to, and status()
    reports it
  * resolver: an unknown payout ends where the provider says, exactly once
  * negative controls: a fresh request id per attempt pays twice, and a
    per-attempt ledger key posts twice

The design and the matrix built on these pieces are in
PREREGISTRATION-ambiguity.md and ambiguity_matrix.py. Everything is simulated.
"""

from __future__ import annotations

import asyncio
from uuid import UUID, uuid4

import psycopg
import pytest

import ambiguity_matrix
import provider
import resolver
from chart import CURRENCY, open_chart
from ledger_api import Ledger, LedgerError
from shared import PayoutRequest
from test_payout_saga import (AMOUNT, FUNDING, _assert_settled_exactly_once, _fund_courier,
                              _payout_transactions)
from test_temporal_payout_saga import _start

TTL = 10


def _pending_payout(ledger: Ledger) -> tuple[UUID, UUID, str]:
    chart = open_chart(ledger)
    payable = _fund_courier(ledger, chart, uuid4())
    request_id = f"amb:{uuid4()}"
    return ledger.payout_begin(request_id, payable, chart.clearing, AMOUNT, CURRENCY), payable, request_id


def _objects(provider_dsn: str, payout_key: str) -> list[tuple]:
    with psycopg.connect(provider_dsn) as c:
        return c.execute("SELECT request_id, status FROM provider_objects WHERE payout_key = %s",
                         (payout_key,)).fetchall()


# ---------------------------------------------------------------------------
# Schema: no failing on a guess
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("state", ["pending", "unknown", "submitted"])
def test_failing_a_payout_without_a_verdict_is_refused(ledger: Ledger, state: str):
    payout_id, payable, _ = _pending_payout(ledger)
    if state == "unknown":
        ledger.payout_mark_unknown(payout_id)
    if state == "submitted":
        ledger.payout_mark_submitted(payout_id, "ref")

    with pytest.raises(LedgerError) as exc:
        ledger.payout_fail(payout_id, None, "timed out")
    assert exc.value.reason == "PAYOUT_VERDICT_REQUIRED"
    assert ledger.payout_state(payout_id) == state


@pytest.mark.parametrize("state", ["pending", "unknown"])
def test_resume_will_not_fail_a_pending_or_unknown_payout_on_a_guess(ledger: Ledger, state: str):
    payout_id, payable, _ = _pending_payout(ledger)
    if state == "unknown":
        assert ledger.payout_mark_unknown(payout_id) == "unknown"

    with pytest.raises(LedgerError) as exc:
        ledger.payout_resume(payout_id, None)
    assert exc.value.reason == "PAYOUT_VERDICT_REQUIRED"
    assert ledger.payout_state(payout_id) == state
    assert ledger.natural_balance(payable) == FUNDING

    # With the provider's answer it goes where the answer says.
    assert ledger.payout_resume(payout_id, None, "not_found") == "failed"


def test_an_unknown_payout_cannot_be_posted_until_the_provider_gives_a_ref(ledger: Ledger):
    payout_id, payable, _ = _pending_payout(ledger)
    ledger.payout_mark_unknown(payout_id)
    with pytest.raises(LedgerError) as exc:
        ledger.payout_post(payout_id)
    assert exc.value.reason == "PAYOUT_NOT_SUBMITTED"

    assert ledger.payout_resume(payout_id, "prv_ref") == "posted"
    _assert_settled_exactly_once(ledger, payout_id, payable)


def test_mark_unknown_never_moves_a_payout_backwards(ledger: Ledger):
    payout_id, _, _ = _pending_payout(ledger)
    ledger.payout_mark_submitted(payout_id, "ref")
    assert ledger.payout_mark_unknown(payout_id) == "submitted"
    ledger.payout_post(payout_id)
    assert ledger.payout_mark_unknown(payout_id) == "posted"


@pytest.mark.parametrize("verdict", ["declined", "not_found"])
def test_a_posted_payout_can_only_fail_as_returned(ledger: Ledger, verdict: str):
    payout_id, payable, _ = _pending_payout(ledger)
    ledger.payout_mark_submitted(payout_id, "ref")
    ledger.payout_post(payout_id)

    with pytest.raises(LedgerError) as exc:
        ledger.payout_fail(payout_id, verdict)
    assert exc.value.reason == "PAYOUT_VERDICT_CONFLICT"
    assert ledger.payout_state(payout_id) == "posted"

    assert ledger.payout_fail(payout_id, "returned") == "failed"
    assert ledger.natural_balance(payable) == FUNDING, "the reversal made the courier whole"


def test_not_found_contradicts_a_payout_the_provider_gave_a_ref_for(ledger: Ledger):
    payout_id, _, _ = _pending_payout(ledger)
    ledger.payout_mark_submitted(payout_id, "ref")
    with pytest.raises(LedgerError) as exc:
        ledger.payout_fail(payout_id, "not_found")
    assert exc.value.reason == "PAYOUT_VERDICT_CONFLICT"


def test_a_failed_row_without_a_verdict_cannot_exist(ledger: Ledger, admin_conn):
    # Structural, not a convention in ledger_payout_fail: even a superuser
    # writing the table directly is stopped by the CHECK.
    payout_id, _, _ = _pending_payout(ledger)
    with pytest.raises(psycopg.errors.CheckViolation):
        admin_conn.execute("UPDATE ledger_payouts SET state = 'failed' WHERE id = %s", (payout_id,))


# ---------------------------------------------------------------------------
# Provider: each fault mode does what it says
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("mode,right_after,eventually", [
    ("commit_then_timeout",       "paid",      "paid"),
    ("key_expiry",                "paid",      "paid"),
    ("timeout_before_commit",     "not_found", "not_found"),
    ("async_pending_then_paid",   "pending",   "paid"),
    ("async_pending_then_failed", "pending",   "failed"),
    ("returned_after_delay",      "paid",      "failed"),
])
def test_each_fault_mode_times_out_and_leaves_what_it_claims(provider_dsn, mode, right_after,
                                                             eventually):
    key = f"fault:{uuid4()}"
    provider.arm(provider_dsn, key, mode, resolve_after=5, return_after=5)
    with pytest.raises(provider.ProviderTimeout):
        provider.pay(provider_dsn, key, AMOUNT, CURRENCY, now=0, ttl=TTL)

    assert provider.status(provider_dsn, key, now=1).state == right_after
    later = provider.status(provider_dsn, key, now=100)
    assert later.state == eventually
    if mode == "returned_after_delay":
        assert later.failure_code == "returned"
    if mode == "async_pending_then_failed":
        assert later.failure_code == "declined"

    # The fault fires once: the next call behaves.
    reply = provider.pay(provider_dsn, key, AMOUNT, CURRENCY, now=2, ttl=TTL)
    assert reply.provider_ref


def test_a_same_key_retry_is_safe_only_while_the_provider_holds_the_key(provider_dsn):
    key = f"ttl:{uuid4()}"
    first = provider.pay(provider_dsn, key, AMOUNT, CURRENCY, now=0, ttl=TTL)
    inside = provider.pay(provider_dsn, key, AMOUNT, CURRENCY, now=TTL - 1, ttl=TTL)
    assert inside.provider_ref == first.provider_ref, "inside the TTL: a replay"
    assert provider.eventual_paid(provider_dsn, key) == (1, 0)

    outside = provider.pay(provider_dsn, key, AMOUNT, CURRENCY, now=TTL + 1, ttl=TTL)
    assert outside.provider_ref != first.provider_ref, "after the TTL: a new payout"
    assert provider.eventual_paid(provider_dsn, key) == (2, 0), "paid twice"
    # status() still answers after the key is gone, because it reads the payouts,
    # not the key cache. The status-first saga depends on that.
    assert provider.status(provider_dsn, key, now=TTL + 2).state == "paid"


# ---------------------------------------------------------------------------
# Resolver
# ---------------------------------------------------------------------------

def test_an_unknown_payout_whose_provider_paid_is_posted_exactly_once(ledger, provider_dsn):
    payout_id, payable, request_id = _pending_payout(ledger)
    provider.arm(provider_dsn, request_id, "commit_then_timeout")
    with pytest.raises(provider.ProviderTimeout):
        provider.pay(provider_dsn, request_id, AMOUNT, CURRENCY)
    ledger.payout_mark_unknown(payout_id)

    for _ in range(3):
        assert resolver.resolve(ledger, provider_dsn, payout_id) == "posted"
    _assert_settled_exactly_once(ledger, payout_id, payable)
    assert len(_objects(provider_dsn, request_id)) == 1


def test_a_payout_the_provider_never_saw_is_resubmitted_not_failed(ledger, provider_dsn):
    # The hand-built suite's after_begin row: the driver died before calling
    # the provider. The old resume(NULL) failed this payout. The resolver asks,
    # hears not_found, and resubmits under the same request id.
    payout_id, payable, request_id = _pending_payout(ledger)
    assert resolver.resolve(ledger, provider_dsn, payout_id) == "posted"
    _assert_settled_exactly_once(ledger, payout_id, payable)
    assert len(_objects(provider_dsn, request_id)) == 1


def test_a_pending_payout_is_held_until_the_provider_decides(ledger, provider_dsn):
    payout_id, payable, request_id = _pending_payout(ledger)
    provider.arm(provider_dsn, request_id, "async_pending_then_failed", resolve_after=10)
    with pytest.raises(provider.ProviderTimeout):
        provider.pay(provider_dsn, request_id, AMOUNT, CURRENCY, now=0)
    ledger.payout_mark_unknown(payout_id)

    assert resolver.resolve(ledger, provider_dsn, payout_id, now=1) == "submitted"
    assert _payout_transactions(ledger, payout_id) == [], "pending is not paid"
    assert resolver.resolve(ledger, provider_dsn, payout_id, now=11) == "failed"
    assert ledger.scalar("SELECT failure_verdict::text FROM ledger_payouts WHERE id = %s",
                         (payout_id,)) == "declined"
    assert ledger.natural_balance(payable) == FUNDING


def test_a_status_timeout_changes_nothing(ledger, provider_dsn):
    payout_id, _, _ = _pending_payout(ledger)
    ledger.payout_mark_unknown(payout_id)

    def silent(*_):
        raise provider.ProviderTimeout("status")
    assert resolver.resolve(ledger, provider_dsn, payout_id, status_fn=silent) == "unknown"


# ---------------------------------------------------------------------------
# Negative controls: the checks above can fail
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def matrix(admin_dsn):
    h = ambiguity_matrix.Harness(admin_dsn)
    yield h
    h.close()


def test_negative_control_a_fresh_request_id_per_attempt_pays_twice(matrix):
    # The per-attempt-key experiment, on the provider side. Same seed, same
    # fault, same detector: a fresh id per retry must come out double, or the
    # zero for status-first below would mean nothing.
    fresh = ambiguity_matrix.run_one(matrix, "fresh_key", "commit_then_timeout", 0)
    assert fresh.provider_paid == 2 and fresh.double and fresh.wrong_money

    status_first = ambiguity_matrix.run_one(matrix, "status_first", "commit_then_timeout", 0)
    assert status_first.provider_paid == 1 and status_first.ledger_state == "posted"
    assert not status_first.wrong_money


def test_negative_control_fail_on_timeout_orphans_a_paid_payout(matrix):
    o = ambiguity_matrix.run_one(matrix, "fail_on_timeout", "commit_then_timeout", 0)
    assert o.ledger_state == "failed" and o.provider_paid == 1 and o.orphaned


def test_negative_control_a_per_attempt_ledger_key_posts_twice(ledger: Ledger):
    # The ledger-side ablation db/temporal_payout/README.md describes: key the
    # post on the attempt instead of the payout, and a retried post is a second
    # transaction. The real key, 'payout:<id>', replays instead.
    chart = open_chart(ledger)
    payable = _fund_courier(ledger, chart, uuid4())
    from ledger_api import credit, debit, fingerprint_of
    entries = [debit(payable, AMOUNT, CURRENCY), credit(chart.clearing, AMOUNT, CURRENCY)]
    payout = uuid4()
    for attempt in (1, 2):
        ledger.post(f"payout:{payout}:attempt:{attempt}", fingerprint_of(entries), "payout",
                    payout, entries)
    assert len(_payout_transactions(ledger, payout)) == 2, "per-attempt key: paid twice"

    payout_id, payable2, _ = _pending_payout(ledger)
    ledger.payout_mark_submitted(payout_id, "ref")
    first, second = ledger.payout_post(payout_id), ledger.payout_post(payout_id)
    assert second.replayed and second.transaction_id == first.transaction_id
    assert len(_payout_transactions(ledger, payout_id)) == 1


# ---------------------------------------------------------------------------
# Temporal: the workflow's submit activity asks before it retries
# ---------------------------------------------------------------------------

def test_temporal_asks_the_provider_after_a_timeout_and_pays_once(
        ledger, workers, temporal_address, provider_dsn):
    chart = open_chart(ledger)
    payable = _fund_courier(ledger, chart, uuid4())
    req = PayoutRequest(f"payout-req:{uuid4()}", str(payable), str(chart.clearing), AMOUNT, CURRENCY)
    provider.arm(provider_dsn, req.request_id, "commit_then_timeout")
    workers.start()

    async def go():
        handle = await _start(temporal_address, workers, req)
        return await asyncio.wait_for(handle.result(), 60)
    outcome = asyncio.run(go())

    assert outcome.state == "posted"
    _assert_settled_exactly_once(ledger, UUID(outcome.payout_id), payable)
    assert _objects(provider_dsn, req.request_id) == [(req.request_id, "paid")]
    with psycopg.connect(provider_dsn) as c:
        calls = c.execute("SELECT calls FROM provider_payouts WHERE request_id = %s",
                          (req.request_id,)).fetchone()[0]
    assert calls == 1, "status answered the question; nothing was resubmitted"


def test_temporal_waits_out_a_pending_payout(ledger, workers, temporal_address, provider_dsn):
    chart = open_chart(ledger)
    payable = _fund_courier(ledger, chart, uuid4())
    req = PayoutRequest(f"payout-req:{uuid4()}", str(payable), str(chart.clearing), AMOUNT, CURRENCY)
    provider.arm(provider_dsn, req.request_id, "async_pending_then_paid", resolve_after=2.0)
    workers.start()

    async def go():
        handle = await _start(temporal_address, workers, req)
        return await asyncio.wait_for(handle.result(), 60)
    outcome = asyncio.run(go())

    assert outcome.state == "posted"
    _assert_settled_exactly_once(ledger, UUID(outcome.payout_id), payable)
    assert len(_objects(provider_dsn, req.request_id)) == 1
