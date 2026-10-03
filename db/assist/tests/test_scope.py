"""Every read is the asking merchant's, and nothing else.

The oracle is independent of the policies: it recomputes, as the table owner
with plain joins, which entries belong to a merchant, and compares that with
what the views return for every one of the 40 seeded merchants.
"""

from __future__ import annotations

import psycopg
import pytest

from conftest import as_merchant, by_cause, reason_of

ORACLE_SQL = """
WITH mine AS (
  SELECT a.id FROM public.ledger_accounts a
  WHERE (a.kind = 'merchant_payable' AND a.owner_id = %(m)s)
     OR (a.kind = 'order_escrow' AND a.owner_id IN (
           SELECT o.id FROM public.orders o JOIN public.restaurants r ON r.id = o.restaurant_id
           WHERE r.owner_id = %(m)s))
), txs AS (SELECT DISTINCT transaction_id FROM public.ledger_entries WHERE account_id IN (SELECT id FROM mine))
SELECT e.id FROM public.ledger_entries e JOIN public.ledger_accounts a ON a.id = e.account_id
WHERE e.account_id IN (SELECT id FROM mine)
   OR (a.owner_id IS NULL AND e.transaction_id IN (SELECT transaction_id FROM txs))
ORDER BY e.id
"""

VIEWS = ("entries", "payouts", "orders", "order_history", "contract", "my_proposals")


def visible_entry_ids(dsn: str, merchant: str | None) -> list[int]:
    with psycopg.connect(dsn) as conn:
        as_merchant(conn, "assist_reader", merchant)
        return [r[0] for r in conn.execute("SELECT entry_id FROM assist.entries ORDER BY entry_id")]


def test_each_merchant_sees_exactly_its_own_entries(dsn, admin, cases):
    for case in cases.values():
        m = case["merchant_id"]
        expected = [r[0] for r in admin.execute(ORACLE_SQL, {"m": m})]
        assert expected, f"{case['case_id']} has no entries; the oracle is vacuous"
        assert visible_entry_ids(dsn, m) == expected, case["case_id"]


def test_no_merchant_ever_sees_a_courier_leg(dsn, cases):
    for case in cases.values():
        with psycopg.connect(dsn) as conn:
            as_merchant(conn, "assist_reader", case["merchant_id"])
            kinds = {r[0] for r in conn.execute("SELECT DISTINCT account_kind::text FROM assist.entries")}
        assert "courier_payable" not in kinds


def test_orders_and_history_are_scoped(dsn, admin, cases):
    for case in list(cases.values())[:8]:
        m = case["merchant_id"]
        own = {r[0] for r in admin.execute(
            "SELECT o.id FROM public.orders o JOIN public.restaurants r ON r.id = o.restaurant_id "
            "WHERE r.owner_id = %s", (m,))}
        with psycopg.connect(dsn) as conn:
            as_merchant(conn, "assist_reader", m)
            seen = {r[0] for r in conn.execute("SELECT order_id FROM assist.orders")}
            hist = {r[0] for r in conn.execute("SELECT DISTINCT order_id FROM assist.order_history")}
        assert seen == own and len(own) == 3
        assert hist == own


@pytest.mark.parametrize("merchant", [None, ""])
def test_no_merchant_set_means_no_rows_anywhere(dsn, merchant):
    with psycopg.connect(dsn) as conn:
        as_merchant(conn, "assist_reader", merchant)
        for view in VIEWS:
            assert conn.execute(f"SELECT count(*) FROM assist.{view}").fetchone()[0] == 0, view


def leak_with_open_policies(dsn: str, merchant: str, tables: list[str]) -> list[int]:
    with psycopg.connect(dsn) as conn:
        for t in tables:
            conn.execute(f"ALTER POLICY assist_scope ON public.{t} USING (true)")
        as_merchant(conn, "assist_reader", merchant)
        rows = [r[0] for r in conn.execute("SELECT entry_id FROM assist.entries ORDER BY entry_id")]
        conn.rollback()
    return rows


