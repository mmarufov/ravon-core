"""The recovery sweeper the hand-built saga does not have.

    LEDGER_TEMPORAL_DSN=... PROVIDER_DSN=... python resolver.py [--older-than 30]

The hand-built saga's resume path used to take the provider's answer as an
argument: "NULL means the provider never got it". Nothing ever asked. After a
timeout that is exactly the wrong assumption, because a provider can pay and
then lose the reply. This module asks.

For one payout, `resolve()` does whatever the provider's answer allows, and
nothing else:

    pending / unknown  status(request_id)
                         paid       -> mark submitted, post
                         pending    -> mark submitted, wait
                         failed     -> fail with the provider's verdict
                         not_found  -> resubmit under the SAME request id
                                       (it has no record, so this cannot pay twice)
    submitted          status(ref): paid -> post; failed -> fail; pending -> wait
    posted             status(ref): failed/returned -> fail('returned'), which
                       posts the reversal
    failed             nothing

A status call that times out changes nothing; the payout is looked at again on
the next sweep. There is no branch that fails a payout on silence, and the
schema would refuse one (PAYOUT_VERDICT_REQUIRED).

What this still assumes, and cannot check: that `status()` reads records that
outlive the provider's idempotency key, and that a request the provider reports
as `not_found` can no longer land. `sweep()` only touches payouts older than
`older_than_s`, which is meant to exceed the provider's request deadline, so a
live driver's in-flight call is not raced.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import sys
from typing import Callable
from uuid import UUID

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "ledger" / "tests"))

import psycopg  # noqa: E402

import provider  # noqa: E402
from ledger_api import Ledger  # noqa: E402

StatusFn = Callable[..., provider.Status]


def _handle_answer(ledger: Ledger, payout_id: UUID, state: str, answer: provider.Status) -> str:
    """Apply one provider answer to a payout that is pending, unknown or submitted."""
    if answer.state == "paid":
        return ledger.payout_resume(payout_id, answer.provider_ref)
    if answer.state == "pending":
        if state != "submitted":
            ledger.payout_mark_submitted(payout_id, answer.provider_ref)
        return "submitted"
    if answer.state == "failed":
        return ledger.payout_fail(payout_id, answer.failure_code,
                                  f"provider: failed/{answer.failure_code}")
    return state


def resolve(ledger: Ledger, provider_target, payout_id: UUID, *, now: float | None = None,
            ask_unknown: bool = True, ttl: float | None = None,
            status_fn: StatusFn = provider.status,
            status_by_ref_fn: StatusFn = provider.status_by_ref) -> str:
    """Move one payout as far as the provider's current answer allows. Returns its state.

    `ask_unknown=False` limits it to payouts that already have a provider ref
    (submitted and posted). The ambiguity matrix uses that for the baseline
    strategies, so every strategy shares the same handling of a known payout and
    only the timeout decision differs.
    """
    state, request_id, ref, amount, currency = ledger.query(
        "SELECT state::text, request_id, provider_ref, amount_minor, currency "
        "FROM ledger_payouts WHERE id = %s", (payout_id,))[0]
    try:
        if state == "failed":
            return state
        if state == "posted":
            answer = status_by_ref_fn(provider_target, ref, now)
            if answer.state == "failed" and answer.failure_code == "returned":
                return ledger.payout_fail(payout_id, "returned", "provider: returned")
            return state
        if state == "submitted":
            return _handle_answer(ledger, payout_id, state, status_by_ref_fn(provider_target, ref, now))
        if not ask_unknown:
            return state
        # pending or unknown: nobody knows yet whether money moved.
        answer = status_fn(provider_target, request_id, now)
        if answer.state == "not_found":
            try:
                reply = provider.pay(provider_target, request_id, amount, currency.strip(),
                                     payout_key=request_id, now=now, ttl=ttl)
            except provider.ProviderTimeout:
                return ledger.payout_mark_unknown(payout_id)
            code = "declined" if reply.status == "failed" else None
            answer = provider.Status(reply.status, reply.provider_ref, code)
        return _handle_answer(ledger, payout_id, state, answer)
    except provider.ProviderTimeout:
        return state        # no answer is not an answer; try again next sweep


def sweep(ledger: Ledger, provider_target, *, older_than_s: float = 30.0,
          returns_within_days: int = 60) -> dict[str, int]:
    """Resolve every payout that is not terminal, plus recently posted ones (for returns)."""
    rows = ledger.query(
        "SELECT id FROM ledger_payouts "
        "WHERE (state IN ('pending', 'unknown', 'submitted') "
        "       AND updated_at < now() - make_interval(secs => %s)) "
        "   OR (state = 'posted' AND updated_at > now() - make_interval(days => %s)) "
        "ORDER BY created_at", (older_than_s, returns_within_days))
    counts: dict[str, int] = {}
    for (payout_id,) in rows:
        after = resolve(ledger, provider_target, payout_id)
        counts[after] = counts.get(after, 0) + 1
    return counts


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--older-than", type=float, default=30.0,
                    help="seconds a non-terminal payout must be idle before it is touched")
    args = ap.parse_args()
    with psycopg.connect(os.environ["LEDGER_TEMPORAL_DSN"]) as conn:
        print(sweep(Ledger(conn), os.environ["PROVIDER_DSN"], older_than_s=args.older_than))


if __name__ == "__main__":
    main()
