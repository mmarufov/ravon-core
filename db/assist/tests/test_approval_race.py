"""50 concurrent approvals of one proposal post exactly one ledger transaction.

assist_approve() has two independent mechanisms (01_assist.sql): a row lock on
the proposal, and an idempotency key derived from the proposal id. The
variants below are built from the real function's own source with one
mechanism, or both, removed, so the test shows which one carries the
guarantee and that the detector fires when neither does.
"""

from __future__ import annotations

import threading
import uuid

import psycopg
import pytest

from conftest import as_merchant, by_cause, reason_of

CLICKS = 50

LOCK = "WHERE id = p_proposal_id FOR UPDATE;"
NO_LOCK = "WHERE id = p_proposal_id;"
KEY = "'assist:' || p.id::text,\n"
FRESH_KEY = "'assist:' || p.id::text || ':' || gen_random_uuid()::text,\n"

VARIANTS = {
    # name: (keep the lock, keep the derived key, expected transactions or None for "> 1")
    "assist_approve": (True, True, 1),
    "approve_without_lock": (False, True, 1),
    "approve_with_fresh_key": (True, False, 1),
    "approve_without_lock_or_key": (False, False, None),
}


def make_variant(admin: psycopg.Connection, name: str, keep_lock: bool, keep_key: bool) -> str:
    if name == "assist_approve":
        return "public.assist_approve"
    src = admin.execute("SELECT pg_get_functiondef('public.assist_approve(uuid, text)'::regprocedure)").fetchone()[0]
    assert LOCK in src and KEY in src, "assist_approve changed shape; update the variant patterns"
    if not keep_lock:
        src = src.replace(LOCK, NO_LOCK, 1)
    if not keep_key:
        src = src.replace(KEY, FRESH_KEY, 1)
    src = src.replace("public.assist_approve(", f"assist_race_variants.{name}(", 1)
    admin.execute("CREATE SCHEMA IF NOT EXISTS assist_race_variants")
    admin.execute(src)
    admin.execute(f"GRANT USAGE ON SCHEMA assist_race_variants TO assist_approver")
    admin.execute(f"GRANT EXECUTE ON FUNCTION assist_race_variants.{name}(uuid, text) TO assist_approver")
    return f"assist_race_variants.{name}"


def fresh_proposal(dsn: str, case: dict) -> str:
    with psycopg.connect(dsn) as conn:
        as_merchant(conn, "assist_proposer", case["merchant_id"])
        pid = conn.execute(
            "SELECT public.assist_propose('commission_correction', %s, %s, 'race test')",
            (case["expected_proposal"]["amount_minor"], case["facts"]["evidence_entry_ids"])).fetchone()[0]
        conn.commit()
    return str(pid)


def click(dsn: str, fn: str, pid: str, barrier: threading.Barrier, out: list, i: int) -> None:
    with psycopg.connect(dsn) as conn:
        conn.execute("SET ROLE assist_approver")
        barrier.wait()
        try:
            out[i] = conn.execute(f"SELECT {fn}(%s, %s)", (pid, f"operator-{i}")).fetchone()[0]
            conn.commit()
        except psycopg.Error as exc:
            conn.rollback()
            out[i] = exc


