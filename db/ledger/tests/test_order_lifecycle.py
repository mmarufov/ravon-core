"""One order, every operation, exact numbers.

The state machine explores interleavings but cannot promise that any particular
operation ran in any particular run. This walks a single order through the whole
money model with the expected balance asserted after every step, so the rare
operations are always covered and the money model itself is readable as a
sequence of numbers rather than inferred from rules.
"""

from __future__ import annotations

from uuid import uuid4

from chart import (CURRENCY, courier_payable_for, escrow_for,
                   merchant_payable_for, open_chart, wallet_for)
from ledger_api import (Ledger, adjust_entries, authorize_entries,
                        capture_entries, chargeback_entries,
                        chargeback_reversal_entries, fingerprint_of,
                        promo_entries, refund_entries, settlement_entries,
                        tip_entries, wallet_spend_entries)

AUTHORIZED = 10_000
TIP = 1_501
PROMO = 2_000
REFUND = 1_000
CHARGEBACK = 500
SPLIT_BPS = [7000, 2000, 1000]      # merchant / courier / platform


def test_one_order_through_every_operation(ledger: Ledger):
    chart = open_chart(ledger)
    order_id, consumer_id, merchant_id, courier_id = (uuid4() for _ in range(4))
    escrow = escrow_for(ledger, order_id)
    wallet = wallet_for(ledger, consumer_id)
    merchant = merchant_payable_for(ledger, merchant_id)
    courier = courier_payable_for(ledger, courier_id)

    def post(event: str, entries, event_id=None):
        result = ledger.post(f"{event}:{uuid4()}", fingerprint_of(entries),
                             event, event_id or order_id, entries)
        # Conservation and cache consistency after every single operation.
        assert ledger.scalar(
            "SELECT COALESCE(SUM(CASE WHEN direction='debit' THEN amount_minor "
            "ELSE -amount_minor END), 0) FROM ledger_entries") == 0
        assert ledger.verify_balances() == []
        return result

    # 1. Authorize: we hold a claim on the consumer; the order's value is escrowed.
    post("authorize", authorize_entries(chart.receivable, escrow, AUTHORIZED, CURRENCY))
    assert ledger.natural_balance(chart.receivable) == AUTHORIZED
    assert ledger.natural_balance(escrow) == AUTHORIZED

    # 2. Capture: the claim becomes real money at the provider. Escrow is untouched.
    post("capture", capture_entries(chart.clearing, chart.receivable, AUTHORIZED, CURRENCY))
    assert ledger.natural_balance(chart.receivable) == 0
    assert ledger.natural_balance(chart.clearing) == AUTHORIZED
    assert ledger.natural_balance(escrow) == AUTHORIZED

    # 3. Tip, captured separately and added to the order's escrow.
    post("tip", tip_entries(chart.clearing, escrow, TIP, CURRENCY))
    assert ledger.natural_balance(escrow) == AUTHORIZED + TIP
    assert ledger.natural_balance(chart.clearing) == AUTHORIZED + TIP

    # 4. Promotional credit issued to the consumer: an expense to us, a balance
    #    to them. No money has moved at the provider.
    post("promo", promo_entries(chart.promo_expense, wallet, PROMO, CURRENCY),
         event_id=consumer_id)
    assert ledger.natural_balance(wallet) == PROMO
    assert ledger.natural_balance(chart.promo_expense) == PROMO
    assert ledger.natural_balance(chart.clearing) == AUTHORIZED + TIP

    # 5. The consumer spends that credit on this order.
    post("wallet_spend", wallet_spend_entries(wallet, escrow, PROMO, CURRENCY))
    assert ledger.natural_balance(wallet) == 0
    assert ledger.natural_balance(escrow) == AUTHORIZED + TIP + PROMO

    # 6. Partial refund: drains escrow, returns money at the provider.
    post("partial_refund", refund_entries(escrow, chart.clearing, REFUND, CURRENCY))
    assert ledger.natural_balance(escrow) == AUTHORIZED + TIP + PROMO - REFUND
    assert ledger.natural_balance(chart.clearing) == AUTHORIZED + TIP - REFUND

    # 7. Adjustment: the merchant is owed a little more than first booked. A new
    #    balanced transaction — the original is never touched.
    post("adjustment", adjust_entries(chart.revenue, merchant, 300, CURRENCY))
    assert ledger.natural_balance(merchant) == 300
    assert ledger.natural_balance(chart.revenue) == -300

    # 8. Settlement: split what is left in escrow, remainder to platform_rounding.
    total = ledger.natural_balance(escrow)
    assert total == 12_501
    merchant_cut, courier_cut, platform_cut, remainder = ledger.split(total, SPLIT_BPS)
    assert (merchant_cut, courier_cut, platform_cut, remainder) == (8750, 2500, 1250, 1)
    assert merchant_cut + courier_cut + platform_cut + remainder == total

    post("settlement", settlement_entries(
        escrow,
        [(merchant, merchant_cut), (courier, courier_cut),
         (chart.revenue, platform_cut), (chart.rounding, remainder)],
        total, CURRENCY))
    assert ledger.natural_balance(escrow) == 0, "escrow drained exactly"
    assert ledger.natural_balance(merchant) == 300 + merchant_cut
    assert ledger.natural_balance(courier) == courier_cut
    assert ledger.natural_balance(chart.revenue) == -300 + platform_cut
    assert ledger.natural_balance(chart.rounding) == 1, "the lost minor unit, kept"

    # 9. Courier payout, through the saga.
    payout_id = ledger.payout_begin(f"payout:{uuid4()}", courier, chart.clearing,
                                    courier_cut, CURRENCY)
    ledger.payout_mark_submitted(payout_id, "provider-ref-1")
    ledger.payout_post(payout_id)
    assert ledger.natural_balance(courier) == 0
    assert ledger.verify_balances() == []

    # 10. Chargeback: the bank pulls money back and the platform wears the loss.
    clearing_before = ledger.natural_balance(chart.clearing)
    post("chargeback", chargeback_entries(chart.chargeback_loss, chart.clearing,
                                          CHARGEBACK, CURRENCY))
    assert ledger.natural_balance(chart.chargeback_loss) == CHARGEBACK
    assert ledger.natural_balance(chart.clearing) == clearing_before - CHARGEBACK

    # 11. Chargeback reversal: we won the dispute. A reversing entry, not an undo.
    post("chargeback_reversal", chargeback_reversal_entries(
        chart.clearing, chart.chargeback_loss, CHARGEBACK, CURRENCY))
    assert ledger.natural_balance(chart.chargeback_loss) == 0
    assert ledger.natural_balance(chart.clearing) == clearing_before

    # -- the whole story, checked once more at the end ----------------------
    assert ledger.verify_balances() == []
    assert ledger.scalar(
        "SELECT COALESCE(SUM(CASE WHEN direction='debit' THEN amount_minor "
        "ELSE -amount_minor END), 0) FROM ledger_entries") == 0

    # Nothing was ever mutated: the ledger only grew.
    assert ledger.scalar("SELECT count(*) FROM ledger_transactions") == 11
    assert ledger.scalar(
        "SELECT count(*) FROM ledger_entries WHERE transaction_id IN "
        "(SELECT id FROM ledger_transactions WHERE business_event_type = 'settlement')") == 5

    # Every minor unit that entered the system is still accounted for somewhere.
    assert ledger.natural_balance(chart.clearing) == (
        AUTHORIZED + TIP - REFUND - courier_cut)


