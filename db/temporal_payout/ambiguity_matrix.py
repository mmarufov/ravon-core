"""Four ways to handle a lost provider reply, under six fault modes. Simulated.

    cd db/temporal_payout
    LEDGER_DSN=... python ambiguity_matrix.py --seeds 200 [--check] [--out results.md]

The design is fixed in PREREGISTRATION-ambiguity.md, committed before this file
first ran. In short: one payout per run, a logical clock in integer ticks, the
real db/ledger/schema.sql on the ledger side, and the fake provider in
provider.py on the other. Per (mode, seed) every strategy sees the same random
draws, so the comparison is paired.

Each run ends with two views of the same payout: the ledger's state at the
horizon, and the provider's eventual state (every scheduled transition applied).
They are then classified as double, orphaned, phantom, stuck or correct.

Nothing here touches a real provider or real money.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import random
import sys
import time
from dataclasses import dataclass, field
from uuid import UUID, uuid4

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "ledger" / "tests"))

import psycopg  # noqa: E402
from psycopg import sql  # noqa: E402
from psycopg.conninfo import conninfo_to_dict, make_conninfo  # noqa: E402

import provider  # noqa: E402
import resolver  # noqa: E402
from chart import CURRENCY, courier_payable_for, open_chart  # noqa: E402
from ledger_api import Ledger, credit, debit, fingerprint_of  # noqa: E402

STRATEGIES = ("fresh_key", "same_key", "fail_on_timeout", "status_first")
FAULT_MODES = ("commit_then_timeout", "timeout_before_commit", "async_pending_then_paid",
               "async_pending_then_failed", "returned_after_delay", "key_expiry")
CONTROL = "none"
TTL = 10                    # ticks the provider keeps an idempotency key
HORIZON = 40                # ticks each run is driven for
STATUS_TIMEOUT_P = 0.2      # every status call, from every strategy
FUNDING = 100_000

LEDGER_DB = "ravon_ambiguity_ledger"
PROVIDER_DB = "ravon_ambiguity_provider"
SCHEMA_PATH = HERE.parent / "ledger" / "schema.sql"


@dataclass(frozen=True)
class Draws:
    amount: int
    retry_delay: int
    resolve_after: int
    return_after: int


def draws(mode: str, seed: int) -> Draws:
    """Drawn in a fixed order from one generator per (mode, seed), for every strategy."""
    rng = random.Random(f"{mode}:{seed}")
    amount = rng.randint(100, 50_000)
    retry_delay = rng.randint(TTL + 1, TTL + 10) if mode == "key_expiry" else rng.randint(1, 5)
    resolve_after = rng.randint(2, 60)
    return_after = rng.randint(3, 20)
    return Draws(amount, retry_delay, resolve_after, return_after)


@dataclass
class Outcome:
    ledger_state: str
    provider_paid: int          # provider objects for this payout that end paid
    provider_pending: int       # ...that are still pending with nothing scheduled
    status_calls: int
    double: bool = field(init=False)
    orphaned: bool = field(init=False)
    phantom: bool = field(init=False)
    stuck: bool = field(init=False)

    def __post_init__(self) -> None:
        self.double = self.provider_paid >= 2
        self.orphaned = self.provider_paid >= 1 and self.ledger_state == "failed"
        self.phantom = self.ledger_state == "posted" and self.provider_paid == 0
        self.stuck = self.ledger_state in ("pending", "unknown", "submitted")

    @property
    def wrong_money(self) -> bool:
        return self.double or self.orphaned or self.phantom


class Harness:
    """The two databases and the chart of accounts, shared by every run."""

    def __init__(self, admin_dsn: str) -> None:
        def dsn_for(db: str) -> str:
            return make_conninfo(**{**conninfo_to_dict(admin_dsn), "dbname": db})
        with psycopg.connect(admin_dsn, autocommit=True) as c:
            for db in (LEDGER_DB, PROVIDER_DB):
                c.execute(sql.SQL("DROP DATABASE IF EXISTS {} WITH (FORCE)").format(sql.Identifier(db)))
                c.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(db)))
        with psycopg.connect(dsn_for(LEDGER_DB), autocommit=True) as c:
            c.execute(SCHEMA_PATH.read_text())
        with psycopg.connect(dsn_for(PROVIDER_DB), autocommit=True) as c:
            c.execute(provider.SCHEMA)
        self.ledger = Ledger(psycopg.connect(dsn_for(LEDGER_DB)))
        self.provider = psycopg.connect(dsn_for(PROVIDER_DB))
        self.chart = open_chart(self.ledger)
        self.tag = uuid4().hex[:8]

    def fund_courier(self) -> UUID:
        payable = courier_payable_for(self.ledger, uuid4())
        entries = [debit(self.chart.revenue, FUNDING, CURRENCY), credit(payable, FUNDING, CURRENCY)]
        self.ledger.post(f"fund:{uuid4()}", fingerprint_of(entries), "settlement", uuid4(), entries)
        return payable

    def close(self) -> None:
        self.ledger.conn.close()
        self.provider.close()


def run_one(h: Harness, strategy: str, mode: str, seed: int) -> Outcome:
    d = draws(mode, seed)
    status_rng = random.Random(f"{mode}:{seed}:status")
    calls = 0

    def flaky(fn):
        def call(target, key, now):
            nonlocal calls
            calls += 1
            if status_rng.random() < STATUS_TIMEOUT_P:
                raise provider.ProviderTimeout(key)
            return fn(target, key, now)
        return call

    status_fn, status_by_ref_fn = flaky(provider.status), flaky(provider.status_by_ref)
    request_id = f"m:{h.tag}:{strategy}:{mode}:{seed}"
    if mode != CONTROL:
        provider.arm(h.provider, request_id, mode,
                     resolve_after=d.resolve_after, return_after=d.return_after)
    ledger = h.ledger
    payout_id = ledger.payout_begin(request_id, h.fund_courier(), h.chart.clearing,
                                    d.amount, CURRENCY)

    def take(reply: provider.Reply) -> None:
        code = "declined" if reply.status == "failed" else None
        resolver._handle_answer(ledger, payout_id, ledger.payout_state(payout_id),
                                provider.Status(reply.status, reply.provider_ref, code))

    retry_at, retry_id = None, request_id
    try:
        take(provider.pay(h.provider, request_id, d.amount, CURRENCY,
                          payout_key=request_id, now=0, ttl=TTL))
    except provider.ProviderTimeout:
        if strategy == "fresh_key":
            retry_at, retry_id = d.retry_delay, f"{request_id}:2"
        elif strategy == "same_key":
            retry_at = d.retry_delay
        elif strategy == "fail_on_timeout":
            # Today's hand-built resume(NULL): "no ref means the provider never
            # got it". The schema now demands a verdict, so the guess has to be
            # written down.
            ledger.payout_fail(payout_id, "not_found", "assumed from a timeout")
        else:
            ledger.payout_mark_unknown(payout_id)

    for t in range(HORIZON):
        if retry_at == t:
            take(provider.pay(h.provider, retry_id, d.amount, CURRENCY,
                              payout_key=request_id, now=t, ttl=TTL))
        resolver.resolve(ledger, h.provider, payout_id, now=t,
                         ask_unknown=(strategy == "status_first"), ttl=TTL,
                         status_fn=status_fn, status_by_ref_fn=status_by_ref_fn)

    paid, pending = provider.eventual_paid(h.provider, request_id)
    return Outcome(ledger.payout_state(payout_id), paid, pending, calls)


METRICS = ("double", "orphaned", "phantom", "stuck", "wrong_money")


def run_matrix(admin_dsn: str, seeds: int) -> dict:
    h = Harness(admin_dsn)
    started = time.perf_counter()
    cells: dict[str, dict[str, dict[str, int]]] = {}
    try:
        for mode in (CONTROL, *FAULT_MODES):
            for strategy in STRATEGIES:
                cell = {m: 0 for m in METRICS} | {"runs": 0, "status_calls": 0}
                for seed in range(seeds):
                    o = run_one(h, strategy, mode, seed)
                    cell["runs"] += 1
                    cell["status_calls"] += o.status_calls
                    for m in METRICS:
                        cell[m] += int(getattr(o, m))
                cells.setdefault(mode, {})[strategy] = cell
        mismatches = h.ledger.verify_balances()
    finally:
        h.close()
    return {"seeds": seeds, "ttl": TTL, "horizon": HORIZON, "status_timeout_p": STATUS_TIMEOUT_P,
            "elapsed_s": round(time.perf_counter() - started, 1),
            "ledger_verify_balances_mismatches": len(mismatches), "cells": cells}


def headline(result: dict) -> dict[str, dict[str, int]]:
    out = {}
    for s in STRATEGIES:
        out[s] = {m: sum(result["cells"][mode][s][m] for mode in FAULT_MODES) for m in METRICS}
        out[s]["runs"] = sum(result["cells"][mode][s]["runs"] for mode in FAULT_MODES)
    return out


def render(result: dict) -> str:
    n = result["seeds"]
    lines = [f"Simulated. {n} seeds per cell, TTL {TTL} ticks, horizon {HORIZON} ticks, "
             f"status calls time out with p={STATUS_TIMEOUT_P}.", "",
             "Each cell: double / orphaned / phantom / stuck, out of "
             f"{n} runs. **wrong** = double or orphaned or phantom.", "",
             "| fault mode | " + " | ".join(f"`{s}`" for s in STRATEGIES) + " |",
             "|---|" + "---|" * len(STRATEGIES)]
    for mode in (CONTROL, *FAULT_MODES):
        row = []
        for s in STRATEGIES:
            c = result["cells"][mode][s]
            row.append(f"{c['double']} / {c['orphaned']} / {c['phantom']} / {c['stuck']}"
                       f" (**wrong {c['wrong_money']}**)")
        label = f"`{mode}`" + (" (control)" if mode == CONTROL else "")
        lines.append(f"| {label} | " + " | ".join(row) + " |")
    hl = headline(result)
    lines += ["", f"Summed over the 6 fault modes ({hl[STRATEGIES[0]]['runs']} runs per strategy):", "",
              "| strategy | double | orphaned | phantom | wrong (any) | stuck |", "|---|---|---|---|---|---|"]
    for s in STRATEGIES:
        x = hl[s]
        lines.append(f"| `{s}` | {x['double']} | {x['orphaned']} | {x['phantom']} | "
                     f"**{x['wrong_money']}** | {x['stuck']} |")
    lines += ["", f"`ledger_verify_balances()` after all runs: "
              f"{result['ledger_verify_balances_mismatches']} mismatches. "
              f"Elapsed {result['elapsed_s']} s."]
    return "\n".join(lines)


def check(result: dict) -> list[str]:
    """The pre-registered CI gate."""
    problems = []
    for mode in FAULT_MODES:
        c = result["cells"][mode]["status_first"]
        if c["wrong_money"]:
            problems.append(f"status_first has {c['wrong_money']} wrong-money runs under {mode}")
    for s in STRATEGIES:
        c = result["cells"][CONTROL][s]
        if any(c[m] for m in METRICS):
            problems.append(f"{s} is not clean under the control: {c}")
    if result["cells"]["commit_then_timeout"]["fresh_key"]["double"] == 0:
        problems.append("negative control: fresh_key produced no double under commit_then_timeout")
    if result["ledger_verify_balances_mismatches"]:
        problems.append("ledger_verify_balances() is not empty")
    return problems


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", type=int, default=200)
    ap.add_argument("--check", action="store_true", help="fail on the pre-registered gate")
    ap.add_argument("--out", help="write the table here (markdown)")
    ap.add_argument("--json", help="write the raw counts here")
    args = ap.parse_args()
    admin = os.environ.get("LEDGER_DSN", "postgresql://postgres:ledger@127.0.0.1:5433/postgres")
    result = run_matrix(admin, args.seeds)
    text = render(result)
    print(text)
    if args.out:
        pathlib.Path(args.out).write_text(text + "\n")
    if args.json:
        pathlib.Path(args.json).write_text(json.dumps(result, indent=2) + "\n")
    if args.check:
        problems = check(result)
        for p in problems:
            print(f"CHECK FAILED: {p}")
        sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
