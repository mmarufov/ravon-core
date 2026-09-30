"""Crash injection for the worker. Test instrumentation, not part of the saga.

Inert unless PAYOUT_FAULT_DIR is set. A test arms a fault by writing
    $PAYOUT_FAULT_DIR/plans/<request_id>.json   {"at": "<step>:<point>", "action": "..."}
and the fault fires at most once, across every worker process, because firing
is claimed with O_CREAT|O_EXCL on $PAYOUT_FAULT_DIR/fired/<request_id>.

Points, per step:
    enter          the activity has been handed to this worker, nothing done yet
    before_commit  the step's SQL has executed, its transaction is still open
    committed      the step's effect is durable, Temporal has not been told

Actions:
    sigkill   the worker process dies on the spot
    sigstop   the worker process freezes; a test SIGCONTs it later (a zombie)
    pg_kill   the step's PostgreSQL backend is terminated from a second
              connection, exactly as the hand-built crash_now() does

Every activity attempt also appends one line to evidence.jsonl, so a test can
say which attempt did what and in which process.
"""

from __future__ import annotations

import dataclasses
import functools
import json
import os
import signal
import threading
from typing import Any, Callable

import psycopg

from ledger_api import Ledger

_DIR = os.environ.get("PAYOUT_FAULT_DIR")
_current = threading.local()


def _plan(request_id: str) -> dict | None:
    path = os.path.join(_DIR, "plans", f"{request_id}.json")
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return json.load(f)


def _claim(request_id: str) -> bool:
    try:
        fd = os.open(os.path.join(_DIR, "fired", request_id), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        return False
    os.write(fd, str(os.getpid()).encode())
    os.close(fd)
    return True


def record(**fields: Any) -> None:
    if not _DIR:
        return
    if dataclasses.is_dataclass(fields.get("result")):
        fields["result"] = dataclasses.asdict(fields["result"])
    line = json.dumps({"pid": os.getpid(), **fields}, default=str)
    with open(os.path.join(_DIR, "evidence.jsonl"), "a") as f:
        f.write(line + "\n")


def checkpoint(point: str, conn: psycopg.Connection | None = None) -> None:
    if not _DIR:
        return
    step, request_id = _current.step, _current.request_id
    plan = _plan(request_id)
    if not plan or plan["at"] != f"{step}:{point}" or not _claim(request_id):
        return
    record(request_id=request_id, step=step, event=f"fault:{plan['action']}@{point}")
    if plan["action"] == "sigkill":
        os.kill(os.getpid(), signal.SIGKILL)
    elif plan["action"] == "sigstop":
        os.kill(os.getpid(), signal.SIGSTOP)
    elif plan["action"] == "pg_kill":
        from test_crash_atomicity import backend_pid, kill    # the hand-built suite's own helpers
        with psycopg.connect(os.environ["LEDGER_TEMPORAL_DSN"], autocommit=True) as admin:
            kill(admin, backend_pid(conn))
    else:
        raise ValueError(plan["action"])


class FaultableLedger(Ledger):
    """The same Ledger, with a hook between executing a step's SQL and COMMIT."""

    def _commit(self) -> None:
        checkpoint("before_commit", self.conn)
        super()._commit()


def ledger_class() -> type[Ledger]:
    return FaultableLedger if _DIR else Ledger


def injectable(step: str) -> Callable:
    """Wrap an activity so it passes through `enter` and `committed`."""
    def wrap(fn: Callable) -> Callable:
        @functools.wraps(fn)
        def run(call: Any) -> Any:
            if not _DIR:
                return fn(call)
            from temporalio import activity
            attempt = activity.info().attempt
            _current.step, _current.request_id = step, call.request_id
            record(request_id=call.request_id, step=step, attempt=attempt, event="enter")
            checkpoint("enter")
            try:
                result = fn(call)
            except BaseException as exc:
                record(request_id=call.request_id, step=step, attempt=attempt,
                       event="raised", error=f"{type(exc).__name__}: {exc}"[:200])
                raise
            record(request_id=call.request_id, step=step, attempt=attempt,
                   event="returned", result=result)
            checkpoint("committed")
            return result
        return run
    return wrap
