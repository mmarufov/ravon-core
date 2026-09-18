"""Randomised operation sequences checked against a model.

A Hypothesis RuleBasedStateMachine drives the ledger through arbitrary
interleavings of the operations a delivery marketplace actually performs, and
after *every* single one of them re-checks six invariants against the database.

The oracle is a plain `dict[account_id, int]`. Every rule applies its effect to
both PostgreSQL and the dict; if the two ever disagree the run fails and
Hypothesis shrinks the sequence to the shortest one that still breaks it. The
model is deliberately trivial — the point is that something as simple as a dict
of integers is enough to catch the database being wrong, and a dict cannot be
wrong in the same way the database is.
"""

from __future__ import annotations

import collections
from dataclasses import dataclass
from uuid import UUID, uuid4

import psycopg
import pytest

WORK_SUMMARY = pytest.StashKey[list]()
from hypothesis import settings as hypothesis_settings
from hypothesis import strategies as st
from hypothesis.stateful import (Bundle, RuleBasedStateMachine, consumes,
                                 initialize, invariant, multiple, precondition,
                                 rule, run_state_machine_as_test)

from chart import (CURRENCY, courier_payable_for, escrow_for,
                   merchant_payable_for, open_chart, wallet_for)
from conftest import MAX_EXAMPLES, reset_ledger
from ledger_api import (Entry, Ledger, LedgerError, adjust_entries,
                        authorize_entries, capture_entries,
                        chargeback_entries, chargeback_reversal_entries,
                        credit, debit, fingerprint_of, promo_entries,
                        refund_entries, settlement_entries, tip_entries,
                        wallet_spend_entries)

# How much work the run actually did. A stateful suite that quietly degenerates
# into zero-step runs still passes, and passing for that reason is worse than
# failing — so the test asserts a floor on these at the end.
WORK: collections.Counter = collections.Counter()

AMOUNTS = st.integers(min_value=1, max_value=250_000)
SMALL = st.integers(min_value=1, max_value=5_000)
FRACTION = st.integers(min_value=1, max_value=100)

# One invariant query per step, so that a step costs one round trip to apply and
# one to verify rather than six.
INVARIANT_SQL = """
SELECT jsonb_build_object(
  'global_sum', (
     SELECT COALESCE(SUM(CASE WHEN direction = 'debit' THEN amount_minor
                              ELSE -amount_minor END), 0)
     FROM ledger_entries),
  'unbalanced_transactions', (
     SELECT COALESCE(jsonb_agg(x.transaction_id), '[]'::jsonb) FROM (
       SELECT transaction_id FROM ledger_entries GROUP BY transaction_id
       HAVING SUM(CASE WHEN direction = 'debit' THEN amount_minor
                       ELSE -amount_minor END) <> 0) x),
  'multi_currency_transactions', (
     SELECT COALESCE(jsonb_agg(x.transaction_id), '[]'::jsonb) FROM (
       SELECT transaction_id FROM ledger_entries GROUP BY transaction_id
       HAVING count(DISTINCT currency) > 1) x),
  'cache_mismatches', (
     SELECT COALESCE(jsonb_agg(to_jsonb(v)), '[]'::jsonb) FROM ledger_verify_balances() v),
  'balances', (
     SELECT COALESCE(jsonb_object_agg(account_id::text, balance_minor), '{}'::jsonb)
     FROM ledger_balances),
  'per_order', (
     SELECT COALESCE(jsonb_object_agg(s.order_id, s.totals), '{}'::jsonb) FROM (
       SELECT t.business_event_id::text AS order_id,
              jsonb_build_object(
                'captured', COALESCE(SUM(e.amount_minor) FILTER (
                   WHERE t.business_event_type = 'capture' AND e.direction = 'debit'), 0),
                'refunded', COALESCE(SUM(e.amount_minor) FILTER (
                   WHERE t.business_event_type IN ('partial_refund', 'full_refund')
                     AND e.direction = 'debit'), 0)) AS totals
       FROM ledger_transactions t
       JOIN ledger_entries e ON e.transaction_id = t.id
       GROUP BY t.business_event_id) s)
)
"""


