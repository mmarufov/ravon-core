"""The hand-built saga's crash matrix, run against the Temporal workflow.

Same ledger, same schema, same idempotency key, and the same final assertion:
`_assert_settled_exactly_once` is imported from db/ledger/tests/
test_payout_saga.py, not rewritten.

What "crash" means has to change, and the mapping is the interesting part:

  * The two `during_*` points kill the PostgreSQL backend mid-transaction, the
    same way the hand-built suite does. Temporal sees a failed activity attempt.
  * The three `after_*` points in the hand-built suite are the driver dying
    between steps. In Temporal the driver is the worker, so they become a
    SIGKILL of the worker after the previous activity's completion is in
    history, at the entry of the next activity, before any side effect.
  * `after_post` is "fully done, resume must be a no-op". The Temporal version
    is the same payout submitted again, three times, after it completed.

Then the points that only exist once there is a worker: SIGKILL after a step's
COMMIT but before Temporal hears about it, one per step, and a frozen worker
that wakes up after someone else has finished its job.
"""

from __future__ import annotations

import asyncio
import os
import signal
import time
from uuid import UUID, uuid4

import psycopg
import pytest
from temporalio.api.enums.v1 import EventType
from temporalio.client import Client, WorkflowFailureError
from temporalio.exceptions import WorkflowAlreadyStartedError

from chart import CURRENCY, open_chart
from ledger_api import Ledger
from provider import DECLINE_ABOVE
from shared import WORKFLOW_TASK_TIMEOUT, PayoutRequest
from test_payout_saga import (AMOUNT, CRASH_POINTS, FUNDING, _assert_settled_exactly_once,
                              _fund_courier, _payout_transactions)
from workflow import PayoutWorkflow

# crash point -> (where the fault fires, what it does). None: no fault.
SEVEN = {
    "during_begin":         ("begin:before_commit", "pg_kill"),
    "after_begin":          ("provider:enter", "sigkill"),
    "after_provider_call":  ("mark:enter", "sigkill"),
    "after_mark_submitted": ("post:enter", "sigkill"),
    "during_post":          ("post:before_commit", "pg_kill"),
    "after_post":           None,
    "never":                None,
}
assert list(SEVEN) == CRASH_POINTS, "the matrix must track the hand-built suite exactly"

MID_ACTIVITY = {
    "worker_kill_mid_begin":    "begin:committed",
    "worker_kill_mid_provider": "provider:committed",
    "worker_kill_mid_mark":     "mark:committed",
    "worker_kill_mid_post":     "post:committed",
}

STEP_OF = {"begin_payout": "begin", "submit_to_provider": "provider",
           "provider_status": "status", "mark_submitted": "mark", "post_payout": "post",
           "fail_payout": "fail"}


def _payout(ledger: Ledger, amount: int = AMOUNT) -> tuple[PayoutRequest, UUID]:
    chart = open_chart(ledger)
    payable = _fund_courier(ledger, chart, uuid4())
    return PayoutRequest(f"payout-req:{uuid4()}", str(payable), str(chart.clearing),
                         amount, CURRENCY), payable


async def _start(address: str, workers, req: PayoutRequest):
    client = await Client.connect(address)
    return await client.start_workflow(
        PayoutWorkflow.run, req, id=req.request_id,
        task_queue=workers.env["PAYOUT_TASK_QUEUE"], task_timeout=WORKFLOW_TASK_TIMEOUT)


async def _attempts(handle) -> dict[str, int]:
    """Final attempt number per step, read from Temporal's own event history."""
    names, attempts = {}, {}
    async for e in handle.fetch_history_events():
        if e.event_type == EventType.EVENT_TYPE_ACTIVITY_TASK_SCHEDULED:
            names[e.event_id] = STEP_OF[e.activity_task_scheduled_event_attributes.activity_type.name]
        elif e.event_type == EventType.EVENT_TYPE_ACTIVITY_TASK_STARTED:
            a = e.activity_task_started_event_attributes
            attempts[names[a.scheduled_event_id]] = a.attempt
    return attempts


def _provider_rows(provider_dsn: str, request_id: str) -> list[tuple]:
    with psycopg.connect(provider_dsn) as c:
        return c.execute("SELECT provider_ref, calls FROM provider_payouts WHERE request_id = %s",
                         (request_id,)).fetchall()


def _executions(workers, request_id: str) -> dict[str, int]:
    """How many times each step's code actually started, from the workers' own log."""
    counts: dict[str, int] = {}
    for e in workers.evidence(request_id):
        if e["event"] == "enter":
            counts[e["step"]] = counts.get(e["step"], 0) + 1
    return counts