def race(dsn: str, fn: str, pid: str) -> list:
    barrier = threading.Barrier(CLICKS)
    out: list = [None] * CLICKS
    threads = [threading.Thread(target=click, args=(dsn, fn, pid, barrier, out, i)) for i in range(CLICKS)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return out


def assist_transactions(admin: psycopg.Connection, pid: str) -> list[uuid.UUID]:
    return [r[0] for r in admin.execute(
        "SELECT id FROM public.ledger_transactions WHERE business_event_id = %s AND idempotency_key LIKE 'assist:%%'",
        (pid,))]


def payable_balance(admin: psycopg.Connection, merchant: str) -> int:
    return admin.execute(
        "SELECT natural_minor FROM public.ledger_account_balances "
        "WHERE kind = 'merchant_payable' AND owner_id = %s", (merchant,)).fetchone()[0]


@pytest.mark.parametrize("variant", list(VARIANTS))
def test_fifty_concurrent_approvals(dsn, admin, cases, variant):
    keep_lock, keep_key, expected = VARIANTS[variant]
    case = by_cause(cases, "commission_misapplied")[list(VARIANTS).index(variant)]
    fn = make_variant(admin, variant, keep_lock, keep_key)
    pid = fresh_proposal(dsn, case)
    before = payable_balance(admin, case["merchant_id"])

    results = race(dsn, fn, pid)

    txs = assist_transactions(admin, pid)
    errors = [r for r in results if isinstance(r, Exception)]
    paid = payable_balance(admin, case["merchant_id"]) - before
    amount = case["expected_proposal"]["amount_minor"]
    print(f"{variant}: {len(txs)} ledger transaction(s) from {CLICKS} clicks, "
          f"{len(errors)} errors, merchant credited {paid} (= {paid // amount} x {amount})")
    assert admin.execute("SELECT count(*) FROM public.ledger_verify_balances()").fetchone()[0] == 0

    if expected is None:
        # The negative control: with both mechanisms gone, the detector must see doubles.
        assert len(txs) > 1, "removing both the lock and the key did not double-post; the race never ran"
        assert paid == len(txs) * amount
    else:
        assert errors == []
        assert len(txs) == expected
        assert {str(r) for r in results} == {str(txs[0])}   # every click got the same answer
        assert paid == amount


def test_rejected_proposal_cannot_be_approved_and_approved_cannot_be_rejected(dsn, cases):
    a, b = by_cause(cases, "commission_misapplied")[4], by_cause(cases, "refund_duplicated")[0]
    pid_a = fresh_proposal(dsn, a)
    with psycopg.connect(dsn) as conn:
        conn.execute("SET ROLE assist_approver")
        conn.execute("SELECT public.assist_reject(%s, 'operator')", (pid_a,))
        conn.commit()
        with pytest.raises(psycopg.Error) as exc:
            conn.execute("SELECT public.assist_approve(%s, 'operator')", (pid_a,))
        assert reason_of(exc.value) == "ASSIST_PROPOSAL_REJECTED"
        conn.rollback()

    with psycopg.connect(dsn) as conn:
        as_merchant(conn, "assist_proposer", b["merchant_id"])
        pid_b = conn.execute("SELECT public.assist_propose('refund_reversal', %s, %s, 'x')",
                             (b["expected_proposal"]["amount_minor"], b["facts"]["evidence_entry_ids"])).fetchone()[0]
        conn.commit()
    with psycopg.connect(dsn) as conn:
        conn.execute("SET ROLE assist_approver")
        conn.execute("SELECT public.assist_approve(%s, 'operator')", (pid_b,))
        conn.commit()
        with pytest.raises(psycopg.Error) as exc:
            conn.execute("SELECT public.assist_reject(%s, 'operator')", (pid_b,))
        assert reason_of(exc.value) == "ASSIST_PROPOSAL_ALREADY_APPROVED"


def test_approval_rechecks_evidence_against_the_proposals_merchant(dsn, admin, cases):
    """A proposal row forged around assist_propose (here, by the table owner)
    citing another merchant's entry is refused at approval."""
    mine, other = by_cause(cases, "chargeback")[:2]
    pid = admin.execute(
        "INSERT INTO public.assist_proposals (merchant_id, kind, amount_minor, entry_ids, reason) "
        "VALUES (%s, 'refund_reversal', 100, %s, 'forged') RETURNING id",
        (mine["merchant_id"], other["facts"]["evidence_entry_ids"])).fetchone()[0]
    with psycopg.connect(dsn) as conn:
        conn.execute("SET ROLE assist_approver")
        with pytest.raises(psycopg.Error) as exc:
            conn.execute("SELECT public.assist_approve(%s, 'operator')", (pid,))
    assert reason_of(exc.value) == "ASSIST_EVIDENCE_NOT_VISIBLE"
    assert assist_transactions(admin, str(pid)) == []


def test_every_assist_transaction_has_an_approved_proposal(admin):
    """Run last in this file: whatever the tests above posted, each assist:
    transaction is named by exactly one approved proposal, except those the
    negative-control variants posted, which are exactly the extra ones."""
    orphans = admin.execute("""
        SELECT t.idempotency_key FROM public.ledger_transactions t
        WHERE t.idempotency_key LIKE 'assist:%'
          AND NOT EXISTS (SELECT 1 FROM public.assist_proposals p
                          WHERE p.status = 'approved' AND p.ledger_tx_id = t.id)""").fetchall()
    # Only the no-lock-no-key variant may leave orphans: its extra postings
    # are the double payments the control exists to produce.
    with_fresh_suffix = [k for (k,) in orphans if k.count(":") == 2]
    assert len(orphans) == len(with_fresh_suffix)
