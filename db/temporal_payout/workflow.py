"""The payout saga as a Temporal workflow.

    create pending -> call the provider -> mark submitted -> post entries

This file is the whole of what Temporal replaces: the order of the steps, and
the memory of how far the saga got. There is no resume function. After a crash
a new worker replays this code against the recorded event history, every
completed step returns its recorded result instead of running again, and
execution continues at the first step that has no result yet.
"""

from __future__ import annotations

from datetime import timedelta

from temporalio import workflow
from temporalio.common import RetryPolicy

with workflow.unsafe.imports_passed_through():
    import activities
    from shared import (ACTIVITY_TIMEOUT, PENDING_POLL, FailCall, MarkCall, PayoutOutcome,
                        PayoutRequest, PostCall, ProviderCall, StatusCall)

# Unlimited attempts: a payout is not allowed to give up on a transient fault.
# Business rejections are raised non-retryable by the activities instead.
RETRY = RetryPolicy(initial_interval=timedelta(milliseconds=200), backoff_coefficient=2.0,
                    maximum_interval=timedelta(seconds=2), maximum_attempts=0)


@workflow.defn
class PayoutWorkflow:
    @workflow.run
    async def run(self, req: PayoutRequest) -> PayoutOutcome:
        payout_id = await self._step(activities.begin_payout, req)

        answer = await self._step(
            activities.submit_to_provider,
            ProviderCall(req.request_id, req.amount_minor, req.currency, payout_id))
        # Accepted but not settled: keep asking. This is the liveness Temporal
        # buys; the hand-built saga needs resolver.py to do the same.
        while answer.status == "pending":
            await workflow.sleep(PENDING_POLL)
            answer = await self._step(activities.provider_status, StatusCall(req.request_id))
        if answer.status != "paid":
            # failed carries the provider's code; not_found is its own verdict.
            verdict = answer.failure_code if answer.status == "failed" else "not_found"
            await self._step(activities.fail_payout, FailCall(
                req.request_id, payout_id, verdict, f"provider: {answer.status}"))
            return PayoutOutcome(payout_id, "failed", None)

        ref = answer.provider_ref
        await self._step(activities.mark_submitted, MarkCall(req.request_id, payout_id, ref))
        posted = await self._step(activities.post_payout, PostCall(req.request_id, payout_id))
        return PayoutOutcome(payout_id, "posted", posted.transaction_id)

    @staticmethod
    async def _step(fn, arg):
        return await workflow.execute_activity(
            fn, arg, start_to_close_timeout=ACTIVITY_TIMEOUT, retry_policy=RETRY)
