"""A standard chart of accounts for the tests.

Mirrors what the Ravon marketplace actually needs: money sits at the payment
provider, is held per order in escrow, and is owed out to merchants and couriers.

Which accounts may go negative is the interesting column:

  psp_clearing      allow_negative=True   a clearing account legitimately goes
                                          negative between payout and settlement
  platform_revenue  allow_negative=True   a young marketplace can run a negative
                                          take; refusing to record that would be
                                          the ledger lying
  platform_rounding allow_negative=True   remainders are signed
  order_escrow      allow_negative=False  <- makes over-refunding impossible
  *_payable         allow_negative=False  <- makes over-paying impossible
  consumer_wallet   allow_negative=False  <- makes over-spending impossible
"""

from __future__ import annotations

from dataclasses import dataclass
from uuid import UUID

from ledger_api import Ledger

CURRENCY = "TJS"


@dataclass(frozen=True)
class Chart:
    clearing: UUID
    revenue: UUID
    rounding: UUID
    promo_expense: UUID
    chargeback_loss: UUID
    receivable: UUID
    currency: str = CURRENCY


def open_chart(ledger: Ledger, currency: str = CURRENCY) -> Chart:
    return Chart(
        clearing=ledger.open_account("psp_clearing", None, currency, allow_negative=True),
        revenue=ledger.open_account("platform_revenue", None, currency, allow_negative=True),
        rounding=ledger.open_account("platform_rounding", None, currency, allow_negative=True),
        promo_expense=ledger.open_account("promo_expense", None, currency),
        chargeback_loss=ledger.open_account("chargeback_loss", None, currency),
        receivable=ledger.open_account("order_receivable", None, currency),
        currency=currency,
    )


def escrow_for(ledger: Ledger, order_id: UUID, currency: str = CURRENCY) -> UUID:
    return ledger.open_account("order_escrow", order_id, currency)


def wallet_for(ledger: Ledger, consumer_id: UUID, currency: str = CURRENCY) -> UUID:
    return ledger.open_account("consumer_wallet", consumer_id, currency)


def merchant_payable_for(ledger: Ledger, merchant_id: UUID, currency: str = CURRENCY) -> UUID:
    return ledger.open_account("merchant_payable", merchant_id, currency)


def courier_payable_for(ledger: Ledger, courier_id: UUID, currency: str = CURRENCY) -> UUID:
    return ledger.open_account("courier_payable", courier_id, currency)
