"""INVARIANT 6 — idempotency, including the concurrent race.

The contract is DoorDash's published one:
  same key + same fingerprint      -> the original transaction, nothing written
  same key + different fingerprint -> HTTP 409
  concurrent callers, same key     -> exactly one writes; the rest serialise
                                      behind it and replay its result
"""

from __future__ import annotations

import json
import threading
from uuid import uuid4

import psycopg
import pytest

from chart import CURRENCY, escrow_for, open_chart
from ledger_api import Ledger, LedgerError, authorize_entries, fingerprint_of


def test_replay_with_same_fingerprint_returns_the_original(ledger: Ledger):
    chart = open_chart(ledger)
    escrow = escrow_for(ledger, uuid4())
    entries = authorize_entries(chart.receivable, escrow, 5000, CURRENCY)
    key, fp, event = f"k:{uuid4()}", fingerprint_of(entries), uuid4()

    first = ledger.post(key, fp, "authorize", event, entries)
    second = ledger.post(key, fp, "authorize", event, entries)

    assert first.replayed is False
    assert second.replayed is True
    assert second.transaction_id == first.transaction_id


def test_replay_is_a_no_op_not_a_second_posting(ledger: Ledger):
    """The property that matters: a retried request must not move money twice."""
    chart = open_chart(ledger)
    escrow = escrow_for(ledger, uuid4())
    entries = authorize_entries(chart.receivable, escrow, 5000, CURRENCY)
    key, fp, event = f"k:{uuid4()}", fingerprint_of(entries), uuid4()

    ledger.post(key, fp, "authorize", event, entries)
    before = (ledger.scalar("SELECT count(*) FROM ledger_entries"),
              ledger.natural_balance(escrow))

    for _ in range(5):
        ledger.post(key, fp, "authorize", event, entries)

    after = (ledger.scalar("SELECT count(*) FROM ledger_entries"),
             ledger.natural_balance(escrow))
    assert after == before == (2, 5000)


def test_same_key_different_fingerprint_is_a_409(ledger: Ledger):
    chart = open_chart(ledger)
    escrow = escrow_for(ledger, uuid4())
    entries = authorize_entries(chart.receivable, escrow, 5000, CURRENCY)
    key = f"k:{uuid4()}"

    original = ledger.post(key, fingerprint_of(entries), "authorize", uuid4(), entries)

    bigger = authorize_entries(chart.receivable, escrow, 9999, CURRENCY)
    with pytest.raises(LedgerError) as exc:
        ledger.post(key, fingerprint_of(bigger), "authorize", uuid4(), bigger)

    assert exc.value.reason == "IDEMPOTENCY_KEY_CONFLICT"
    assert exc.value.http_status == 409
    assert exc.value.detail["transaction_id"] == str(original.transaction_id)
    assert ledger.natural_balance(escrow) == 5000, "the conflicting attempt moved nothing"


def test_a_replay_does_not_fire_the_deferred_check(ledger: Ledger):
    """A replay writes no entries, so there is nothing to validate. Cheap, and
    it confirms the replay really short-circuits rather than re-inserting and
    relying on a constraint to deduplicate."""
    chart = open_chart(ledger)
    escrow = escrow_for(ledger, uuid4())
    entries = authorize_entries(chart.receivable, escrow, 5000, CURRENCY)
    key, fp = f"k:{uuid4()}", fingerprint_of(entries)

    ledger.post(key, fp, "authorize", uuid4(), entries)
    fires_after_first = ledger.deferred_check_count()

    ledger.post(key, fp, "authorize", uuid4(), entries)

    assert ledger.deferred_check_count() == fires_after_first


# ===========================================================================
# The concurrent race
# ===========================================================================

def _race(dsn: str, key: str, fingerprints: list[str], entries, event_id):
    """Fire N callers at ledger_post simultaneously and collect what each got."""
    results: list[object] = [None] * len(fingerprints)
    barrier = threading.Barrier(len(fingerprints))

    def worker(i: int, fp: str) -> None:
        with psycopg.connect(dsn) as conn:
            ledger = Ledger(conn)
            barrier.wait(timeout=10)
            try:
                results[i] = ledger.post(key, fp, "authorize", event_id, entries)
            except LedgerError as exc:
                results[i] = exc

    threads = [threading.Thread(target=worker, args=(i, fp))
               for i, fp in enumerate(fingerprints)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=30)
        assert not t.is_alive(), "a racing caller deadlocked"
    return results


def test_concurrent_identical_posts_write_exactly_once(ledger: Ledger, ledger_db: str):
    chart = open_chart(ledger)
    escrow = escrow_for(ledger, uuid4())
    entries = authorize_entries(chart.receivable, escrow, 5000, CURRENCY)
    key, fp, event = f"k:{uuid4()}", fingerprint_of(entries), uuid4()

    results = _race(ledger_db, key, [fp] * 8, entries, event)

    assert all(not isinstance(r, LedgerError) for r in results), \
        [r for r in results if isinstance(r, LedgerError)]
    winners = [r for r in results if r.replayed is False]
    assert len(winners) == 1, "exactly one caller may write"
    assert len({r.transaction_id for r in results}) == 1, "everyone got the same transaction"
    assert ledger.scalar("SELECT count(*) FROM ledger_entries") == 2
    assert ledger.natural_balance(escrow) == 5000