def test_refunded_never_exceeds_captured_for_the_order(ledger: Ledger):
    """Stated as its own test because it is the invariant the state machine
    asserts after every step, and it should be legible on its own."""
    chart = open_chart(ledger)
    order_id = uuid4()
    escrow = escrow_for(ledger, order_id)

    def post(event: str, entries):
        return ledger.post(f"{event}:{uuid4()}", fingerprint_of(entries),
                           event, order_id, entries)

    post("authorize", authorize_entries(chart.receivable, escrow, 10_000, CURRENCY))
    post("capture", capture_entries(chart.clearing, chart.receivable, 6_000, CURRENCY))
    post("partial_refund", refund_entries(escrow, chart.clearing, 4_000, CURRENCY))
    post("partial_refund", refund_entries(escrow, chart.clearing, 2_000, CURRENCY))

    totals = ledger.query("""
        SELECT COALESCE(SUM(e.amount_minor) FILTER (
                 WHERE t.business_event_type = 'capture' AND e.direction = 'debit'), 0),
               COALESCE(SUM(e.amount_minor) FILTER (
                 WHERE t.business_event_type = 'partial_refund' AND e.direction = 'debit'), 0)
        FROM ledger_transactions t
        JOIN ledger_entries e ON e.transaction_id = t.id
        WHERE t.business_event_id = %s
    """, (order_id,))
    captured, refunded = totals[0]
    assert captured == 6_000
    assert refunded == 6_000
    assert refunded <= captured