def test_negative_control_an_open_policy_leaks_and_the_oracle_sees_it(dsn, admin, cases):
    """Replace the policies with USING (true) inside a rolled-back transaction:
    the same comparison must now fail, or it was never able to.

    One open policy is not enough. assist.entries joins ledger_accounts and
    ledger_transactions, and each carries its own policy, so opening
    ledger_entries alone leaks nothing. All three have to go."""
    m = next(iter(cases.values()))["merchant_id"]
    expected = [r[0] for r in admin.execute(ORACLE_SQL, {"m": m})]
    assert leak_with_open_policies(dsn, m, ["ledger_entries"]) == expected
    leaked = leak_with_open_policies(dsn, m, ["ledger_entries", "ledger_transactions", "ledger_accounts"])
    assert len(leaked) > len(expected)
    assert visible_entry_ids(dsn, m) == expected   # and the rollback restored it


# -- assist_propose: the agent's only write --------------------------------

def propose(dsn: str, merchant: str | None, kind: str, amount: int, entry_ids: list[int]) -> str:
    with psycopg.connect(dsn) as conn:
        as_merchant(conn, "assist_proposer", merchant)
        pid = conn.execute("SELECT public.assist_propose(%s, %s, %s, 'test')",
                           (kind, amount, entry_ids)).fetchone()[0]
        conn.commit()
        return pid


def test_propose_inserts_a_pending_row_and_posts_nothing(dsn, admin, cases):
    case = by_cause(cases, "commission_misapplied")[0]
    before = admin.execute("SELECT count(*) FROM public.ledger_transactions").fetchone()[0]
    pid = propose(dsn, case["merchant_id"], "commission_correction",
                  case["expected_proposal"]["amount_minor"], case["facts"]["evidence_entry_ids"])
    row = admin.execute("SELECT status, ledger_tx_id FROM public.assist_proposals WHERE id = %s",
                        (pid,)).fetchone()
    assert row == ("pending", None)
    assert admin.execute("SELECT count(*) FROM public.ledger_transactions").fetchone()[0] == before
    admin.execute("DELETE FROM public.assist_proposals WHERE id = %s", (pid,))


@pytest.mark.parametrize("scenario, reason", [
    ("other_merchants_entry", "ASSIST_EVIDENCE_NOT_VISIBLE"),
    ("phantom_entry", "ASSIST_EVIDENCE_NOT_VISIBLE"),
    ("amount_over_evidence", "ASSIST_AMOUNT_EXCEEDS_EVIDENCE"),
    ("no_merchant", "ASSIST_NO_MERCHANT"),
])
def test_propose_refuses(dsn, cases, scenario, reason):
    mine, other = by_cause(cases, "commission_misapplied")[:2]
    merchant, ids, amount = mine["merchant_id"], mine["facts"]["evidence_entry_ids"], 100
    if scenario == "other_merchants_entry":
        ids = other["facts"]["evidence_entry_ids"]
    elif scenario == "phantom_entry":
        ids = [10_000_000]
    elif scenario == "amount_over_evidence":
        amount = 1_000_000
    elif scenario == "no_merchant":
        merchant = None
    with pytest.raises(psycopg.Error) as exc:
        propose(dsn, merchant, "commission_correction", amount, ids)
    assert reason_of(exc.value) == reason


def test_pending_proposals_are_capped_at_five(dsn, admin, cases):
    case = by_cause(cases, "refund_duplicated")[0]
    ids = case["facts"]["evidence_entry_ids"]
    made = [propose(dsn, case["merchant_id"], "refund_reversal", 100, ids) for _ in range(5)]
    with pytest.raises(psycopg.Error) as exc:
        propose(dsn, case["merchant_id"], "refund_reversal", 100, ids)
    assert reason_of(exc.value) == "ASSIST_TOO_MANY_PENDING"
    admin.execute("DELETE FROM public.assist_proposals WHERE id = ANY(%s)", (made,))
