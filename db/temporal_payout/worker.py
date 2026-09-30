"""The worker process: polls the task queue, runs the workflow and its activities.

    TEMPORAL_ADDRESS=127.0.0.1:7239 LEDGER_TEMPORAL_DSN=... PROVIDER_DSN=... \
        python worker.py

This is a long-running process the hand-built saga does not have. Something has
to keep it alive and restart it when it dies; in the tests that is the harness.
"""

from __future__ import annotations

import asyncio
import os
from concurrent.futures import ThreadPoolExecutor

from temporalio.client import Client
from temporalio.worker import PollerBehaviorSimpleMaximum, Worker

import activities
from shared import TASK_QUEUE
from workflow import PayoutWorkflow


async def main() -> None:
    client = await Client.connect(os.environ.get("TEMPORAL_ADDRESS", "127.0.0.1:7233"))
    with ThreadPoolExecutor(max_workers=4) as pool:
        worker = Worker(
            client,
            task_queue=TASK_QUEUE,
            workflows=[PayoutWorkflow],
            activities=activities.ALL,
            activity_executor=pool,
            # No sticky cache: a SIGKILLed worker would otherwise strand the
            # next workflow task on its private sticky queue until that
            # queue's schedule-to-start timeout (5s by default) expired. With
            # the cache off, every workflow task is a full replay of history.
            max_cached_workflows=0,
            # One outstanding long-poll each. A SIGSTOPped worker keeps its
            # polls open, and the server will happily hand tasks to them.
            workflow_task_poller_behavior=PollerBehaviorSimpleMaximum(1),
            activity_task_poller_behavior=PollerBehaviorSimpleMaximum(1),
        )
        print(f"worker ready pid={os.getpid()} queue={TASK_QUEUE}", flush=True)
        await worker.run()


if __name__ == "__main__":
    asyncio.run(main())