def test_concurrent_posts_with_conflicting_fingerprints(ledger: Ledger, ledger_db: str):
    """One caller wins; every other caller is told 409 rather than being allowed
    to post different money under a key that is already spoken for."""
    chart = open_chart(ledger)
    escrow = escrow_for(ledger, uuid4())
    entries = authorize_entries(chart.receivable, escrow, 5000, CURRENCY)
    key, event = f"k:{uuid4()}", uuid4()

    results = _race(ledger_db, key, [f"fp-{i}" for i in range(8)], entries, event)

    winners = [r for r in results if not isinstance(r, LedgerError)]
    losers = [r for r in results if isinstance(r, LedgerError)]
    assert len(winners) == 1
    assert winners[0].replayed is False
    assert all(e.reason == "IDEMPOTENCY_KEY_CONFLICT" for e in losers)
    assert ledger.scalar("SELECT count(*) FROM ledger_entries") == 2


def test_the_loser_blocks_until_the_winner_commits(ledger: Ledger, ledger_db: str):
    """The serialisation requirement, made observable.

    The winner holds its transaction open. A second caller with the same key
    must not return "no such key, I'll write it" and must not error — it must
    block, and then replay the winner's transaction once the winner commits.
    """
    chart = open_chart(ledger)
    escrow = escrow_for(ledger, uuid4())
    entries = authorize_entries(chart.receivable, escrow, 5000, CURRENCY)
    key, fp, event = f"k:{uuid4()}", fingerprint_of(entries), uuid4()

    winner_conn = psycopg.connect(ledger_db)
    loser_result: list[object] = []
    started = threading.Event()

    # Winner posts but does NOT commit.
    with winner_conn.cursor() as cur:
        cur.execute(
            "SELECT transaction_id FROM ledger_post(%s, %s, 'authorize', %s::uuid, %s::jsonb)",
            (key, fp, event, json.dumps([e.as_json() for e in entries])))
        winner_tx = cur.fetchone()[0]

    def loser() -> None:
        with psycopg.connect(ledger_db) as conn:
            started.set()
            try:
                loser_result.append(Ledger(conn).post(key, fp, "authorize", event, entries))
            except LedgerError as exc:
                loser_result.append(exc)

    thread = threading.Thread(target=loser)
    thread.start()
    started.wait(timeout=5)

    thread.join(timeout=1.5)
    assert thread.is_alive(), "the loser should be blocked on the winner's uncommitted row"
    assert loser_result == []

    winner_conn.commit()
    thread.join(timeout=10)
    winner_conn.close()

    assert not thread.is_alive()
    assert len(loser_result) == 1
    assert not isinstance(loser_result[0], LedgerError), loser_result[0]
    assert loser_result[0].replayed is True
    assert loser_result[0].transaction_id == winner_tx
    assert ledger.scalar("SELECT count(*) FROM ledger_entries") == 2


def test_a_losers_replay_survives_the_winner_rolling_back(ledger: Ledger, ledger_db: str):
    """If the winner aborts, its key was never taken. The blocked caller must go
    on to write the posting itself rather than replaying a transaction that
    does not exist."""
    chart = open_chart(ledger)
    escrow = escrow_for(ledger, uuid4())
    entries = authorize_entries(chart.receivable, escrow, 5000, CURRENCY)
    key, fp, event = f"k:{uuid4()}", fingerprint_of(entries), uuid4()

    winner_conn = psycopg.connect(ledger_db)
    with winner_conn.cursor() as cur:
        cur.execute(
            "SELECT transaction_id FROM ledger_post(%s, %s, 'authorize', %s::uuid, %s::jsonb)",
            (key, fp, event, json.dumps([e.as_json() for e in entries])))

    result: list[object] = []
    started = threading.Event()

    def contender() -> None:
        with psycopg.connect(ledger_db) as conn:
            started.set()
            try:
                result.append(Ledger(conn).post(key, fp, "authorize", event, entries))
            except LedgerError as exc:
                result.append(exc)

    thread = threading.Thread(target=contender)
    thread.start()
    started.wait(timeout=5)
    thread.join(timeout=1.5)
    assert thread.is_alive()

    winner_conn.rollback()
    winner_conn.close()
    thread.join(timeout=10)

    assert len(result) == 1 and not isinstance(result[0], LedgerError), result
    assert result[0].replayed is False, "the aborted winner freed the key"
    assert ledger.scalar("SELECT count(*) FROM ledger_entries") == 2
    assert ledger.natural_balance(escrow) == 5000