@dataclass
class Party:
    party_id: UUID
    account_id: UUID


@dataclass
class Order:
    order_id: UUID
    escrow: UUID
    consumer: Party
    merchant: Party
    courier: Party
    authorized: int
    captured: int = 0
    refunded: int = 0
    charged_back: int = 0
    settled: bool = False


@dataclass
class Posting:
    """A posting that already happened, kept so it can be replayed verbatim."""
    key: str
    fingerprint: str
    event_type: str
    event_id: UUID
    entries: list[Entry]
    transaction_id: UUID


@dataclass
class Payout:
    payout_id: UUID
    payee: UUID
    amount: int
    posted: bool = False


class LedgerMachine(RuleBasedStateMachine):
    dsn: str = ""                                # injected by the test below

    consumers = Bundle("consumers")
    merchants = Bundle("merchants")
    couriers = Bundle("couriers")
    orders = Bundle("orders")
    payouts = Bundle("payouts")

    def __init__(self) -> None:
        super().__init__()
        self.conn = psycopg.connect(self.dsn)
        reset_ledger(self.conn)
        self.ledger = Ledger(self.conn)
        self.chart = open_chart(self.ledger)
        self.model: dict[UUID, int] = {}
        self.order_state: dict[UUID, Order] = {}
        # Every posting ever made, so `replay` can re-send any of them — not
        # just the most recent, and not just one operation type.
        self.log: list[Posting] = []
        self.rejections = 0
        # Hypothesis does not weight rules: it picks from whatever is currently
        # applicable, and argument-free rules get picked far more often than
        # rules that must draw a bundle value. Measured, `open_consumer` took
        # 30% of all steps while `chargeback` and `courier_payout` never fired
        # once in 460. Capping the cheap rules with preconditions moves that
        # probability mass onto the operations that actually move money.
        self.fired: collections.Counter = collections.Counter()

    def teardown(self) -> None:
        self.assert_ledger_invariants()
        self.conn.close()

    # -- model plumbing ----------------------------------------------------

    def _apply(self, entries: list[Entry]) -> None:
        for entry in entries:
            self.model[entry.account_id] = self.model.get(entry.account_id, 0) + entry.signed

    def _post(self, event_type: str, event_id: UUID, entries: list[Entry],
              key: str | None = None) -> Posting:
        """Post to PostgreSQL, then to the dict. Never the other way round: if
        the database rejects, the model must not have moved."""
        key = key or f"{event_type}:{uuid4()}"
        fingerprint = fingerprint_of(entries)
        result = self.ledger.post(key, fingerprint, event_type, event_id, entries)
        if not result.replayed:
            self._apply(entries)
        posting = Posting(key, fingerprint, event_type, event_id, list(entries),
                          result.transaction_id)
        self.log.append(posting)
        WORK["posts"] += 1
        WORK[f"post:{event_type}"] += 1
        return posting

    def _natural(self, account_id: UUID, kind_sign: int) -> int:
        return self.model.get(account_id, 0) * kind_sign

    def _escrow_balance(self, order: Order) -> int:
        return -self.model.get(order.escrow, 0)          # credit-normal

    def _payable_balance(self, account_id: UUID) -> int:
        return -self.model.get(account_id, 0)            # credit-normal

    # =====================================================================
    # Rules — open account
    # =====================================================================

    @initialize(target=consumers)
    def seed_consumer(self) -> Party:
        """Bundles start empty, so without a seeded party of each kind the
        order rules are unreachable until Hypothesis happens to draw all three
        openers — which, measured, left 18 of 32 runs posting nothing at all."""
        WORK["rule:seed_consumer"] += 1
        self.fired["seed_consumer"] += 1
        party_id = uuid4()
        return Party(party_id, wallet_for(self.ledger, party_id))

    @initialize(target=merchants)
    def seed_merchant(self) -> Party:
        WORK["rule:seed_merchant"] += 1
        self.fired["seed_merchant"] += 1
        party_id = uuid4()
        return Party(party_id, merchant_payable_for(self.ledger, party_id))

    @initialize(target=couriers)
    def seed_courier(self) -> Party:
        WORK["rule:seed_courier"] += 1
        self.fired["seed_courier"] += 1
        party_id = uuid4()
        return Party(party_id, courier_payable_for(self.ledger, party_id))

    @precondition(lambda self: self.fired["open_consumer"] < 3)
    @rule(target=consumers)
    def open_consumer(self) -> Party:
        WORK["rule:open_consumer"] += 1
        self.fired["open_consumer"] += 1
        party_id = uuid4()
        return Party(party_id, wallet_for(self.ledger, party_id))

    @precondition(lambda self: self.fired["open_merchant"] < 3)
    @rule(target=merchants)
    def open_merchant(self) -> Party:
        WORK["rule:open_merchant"] += 1
        self.fired["open_merchant"] += 1
        party_id = uuid4()
        return Party(party_id, merchant_payable_for(self.ledger, party_id))

    @precondition(lambda self: self.fired["open_courier"] < 3)
    @rule(target=couriers)
    def open_courier(self) -> Party:
        WORK["rule:open_courier"] += 1
        self.fired["open_courier"] += 1
        party_id = uuid4()
        return Party(party_id, courier_payable_for(self.ledger, party_id))

    # =====================================================================
    # Rules — the order money flow
    # =====================================================================

    # Capped so that later steps operate on orders that already exist rather
    # than opening new ones: without this, `authorize` fired 212 times against
    # 38 captures, and refunds — which need a capture — almost never ran.
    @precondition(lambda self: self.fired["authorize"] < 6)
    @rule(target=orders, consumer=consumers, merchant=merchants, courier=couriers,
          amount=AMOUNTS)
    def authorize(self, consumer: Party, merchant: Party, courier: Party,
                  amount: int) -> Order:
        WORK["rule:authorize"] += 1
        self.fired["authorize"] += 1
        order_id = uuid4()
        escrow = escrow_for(self.ledger, order_id)
        order = Order(order_id, escrow, consumer, merchant, courier, amount)
        self._post("authorize", order_id,
                   authorize_entries(self.chart.receivable, escrow, amount, CURRENCY))
        self.order_state[order_id] = order
        return order

    @rule(order=orders, fraction=FRACTION)
    def capture(self, order: Order, fraction: int) -> None:
        """Capture up to what was authorized — never more. Over-capturing is
        structurally impossible anyway: order_receivable may not go negative."""
        WORK["rule:capture"] += 1
        self.fired["capture"] += 1
        remaining = order.authorized - order.captured
        if remaining <= 0:
            return
        amount = max(1, remaining * fraction // 100)
        self._post("capture", order.order_id,
                   capture_entries(self.chart.clearing, self.chart.receivable,
                                   amount, CURRENCY))
        order.captured += amount

    @rule(order=orders, amount=SMALL)
    def add_tip(self, order: Order, amount: int) -> None:
        WORK["rule:add_tip"] += 1
        self.fired["add_tip"] += 1
        self._post("tip", order.order_id,
                   tip_entries(self.chart.clearing, order.escrow, amount, CURRENCY))

    @precondition(lambda self: self.fired["promo_credit"] < 8)
    @rule(consumer=consumers, amount=SMALL)
    def promo_credit(self, consumer: Party, amount: int) -> None:
        WORK["rule:promo_credit"] += 1
        self.fired["promo_credit"] += 1
        self._post("promo", consumer.party_id,
                   promo_entries(self.chart.promo_expense, consumer.account_id,
                                 amount, CURRENCY))

    @rule(order=orders, fraction=FRACTION)
    def spend_wallet(self, order: Order, fraction: int) -> None:
        """Consumer credit pays part of the order. Bounded by the wallet, which
        the database will not let go negative."""
        WORK["rule:spend_wallet"] += 1
        self.fired["spend_wallet"] += 1
        available = self._payable_balance(order.consumer.account_id)
        if available <= 0:
            return
        amount = max(1, available * fraction // 100)
        self._post("wallet_spend", order.order_id,
                   wallet_spend_entries(order.consumer.account_id, order.escrow,
                                        amount, CURRENCY))

    @rule(order=orders, fraction=FRACTION)
    def partial_refund(self, order: Order, fraction: int) -> None:
        """Refunds are bounded twice over: by the funds still held for the order
        (the database enforces this) and by what was actually captured (service
        policy — you cannot give back money you never took)."""
        WORK["rule:partial_refund"] += 1
        self.fired["partial_refund"] += 1
        headroom = min(self._escrow_balance(order),
                       order.captured - order.refunded - order.charged_back)
        if headroom <= 0:
            return
        amount = max(1, headroom * fraction // 100)
        self._post("partial_refund", order.order_id,
                   refund_entries(order.escrow, self.chart.clearing, amount, CURRENCY))
        order.refunded += amount

    @rule(order=orders)
    def full_refund(self, order: Order) -> None:
        WORK["rule:full_refund"] += 1
        self.fired["full_refund"] += 1
        amount = min(self._escrow_balance(order),
                     order.captured - order.refunded - order.charged_back)
        if amount <= 0:
            return
        self._post("full_refund", order.order_id,
                   refund_entries(order.escrow, self.chart.clearing, amount, CURRENCY))
        order.refunded += amount

    @rule(order=orders, fraction=FRACTION)
    def chargeback(self, order: Order, fraction: int) -> None:
        WORK["rule:chargeback"] += 1
        self.fired["chargeback"] += 1
        headroom = order.captured - order.refunded - order.charged_back
        if headroom <= 0:
            return
        amount = max(1, headroom * fraction // 100)
        self._post("chargeback", order.order_id,
                   chargeback_entries(self.chart.chargeback_loss, self.chart.clearing,
                                      amount, CURRENCY))
        order.charged_back += amount

    @precondition(lambda self: self.fired["chargeback_reversal"] < 6)
    @rule(order=orders)
    def chargeback_reversal(self, order: Order) -> None:
        WORK["rule:chargeback_reversal"] += 1
        self.fired["chargeback_reversal"] += 1
        if order.charged_back <= 0:
            return
        amount = order.charged_back
        self._post("chargeback_reversal", order.order_id,
                   chargeback_reversal_entries(self.chart.clearing,
                                               self.chart.chargeback_loss,
                                               amount, CURRENCY))
        order.charged_back = 0

    @rule(order=orders, merchant_bps=st.integers(min_value=0, max_value=9000),
          courier_bps=st.integers(min_value=0, max_value=9000))
    def settle(self, order: Order, merchant_bps: int, courier_bps: int) -> None:
        """Split whatever is left in escrow across merchant, courier and
        platform, with the flooring remainder to platform_rounding."""
        WORK["rule:settle"] += 1
        self.fired["settle"] += 1
        total = self._escrow_balance(order)
        if total <= 0:
            return
        if merchant_bps + courier_bps > 10_000:
            courier_bps = 10_000 - merchant_bps
        platform_bps = 10_000 - merchant_bps - courier_bps

        merchant_cut, courier_cut, platform_cut, remainder = self.ledger.split(
            total, [merchant_bps, courier_bps, platform_bps])
        assert merchant_cut + courier_cut + platform_cut + remainder == total

        legs = settlement_entries(
            order.escrow,
            [(order.merchant.account_id, merchant_cut),
             (order.courier.account_id, courier_cut),
             (self.chart.revenue, platform_cut),
             (self.chart.rounding, remainder)],
            total, CURRENCY)
        self._post("settlement", order.order_id, legs)
        order.settled = True

    @precondition(lambda self: self.fired["adjust"] < 8)
    @rule(order=orders, delta=st.integers(min_value=-5_000, max_value=5_000))
    def adjust(self, order: Order, delta: int) -> None:
        """A post-capture correction between the platform's share and the
        merchant's. Always a new balanced transaction, never a mutation."""
        WORK["rule:adjust"] += 1
        self.fired["adjust"] += 1
        if delta == 0:
            return
        if delta < 0:
            available = self._payable_balance(order.merchant.account_id)
            if available <= 0:
                return
            delta = -min(-delta, available)
        self._post("adjustment", order.order_id,
                   adjust_entries(self.chart.revenue, order.merchant.account_id,
                                  delta, CURRENCY))

    # =====================================================================
    # Rules — payouts (the saga, without crashes; those are in test_payout_saga)
    # =====================================================================

    @precondition(lambda self: self.fired["courier_payout"] < 8)
    @rule(target=payouts, courier=couriers, fraction=FRACTION)
    def courier_payout(self, courier: Party, fraction: int):
        WORK["rule:courier_payout"] += 1
        self.fired["courier_payout"] += 1
        owed = self._payable_balance(courier.account_id)
        if owed <= 0:
            return multiple()
        amount = max(1, owed * fraction // 100)
        payout_id = self.ledger.payout_begin(
            f"payout:{uuid4()}", courier.account_id, self.chart.clearing, amount, CURRENCY)
        self.ledger.payout_mark_submitted(payout_id, f"ref:{payout_id}")
        self.ledger.payout_post(payout_id)
        self._apply([debit(courier.account_id, amount, CURRENCY),
                     credit(self.chart.clearing, amount, CURRENCY)])
        return Payout(payout_id, courier.account_id, amount, posted=True)

    @rule(payout=consumes(payouts))
    def payout_reversal(self, payout: Payout) -> None:
        WORK["rule:payout_reversal"] += 1
        self.fired["payout_reversal"] += 1
        self.ledger.payout_fail(payout.payout_id, "bank returned it")
        if payout.posted:
            self._apply([debit(self.chart.clearing, payout.amount, CURRENCY),
                         credit(payout.payee, payout.amount, CURRENCY)])

    @precondition(lambda self: self.fired["payout_failure_before_posting"] < 4)
    @rule(target=payouts, courier=couriers, amount=SMALL)
    def payout_failure_before_posting(self, courier: Party, amount: int):
        """A payout that the provider declines before anything was posted must
        leave no ledger effect at all."""
        WORK["rule:payout_failure_before_posting"] += 1
        self.fired["payout_failure_before_posting"] += 1
        payout_id = self.ledger.payout_begin(
            f"payout:{uuid4()}", courier.account_id, self.chart.clearing, amount, CURRENCY)
        self.ledger.payout_mark_submitted(payout_id, f"ref:{payout_id}")
        self.ledger.payout_fail(payout_id, "provider declined")
        return multiple()

    # =====================================================================
    # Rules — replay
    # =====================================================================

    @precondition(lambda self: bool(self.log))
    @precondition(lambda self: self.fired["replay_a_prior_operation"] < 8)
    @rule(index=st.integers(min_value=0, max_value=10 ** 6))
    def replay_a_prior_operation(self, index: int) -> None:
        """Re-send any earlier request verbatim — an authorize, a settlement, a
        chargeback reversal, whatever it was — with its original idempotency
        key. It must return the original transaction and change nothing.

        The model is deliberately *not* updated here. If the database were to
        double-post, the next invariant check would see the database ahead of
        the model and fail.
        """
        WORK["rule:replay_a_prior_operation"] += 1
        self.fired["replay_a_prior_operation"] += 1
        posting = self.log[index % len(self.log)]
        result = self.ledger.post(posting.key, posting.fingerprint,
                                  posting.event_type, posting.event_id, posting.entries)
        assert result.replayed is True
        assert result.transaction_id == posting.transaction_id

    @precondition(lambda self: bool(self.log))
    @precondition(lambda self: self.fired["replay_with_a_different_body_is_a_conflict"] < 4)
    @rule(index=st.integers(min_value=0, max_value=10 ** 6), extra=SMALL)
    def replay_with_a_different_body_is_a_conflict(self, index: int, extra: int) -> None:
        """Same key, different money. DoorDash's contract says 409, so does this."""
        WORK["rule:replay_with_a_different_body_is_a_conflict"] += 1
        self.fired["replay_with_a_different_body_is_a_conflict"] += 1
        posting = self.log[index % len(self.log)]
        mutated = [Entry(e.account_id, e.direction, e.amount_minor + extra, e.currency)
                   for e in posting.entries]
        with pytest.raises(LedgerError) as exc:
            self.ledger.post(posting.key, fingerprint_of(mutated),
                             posting.event_type, posting.event_id, mutated)
        assert exc.value.reason == "IDEMPOTENCY_KEY_CONFLICT"
        assert exc.value.http_status == 409
        self.rejections += 1
        WORK["rejections"] += 1

    # =====================================================================
    # Rules — operations that must be rejected
    # =====================================================================

    @precondition(lambda self: self.fired["attempt_an_over_refund"] < 6)
    @rule(order=orders, excess=SMALL)
    def attempt_an_over_refund(self, order: Order, excess: int) -> None:
        """Refund strictly more than the order is holding. The amount is chosen
        from the model, so the expected outcome is not a guess."""
        WORK["rule:attempt_an_over_refund"] += 1
        self.fired["attempt_an_over_refund"] += 1
        amount = self._escrow_balance(order) + excess
        with pytest.raises(LedgerError) as exc:
            self.ledger.post(f"over-refund:{uuid4()}", "fp", "partial_refund",
                             order.order_id,
                             refund_entries(order.escrow, self.chart.clearing,
                                            amount, CURRENCY))
        assert exc.value.reason == "NEGATIVE_BALANCE_NOT_ALLOWED"
        assert exc.value.detail["attempted_balance_minor"] == -excess
        self.rejections += 1
        WORK["rejections"] += 1

    @precondition(lambda self: bool(self.order_state))
    @precondition(lambda self: self.fired["attempt_to_overdraw_a_payable"] < 6)
    @rule(courier=couriers, excess=SMALL)
    def attempt_to_overdraw_a_payable(self, courier: Party, excess: int) -> None:
        WORK["rule:attempt_to_overdraw_a_payable"] += 1
        self.fired["attempt_to_overdraw_a_payable"] += 1
        amount = self._payable_balance(courier.account_id) + excess
        with pytest.raises(LedgerError) as exc:
            self.ledger.post(f"over-payout:{uuid4()}", "fp", "payout",
                             courier.party_id,
                             [debit(courier.account_id, amount, CURRENCY),
                              credit(self.chart.clearing, amount, CURRENCY)])
        assert exc.value.reason == "NEGATIVE_BALANCE_NOT_ALLOWED"
        self.rejections += 1
        WORK["rejections"] += 1

    @precondition(lambda self: bool(self.order_state))
    @precondition(lambda self: self.fired["attempt_an_unbalanced_posting"] < 6)
    @rule(order=orders, amount=SMALL, delta=st.integers(min_value=1, max_value=999))
    def attempt_an_unbalanced_posting(self, order: Order, amount: int, delta: int) -> None:
        WORK["rule:attempt_an_unbalanced_posting"] += 1
        self.fired["attempt_an_unbalanced_posting"] += 1
        with pytest.raises(LedgerError) as exc:
            self.ledger.post(f"unbalanced:{uuid4()}", "fp", "authorize", order.order_id,
                             [debit(self.chart.receivable, amount + delta, CURRENCY),
                              credit(order.escrow, amount, CURRENCY)])
        assert exc.value.reason == "UNBALANCED_TRANSACTION"
        assert exc.value.detail["delta_minor"] == delta
        self.rejections += 1
        WORK["rejections"] += 1

    # =====================================================================
    # Invariants — re-checked after every rule
    # =====================================================================

    @invariant()
    def assert_ledger_invariants(self) -> None:
        WORK["invariant_checks"] += 1
        with self.conn.cursor() as cur:
            cur.execute(INVARIANT_SQL)
            state = cur.fetchone()[0]
        self.conn.commit()

        assert state["global_sum"] == 0, \
            f"money was created or destroyed: net {state['global_sum']}"
        assert state["unbalanced_transactions"] == [], \
            f"unbalanced transactions committed: {state['unbalanced_transactions']}"
        assert state["multi_currency_transactions"] == [], \
            f"mixed-currency transactions committed: {state['multi_currency_transactions']}"
        assert state["cache_mismatches"] == [], \
            f"balance cache drifted from the entries: {state['cache_mismatches']}"

        expected = {str(k): v for k, v in self.model.items()}
        assert state["balances"] == expected, _diff(expected, state["balances"])

        for order_id, totals in state["per_order"].items():
            assert totals["refunded"] <= totals["captured"], (
                f"order {order_id} refunded {totals['refunded']} of "
                f"{totals['captured']} captured")


def _diff(expected: dict[str, int], actual: dict[str, int]) -> str:
    keys = sorted(set(expected) | set(actual))
    rows = [f"  {k}: model={expected.get(k, 0)} db={actual.get(k, 0)}"
            for k in keys if expected.get(k, 0) != actual.get(k, 0)]
    return "model and database disagree:\n" + "\n".join(rows)


def test_ledger_state_machine(state_machine_dsn: str, request):
    LedgerMachine.dsn = state_machine_dsn
    WORK.clear()
    run_state_machine_as_test(
        LedgerMachine,
        settings=hypothesis_settings(
            parent=hypothesis_settings.get_profile("ci"),
            print_blob=True,          # a failure prints a blob that replays it exactly
        ),
    )

    summary = ", ".join(f"{k}={v}" for k, v in sorted(WORK.items()))
    request.config.stash.setdefault(WORK_SUMMARY, []).append(summary)
    print(f"\nstate machine coverage: {summary}")

    # Floors, not targets, and scaled to the configured budget so that lowering
    # LEDGER_MAX_EXAMPLES weakens the run without falsely failing it. These exist
    # because a stateful suite whose bundles never fill, or whose rules all
    # no-op, passes silently — which is how this machine spent its first
    # measured run doing almost nothing at all.
    assert WORK["invariant_checks"] >= 5 * MAX_EXAMPLES, (
        f"only {WORK['invariant_checks']} invariant checks ran for {MAX_EXAMPLES} "
        "examples; the state machine is not exploring. Check that the @initialize "
        "rules still populate the bundles.")
    assert WORK["posts"] >= 2 * MAX_EXAMPLES, (
        f"only {WORK['posts']} postings were made across {MAX_EXAMPLES} examples")
    assert WORK["rejections"] >= MAX_EXAMPLES // 2, (
        f"only {WORK['rejections']} operations were rejected; the negative-path "
        "rules are not firing")
    # Every money-moving operation must have run at least once — but only at the
    # budget CI actually uses. A deliberately shrunk run (LEDGER_MAX_EXAMPLES=20
    # for a quick local check) cannot reach every operation, and failing it for
    # that would train people to ignore this test. The rarer operations
    # (full_refund, chargeback_reversal) are not required even here: they are
    # covered deterministically by test_order_lifecycle.py, and requiring a rare
    # rule would make this the flakiest assertion in the suite.
    if MAX_EXAMPLES >= 100:
        for required in ("post:authorize", "post:capture", "post:settlement",
                         "post:tip", "post:promo", "post:wallet_spend",
                         "post:adjustment", "post:chargeback"):
            assert WORK[required] > 0, (
                f"no {required} operation was ever exercised in {MAX_EXAMPLES} examples")
