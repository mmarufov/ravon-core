"""Types and knobs shared by the workflow, the activities and the tests.

Everything that crosses the Temporal boundary is a plain dataclass of strings
and ints, so the default JSON payload converter can carry it without help.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from datetime import timedelta

TASK_QUEUE = os.environ.get("PAYOUT_TASK_QUEUE", "payout-saga")

# How long Temporal waits before it decides an activity attempt is lost. A
# worker that is SIGKILLed cannot report anything, so this is the floor on how
# fast a mid-activity crash is noticed. The hand-built saga has no equivalent
# number: it notices nothing, because nothing is watching.
ACTIVITY_TIMEOUT = timedelta(seconds=float(os.environ.get("PAYOUT_ACTIVITY_TIMEOUT_S", "3")))
WORKFLOW_TASK_TIMEOUT = timedelta(seconds=2)

# How often the workflow re-asks the provider about a payout it holds as pending.
PENDING_POLL = timedelta(seconds=float(os.environ.get("PAYOUT_PENDING_POLL_S", "0.5")))


@dataclass(frozen=True)
class PayoutRequest:
    request_id: str             # the payout's idempotency key, same as the hand-built saga
    payee_account_id: str
    cash_account_id: str
    amount_minor: int
    currency: str


@dataclass(frozen=True)
class ProviderCall:
    request_id: str
    amount_minor: int
    currency: str
    payout_id: str = ""         # so a timeout can mark the ledger row 'unknown'


@dataclass(frozen=True)
class StatusCall:
    request_id: str


@dataclass(frozen=True)
class ProviderAnswer:
    """What the provider said, directly or, after a timeout, via status()."""
    provider_ref: str | None
    status: str                 # 'paid' | 'pending' | 'failed'
    failure_code: str | None    # 'declined' | 'returned' when failed


@dataclass(frozen=True)
class MarkCall:
    request_id: str
    payout_id: str
    provider_ref: str


@dataclass(frozen=True)
class PostCall:
    request_id: str
    payout_id: str


@dataclass(frozen=True)
class FailCall:
    request_id: str
    payout_id: str
    verdict: str                # the provider's: 'declined' | 'not_found' | 'returned'
    reason: str


@dataclass(frozen=True)
class Posted:
    transaction_id: str
    replayed: bool


@dataclass(frozen=True)
class PayoutOutcome:
    payout_id: str
    state: str                  # 'posted' | 'failed'
    transaction_id: str | None