def _check_one_effect(ledger, provider_dsn, outcome, req, payable) -> int:
    assert outcome.state == "posted"
    _assert_settled_exactly_once(ledger, UUID(outcome.payout_id), payable)
    rows = _provider_rows(provider_dsn, req.request_id)
    assert len(rows) == 1, "the provider paid out more than once"
    return rows[0][1]


def _run(temporal_address, workers, req, fault):
    async def go():
        handle = await _start(temporal_address, workers, req)
        if fault and fault[1] == "sigkill":
            await asyncio.to_thread(workers.wait_for_death)
            workers.restart_dead()                          # the supervisor's job
        outcome = await asyncio.wait_for(handle.result(), 60)
        return outcome, await _attempts(handle)
    return asyncio.run(go())


@pytest.mark.parametrize("crash_point", CRASH_POINTS)
def test_temporal_payout_survives_the_seven_hand_built_crash_points(
        ledger, workers, temporal_address, provider_dsn, record, crash_point):
    req, payable = _payout(ledger)
    fault = SEVEN[crash_point]
    if fault:
        workers.arm(req.request_id, *fault)
    workers.start()
    started = time.monotonic()

    outcome, attempts = _run(temporal_address, workers, req, fault)

    evidence = workers.evidence(req.request_id)
    if fault:
        assert workers.fired_pid(req.request_id), "the fault never fired"
        step = fault[0].split(":")[0]
        assert attempts[step] == 2, f"{step} should have needed exactly one retry: {attempts}"
        runs = _executions(workers, req.request_id)
        assert runs[step] == 2 and all(n == 1 for k, n in runs.items() if k != step), \
            f"only the interrupted step may run twice; history replay covers the rest: {runs}"

    rerun_replays = []
    if crash_point == "after_post":
        # Hand-built: resume three times. Here: submit the same payout three
        # more times. The workflow id is free again once the first run closed,
        # so every rerun really executes all four activities.
        async def resubmit():
            client = await Client.connect(temporal_address)
            for _ in range(3):
                again = await client.execute_workflow(
                    PayoutWorkflow.run, req, id=req.request_id,
                    task_queue=workers.env["PAYOUT_TASK_QUEUE"])
                assert again.transaction_id == outcome.transaction_id
        asyncio.run(resubmit())
        evidence = workers.evidence(req.request_id)
        rerun_replays = [e["result"]["replayed"] for e in evidence
                         if e["step"] == "post" and e["event"] == "returned"]
        assert rerun_replays == [False, True, True, True]

    calls = _check_one_effect(ledger, provider_dsn, outcome, req, payable)
    record(impl="temporal", point=crash_point, passed=True, attempts=attempts,
           executions=_executions(workers, req.request_id),
           provider_calls=calls, worker_restarts=workers.restarts,
           post_replayed=rerun_replays or [e["result"]["replayed"] for e in evidence
                                           if e["step"] == "post" and e["event"] == "returned"],
           seconds=round(time.monotonic() - started, 2))


@pytest.mark.parametrize("crash_point", list(MID_ACTIVITY))
def test_worker_killed_after_commit_before_temporal_is_told(
        ledger, workers, temporal_address, provider_dsn, record, crash_point):
    """The effect is durable, Temporal's history says the attempt is still
    running, and the process that knew the truth is gone. Temporal can only
    wait out the timeout and run the step again."""
    req, payable = _payout(ledger)
    fault = (MID_ACTIVITY[crash_point], "sigkill")
    workers.arm(req.request_id, *fault)
    workers.start()
    started = time.monotonic()

    outcome, attempts = _run(temporal_address, workers, req, fault)

    step = fault[0].split(":")[0]
    runs = [e for e in workers.evidence(req.request_id)
            if e["step"] == step and e["event"] == "returned"]
    assert len(runs) == 2, "the step committed twice, once per attempt"
    assert attempts[step] == 2
    if step == "post":
        assert [r["result"]["replayed"] for r in runs] == [False, True]
    calls = _check_one_effect(ledger, provider_dsn, outcome, req, payable)
    if step == "provider":
        assert calls == 2, "Temporal really did call the provider twice"
    record(impl="temporal", point=crash_point, passed=True, attempts=attempts,
           executions=_executions(workers, req.request_id),
           provider_calls=calls, worker_restarts=workers.restarts,
           step_results=[r["result"] for r in runs],
           seconds=round(time.monotonic() - started, 2))


