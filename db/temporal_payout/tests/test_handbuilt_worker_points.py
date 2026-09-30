"""The worker-only crash points, asked of the hand-built saga.

The hand-built saga has no worker, so "SIGKILL the worker mid-activity" has no
literal meaning for it: the durable state such a kill leaves behind is exactly
the state of an `after_*` point in test_payout_saga.py, and compare.py says so
instead of inventing a test.

The zombie does have a meaning. Two resumers can exist at once, because nothing
in the hand-built design stops a second recovery job from starting while the
first is stalled. These tests run that against the unmodified schema and
ledger_api.py.
"""

from __future__ import annotations

import threading
import time
from uuid import uuid4

import psycopg

from chart import open_chart
from ledger_api import Ledger
from test_payout_saga import AMOUNT, _assert_settled_exactly_once, _fund_courier
from chart import CURRENCY


def _submitted_payout(ledger: Ledger):
    chart = open_chart(ledger)
    payable = _fund_courier(ledger, chart, uuid4())
    payout_id = ledger.payout_begin(f"payout-req:{uuid4()}", payable, chart.clearing,
                                    AMOUNT, CURRENCY)
    ledger.payout_mark_submitted(payout_id, "provider-ref")
    return payout_id, payable


def test_stale_resumer_wakes_after_another_finished(ledger: Ledger, ledger_db: str, record):
    """Same shape as the Temporal zombie: A decides to post, stalls, B finishes
    the saga, A wakes and posts anyway."""
    payout_id, payable = _submitted_payout(ledger)
    assert ledger.payout_state(payout_id) == "submitted"      # A reads this, decides, stalls

    with psycopg.connect(ledger_db) as b:
        assert Ledger(b).payout_resume(payout_id, "provider-ref") == "posted"

    late = ledger.payout_post(payout_id)                      # A wakes up
    assert late.replayed is True
    _assert_settled_exactly_once(ledger, payout_id, payable)
    record(impl="handbuilt", point="worker_zombie_post", passed=True,
           zombie_replayed=late.replayed)


def test_concurrent_resumers_serialise_on_the_payout_row(ledger: Ledger, ledger_db: str,
                                                         record):
    """A holds ledger_payout_post open, uncommitted. B's resume must wait for
    A's row lock, then see A's committed posting and replay it."""
    payout_id, payable = _submitted_payout(ledger)
    a = psycopg.connect(ledger_db)
    a.execute("SELECT transaction_id FROM ledger_payout_post(%s::uuid)", (payout_id,))

    result = {}
    def resume_b():
        with psycopg.connect(ledger_db) as b:
            result["state"] = Ledger(b).payout_resume(payout_id, "provider-ref")
    t = threading.Thread(target=resume_b)
    t.start()
    time.sleep(0.5)
    blocked = t.is_alive()
    a.commit()
    a.close()
    t.join(10)

    assert blocked, "B should have been waiting on A's FOR UPDATE"
    assert result["state"] == "posted"
    _assert_settled_exactly_once(ledger, payout_id, payable)
    record(impl="handbuilt", point="concurrent_resumers", passed=True, b_blocked=blocked)
