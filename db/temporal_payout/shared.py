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