def test_frozen_worker_wakes_after_another_worker_finished_its_job(
        ledger, workers, temporal_address, provider_dsn, record):
    """The zombie. Worker A is handed `post`, freezes before touching the
    ledger, and Temporal gives the step to worker B once A's attempt times out.
    B finishes the payout. Then A thaws and does exactly what it was told to.

    Temporal rejects A's *report*, but nothing stops A's *write*: the only
    thing between A and a second payout is the ledger's idempotency key."""
    req, payable = _payout(ledger)
    workers.arm(req.request_id, "post:enter", "sigstop")
    workers.start(2)
    started = time.monotonic()

    async def go():
        handle = await _start(temporal_address, workers, req)
        outcome = await asyncio.wait_for(handle.result(), 60)
        return outcome, await _attempts(handle)
    outcome, attempts = asyncio.run(go())
    finished = time.monotonic() - started

    zombie = workers.fired_pid(req.request_id)
    assert zombie, "no worker froze"
    before = [e for e in workers.evidence(req.request_id)
              if e["pid"] == zombie and e["step"] == "post" and e["event"] == "returned"]
    assert before == [], "the zombie was frozen; it cannot have written anything yet"
    _check_one_effect(ledger, provider_dsn, outcome, req, payable)

    os.kill(zombie, signal.SIGCONT)
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        late = [e for e in workers.evidence(req.request_id)
                if e["pid"] == zombie and e["step"] == "post" and e["event"] == "returned"]
        if late:
            break
        time.sleep(0.05)
    assert late, "the zombie never ran its write"
    assert late[0]["attempt"] == 1, "the write came from the attempt Temporal had given up on"
    assert late[0]["result"]["replayed"] is True, "the key turned the zombie's write into a replay"

    _check_one_effect(ledger, provider_dsn, outcome, req, payable)
    time.sleep(1)       # let the zombie try to report, so its log shows the rejection
    zombie_log = workers.logs[zombie].read_text()
    record(impl="temporal", point="worker_zombie_post", passed=True, attempts=attempts,
           executions=_executions(workers, req.request_id),
           zombie_attempt=late[0]["attempt"], zombie_replayed=late[0]["result"]["replayed"],
           workflow_done_s=round(finished, 2),
           zombie_report_rejected="not found" in zombie_log.lower(),
           seconds=round(time.monotonic() - started, 2))


# ---------------------------------------------------------------------------
# The rest of the hand-built saga's tests, where they translate.
# ---------------------------------------------------------------------------

def test_starting_the_same_payout_twice_runs_it_once(ledger, workers, temporal_address,
                                                      provider_dsn):
    """Temporal's own dedupe: a workflow id cannot be started twice while open."""
    req, payable = _payout(ledger)

    async def go():
        handle = await _start(temporal_address, workers, req)   # no worker yet: stays open
        with pytest.raises(WorkflowAlreadyStartedError):
            await _start(temporal_address, workers, req)
        workers.start()
        return await asyncio.wait_for(handle.result(), 60)
    _check_one_effect(ledger, provider_dsn, asyncio.run(go()), req, payable)


def test_provider_decline_fails_the_payout_with_no_ledger_effect(ledger, workers,
                                                                 temporal_address):
    chart = open_chart(ledger)
    payable = ledger.open_account("courier_payable", uuid4(), CURRENCY)
    big = DECLINE_ABOVE + 1
    from ledger_api import credit, debit, fingerprint_of
    entries = [debit(chart.revenue, big, CURRENCY), credit(payable, big, CURRENCY)]
    ledger.post(f"fund:{uuid4()}", fingerprint_of(entries), "settlement", uuid4(), entries)
    req = PayoutRequest(f"payout-req:{uuid4()}", str(payable), str(chart.clearing), big, CURRENCY)
    workers.start()

    outcome, _ = _run(temporal_address, workers, req, None)

    assert outcome.state == "failed"
    assert _payout_transactions(ledger, UUID(outcome.payout_id)) == []
    assert ledger.natural_balance(payable) == big


def test_an_overdraw_is_a_verdict_not_a_retry(ledger, workers, temporal_address):
    """NEGATIVE_BALANCE_NOT_ALLOWED is raised non-retryable. Without that
    classification Temporal would retry it forever."""
    req, payable = _payout(ledger, amount=FUNDING + 1)
    workers.start()

    async def go():
        handle = await _start(temporal_address, workers, req)
        with pytest.raises(WorkflowFailureError) as exc:
            await asyncio.wait_for(handle.result(), 60)
        return exc.value, await _attempts(handle)
    failure, attempts = asyncio.run(go())

    assert "NEGATIVE_BALANCE_NOT_ALLOWED" in str(failure.cause.cause)
    assert attempts["post"] == 1
    payout_id = ledger.scalar("SELECT id FROM ledger_payouts WHERE request_id = %s",
                              (req.request_id,))
    assert ledger.payout_state(payout_id) == "submitted", "still resumable once funded"
    assert _payout_transactions(ledger, payout_id) == []
    assert ledger.natural_balance(payable) == FUNDING
