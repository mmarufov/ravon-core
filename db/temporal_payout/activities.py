"""The payout saga's side effects, as Temporal activities.

Every database call goes through db/ledger/tests/ledger_api.py, the same client
the hand-built suite uses, against the same schema.sql. The two implementations
therefore differ only in who decides what runs next.

Temporal runs each activity at least once, not exactly once: a worker that dies
after COMMIT but before reporting back gets the activity run again. Each
activity below is therefore safe to repeat, and the reason it is safe is always
something in the database, never something in Temporal.
"""

# No `from __future__ import annotations`: the faults wrapper copies
# __annotations__, and Temporal must see real types there, not strings it
# would have to resolve in the wrong module.
import os
from contextlib import contextmanager
from typing import Iterator
from uuid import UUID

import psycopg
from temporalio import activity
from temporalio.exceptions import ApplicationError

import faults
import provider
from ledger_api import Ledger, LedgerError
from shared import FailCall, MarkCall, PayoutRequest, Posted, PostCall, ProviderCall

# Schema reasons that mean "try again", not "this request is wrong".
RETRYABLE_REASONS = {"PAYOUT_RACE_RETRY", "IDEMPOTENCY_RACE_RETRY"}


@contextmanager
def _ledger() -> Iterator[Ledger]:
    """One connection per attempt. A retried attempt never reuses a dead one."""
    conn = psycopg.connect(os.environ["LEDGER_TEMPORAL_DSN"])
    try:
        yield faults.ledger_class()(conn)
    except LedgerError as exc:
        # Temporal retries every exception unless told otherwise. A structured
        # 4xx from the schema is a verdict, and retrying it forever would just
        # re-ask the same question. A dropped connection has reason=None and
        # stays retryable, which is what recovers a killed backend.
        if exc.reason and exc.reason not in RETRYABLE_REASONS and (exc.http_status or 500) < 500:
            raise ApplicationError(str(exc), exc.detail, type=exc.reason,
                                   non_retryable=True) from exc
        raise
    finally:
        conn.close()


@activity.defn
@faults.injectable("begin")
def begin_payout(req: PayoutRequest) -> str:
    # Repeat-safe because ledger_payout_begin is ON CONFLICT (request_id).
    with _ledger() as ledger:
        return str(ledger.payout_begin(req.request_id, UUID(req.payee_account_id),
                                       UUID(req.cash_account_id), req.amount_minor, req.currency))


@activity.defn
@faults.injectable("provider")
def submit_to_provider(call: ProviderCall) -> str | None:
    # Repeat-safe only because the provider is idempotent on request_id.
    return provider.submit(os.environ["PROVIDER_DSN"], call.request_id,
                           call.amount_minor, call.currency)


@activity.defn
@faults.injectable("mark")
def mark_submitted(call: MarkCall) -> str:
    # Repeat-safe because a submitted or posted payout returns its state unchanged.
    with _ledger() as ledger:
        return ledger.payout_mark_submitted(UUID(call.payout_id), call.provider_ref)


@activity.defn
@faults.injectable("post")
def post_payout(call: PostCall) -> Posted:
    # Repeat-safe because the ledger key is 'payout:' || payout_id; a second
    # attempt gets replayed=True and the first attempt's transaction id.
    with _ledger() as ledger:
        result = ledger.payout_post(UUID(call.payout_id))
    return Posted(str(result.transaction_id), result.replayed)


@activity.defn
@faults.injectable("fail")
def fail_payout(call: FailCall) -> str:
    with _ledger() as ledger:
        return ledger.payout_fail(UUID(call.payout_id), call.reason)


ALL = [begin_payout, submit_to_provider, mark_submitted, post_payout, fail_payout]
