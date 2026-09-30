"""Rush harness: K concurrent checkouts against N portions of one dish.

Two targets:

  --target strategies   the four strategies in db/rush/strategies.sql, on a
                        scratch schema (PREREGISTRATION.md, primary)
  --target rpc          the product: public.create_order on db/schema, order-now
                        and scheduled pre-orders, called as the seeded consumer
                        through SET ROLE authenticated plus JWT claims, exactly
                        as PostgREST would (PREREGISTRATION.md, secondary)

Everything this measures is local and simulated. Client-observed latency
includes Python event-loop overhead; it is not a benchmark of PostgreSQL.

Examples:

  # the pre-registered matrix, through Toxiproxy (toxi.py starts the proxy)
  python db/rush/rush.py --dsn postgresql://postgres@127.0.0.1:5437/ravon_rush \\
      --target strategies --k 100,1000 --runs 10 --latency 0,20,100 \\
      --toxiproxy http://127.0.0.1:8474 --out db/rush/results.json

  # the CI gate: exits 1 on any oversell or conservation violation
  python db/rush/rush.py --dsn ... --target strategies,rpc --k 200 --runs 3 --gate
"""

from __future__ import annotations

import argparse
import asyncio
import datetime as dt
import json
import os
import pathlib
import platform
import random
import statistics
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, field

import psycopg
from psycopg.conninfo import conninfo_to_dict, make_conninfo

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import toxi  # noqa: E402

HERE = pathlib.Path(__file__).resolve().parent
N_PORTIONS = 40
ITEM = 1

STRATEGIES = ("read_then_write", "row_lock", "conditional_decrement", "reservation_rows")
SAFE = STRATEGIES[1:]

# Seeded db/schema actors (db/schema/seed.sql).
CONSUMER_CLAIMS = json.dumps({"sub": "11111111-1111-1111-1111-111111111111"})
RESTAURANT = "aaaaaaaa-0000-0000-0000-000000000001"
ADDRESS = "dddddddd-0000-0000-0000-000000000001"
PLOV = "cccccccc-0000-0000-0000-000000000001"
LAGMAN = "cccccccc-0000-0000-0000-000000000003"   # untracked stock
CAPACITY = 25

# (name, scheduled?, max_concurrent_orders, item, the bound that must hold)
RPC_SCENARIOS = (
    ("now_stock",          False, None,     PLOV,   N_PORTIONS),
    ("now_capacity",       False, CAPACITY, LAGMAN, CAPACITY),
    ("scheduled_stock",    True,  None,     PLOV,   N_PORTIONS),
    ("scheduled_capacity", True,  CAPACITY, PLOV,   CAPACITY),
)

CONDITIONAL_DECREMENT_SQL = """
WITH d AS (
  UPDATE rush.items SET stock = stock - 1
  WHERE id = %s AND stock >= 1
  RETURNING id)
INSERT INTO rush.orders(item_id, qty) SELECT id, 1 FROM d
RETURNING id"""

RESERVATION_ROWS_SQL = """
WITH u AS (
  SELECT id FROM rush.units
  WHERE item_id = %s AND order_id IS NULL
  ORDER BY id
  LIMIT 1
  FOR UPDATE SKIP LOCKED),
o AS (
  INSERT INTO rush.orders(item_id, qty) SELECT %s, 1 FROM u
  RETURNING id),
c AS (
  UPDATE rush.units SET order_id = o.id FROM u, o
  WHERE rush.units.id = u.id
  RETURNING rush.units.id)
SELECT count(*) FROM c"""


# ---------------------------------------------------------------------------
# One checkout per strategy. Each returns "ok" or a refusal/error label.
# ---------------------------------------------------------------------------
async def read_then_write(c: psycopg.AsyncConnection) -> str:
    # The ORM shape, in a transaction, at READ COMMITTED. Five round trips.
    await c.execute("BEGIN")
    try:
        stock = (await (await c.execute("SELECT stock FROM rush.items WHERE id = %s",
                                        (ITEM,))).fetchone())[0]
        if stock < 1:
            await c.execute("ROLLBACK")
            return "sold_out"
        await c.execute("UPDATE rush.items SET stock = %s WHERE id = %s", (stock - 1, ITEM))
        await c.execute("INSERT INTO rush.orders(item_id, qty) VALUES (%s, 1)", (ITEM,))
        await c.execute("COMMIT")
        return "ok"
    except psycopg.Error as e:
        await c.execute("ROLLBACK")
        return f"error:{e.diag.sqlstate}"


async def row_lock(c: psycopg.AsyncConnection) -> str:
    ok = (await (await c.execute("SELECT rush.checkout_row_lock(%s)", (ITEM,))).fetchone())[0]
    return "ok" if ok else "sold_out"


async def conditional_decrement(c: psycopg.AsyncConnection) -> str:
    row = await (await c.execute(CONDITIONAL_DECREMENT_SQL, (ITEM,))).fetchone()
    return "ok" if row else "sold_out"


async def reservation_rows(c: psycopg.AsyncConnection) -> str:
    n = (await (await c.execute(RESERVATION_ROWS_SQL, (ITEM, ITEM))).fetchone())[0]
    return "ok" if n == 1 else "sold_out"


CHECKOUT = {
    "read_then_write": read_then_write,
    "row_lock": row_lock,
    "conditional_decrement": conditional_decrement,
    "reservation_rows": reservation_rows,
}


def rpc_checkout(item: str, scheduled_for):
    lines = json.dumps([{"menu_item_id": item, "quantity": 1}])

    async def go(c: psycopg.AsyncConnection) -> str:
        try:
            await c.execute("SELECT public.create_order(%s, %s, %s::jsonb, NULL, %s)",
                            (RESTAURANT, ADDRESS, lines, scheduled_for))
            return "ok"
        except psycopg.Error as e:
            try:
                reason = json.loads(e.diag.message_detail or "{}").get("reason")
            except ValueError:
                reason = None
            return reason or f"error:{e.diag.sqlstate}"
    return go


# ---------------------------------------------------------------------------
# The rush itself.
# ---------------------------------------------------------------------------
@dataclass
class Run:
    target: str
    strategy: str
    k: int
    latency_ms: int
    run: int
    seed: int
    bound: int
    sold: int = 0
    final_stock: int | None = None
    oversells: int = 0
    lost_updates: int = 0
    conservation_violation: int = 0
    violations: list = field(default_factory=list)
    p50_ms: float = 0.0
    p99_ms: float = 0.0
    throughput_per_s: float = 0.0
    wall_s: float = 0.0
    outcomes: dict = field(default_factory=dict)
    activated: int | None = None
    probe_rtt_ms: float | None = None


def nearest_rank(sorted_ms: list[float], p: float) -> float:
    # Nearest-rank percentile, as pre-registered.
    import math
    idx = max(0, math.ceil(p * len(sorted_ms)) - 1)
    return sorted_ms[idx]


async def open_conns(dsn: str, k: int, as_consumer: bool) -> list[psycopg.AsyncConnection]:
    async def one():
        c = await psycopg.AsyncConnection.connect(dsn, autocommit=True)
        await c.execute("SET statement_timeout = '120s'")
        if as_consumer:
            await c.execute("SELECT set_config('request.jwt.claims', %s, false)", (CONSUMER_CLAIMS,))
            await c.execute("SET ROLE authenticated")
        return c
    conns: list[psycopg.AsyncConnection] = []
    for i in range(0, k, 50):
        conns += await asyncio.gather(*[one() for _ in range(min(50, k - i))])
    return conns


async def fire(conns, checkout, seed: int) -> tuple[list[str], list[float], float]:
    order = list(range(len(conns)))
    random.Random(seed).shuffle(order)          # the only thing a seed controls
    go = asyncio.Event()
    lat: list[float] = [0.0] * len(conns)
    out: list[str] = [""] * len(conns)
    t0 = 0.0

    async def one(i: int) -> None:
        await go.wait()
        try:
            out[i] = await checkout(conns[i])
        except psycopg.Error as e:
            out[i] = f"error:{e.diag.sqlstate}"
        lat[i] = (time.perf_counter() - t0) * 1000.0

    tasks = [asyncio.create_task(one(i)) for i in order]
    await asyncio.sleep(0.2)                    # every task is parked on the event
    t0 = time.perf_counter()
    go.set()
    await asyncio.gather(*tasks)
    wall = time.perf_counter() - t0
    return out, lat, wall


def summarize(run: Run, out: list[str], lat: list[float], wall: float) -> None:
    tally: dict[str, int] = {}
    for o in out:
        tally[o] = tally.get(o, 0) + 1
    run.outcomes = dict(sorted(tally.items()))
    s = sorted(lat)
    run.p50_ms = round(nearest_rank(s, 0.50), 2)
    run.p99_ms = round(nearest_rank(s, 0.99), 2)
    run.wall_s = round(wall, 4)
    run.throughput_per_s = round(len(out) / wall, 1)


async def run_strategy(admin_dsn: str, client_dsn: str, strategy: str, k: int,
                       latency_ms: int, r: int, proxy: toxi.Proxy | None) -> Run:
    with psycopg.connect(admin_dsn, autocommit=True) as a:
        a.execute("SELECT rush.reset(%s)", (N_PORTIONS,))
    run = Run("strategies", strategy, k, latency_ms, r, r, N_PORTIONS)
    conns = await open_conns(client_dsn, k, as_consumer=False)
    if proxy:
        proxy.set_latency(latency_ms)
        proxy.verify()
    # Measured, not assumed: the median of 3 `SELECT 1` round trips on one of
    # the connections, after the toxic is set and before the release.
    rtts = []
    for _ in range(3):
        t = time.perf_counter()
        await conns[0].execute("SELECT 1")
        rtts.append((time.perf_counter() - t) * 1000.0)
    run.probe_rtt_ms = round(statistics.median(rtts), 2)
    try:
        out, lat, wall = await fire(conns, CHECKOUT[strategy], r)
    finally:
        if proxy:
            proxy.set_latency(0)
        await asyncio.gather(*[c.close() for c in conns])
    summarize(run, out, lat, wall)
    with psycopg.connect(admin_dsn, autocommit=True) as a:
        run.sold = a.execute("SELECT count(*) FROM rush.orders").fetchone()[0]
        if strategy == "reservation_rows":
            run.final_stock = a.execute(
                "SELECT count(*) FROM rush.units WHERE order_id IS NULL").fetchone()[0]
            claimed = a.execute(
                "SELECT count(*) FROM rush.units WHERE order_id IS NOT NULL").fetchone()[0]
            if claimed != run.sold:
                run.violations.append(f"{claimed} units claimed for {run.sold} orders")
        else:
            run.final_stock = a.execute("SELECT stock FROM rush.items WHERE id = %s",
                                        (ITEM,)).fetchone()[0]
    acked = run.outcomes.get("ok", 0)
    if acked != run.sold:
        run.violations.append(f"{acked} acknowledged, {run.sold} orders exist")
    run.oversells = max(0, run.sold - N_PORTIONS)
    run.lost_updates = run.sold - (N_PORTIONS - run.final_stock)
    if run.final_stock + run.sold != N_PORTIONS:
        run.violations.append(f"final stock {run.final_stock} + sold {run.sold} != {N_PORTIONS}")
    run.conservation_violation = int(bool(run.violations))
    return run


def has_ledger(a: psycopg.Connection) -> bool:
    """False on a schema from before the fix (65ad66c), which the harness also
    drives as its negative control: same rush, old create_order."""
    return a.execute("SELECT to_regclass('public.inventory_movements') IS NOT NULL").fetchone()[0]


def reset_rpc(a: psycopg.Connection, cap: int | None) -> None:
    """Empty every order table and restore the seeded menu, through the ledger."""
    ledger = has_ledger(a)
    tables = ("order_status_history", "order_items", "courier_earnings", "orders")
    if ledger:
        tables = ("inventory_movements", "kitchen_slot_holds", "kitchen_slots") + tables
    with a.transaction():
        a.execute("SET LOCAL session_replication_role = replica")   # skip triggers for cleanup only
        for t in tables:
            a.execute(f"DELETE FROM public.{t}")
    if ledger:
        # The ledger is now empty, so re-open it at each item's current balance,
        # then move plov to N through the trigger like any merchant restock.
        a.execute("INSERT INTO public.inventory_movements(menu_item_id, kind, quantity) "
                  "SELECT id, 'adjust', stock_count FROM public.menu_items "
                  "WHERE COALESCE(stock_count, 0) <> 0")
    a.execute("UPDATE public.menu_items SET stock_count = %s WHERE id = %s", (N_PORTIONS, PLOV))
    a.execute("UPDATE public.restaurants SET max_concurrent_orders = %s, restaurant_status = 'active', "
              "is_accepting_orders = true WHERE id = %s", (cap, RESTAURANT))


async def run_rpc(admin_dsn: str, client_dsn: str, scenario, k: int, r: int) -> Run:
    name, scheduled, cap, item, bound = scenario
    with psycopg.connect(admin_dsn, autocommit=True) as a:
        reset_rpc(a, cap)
        sched = a.execute("""SELECT date_bin('15 minutes', now() + interval '30 minutes',
                             timestamptz '2000-01-01 00:00+00') + interval '7 minutes'""").fetchone()[0] \
            if scheduled else None
    run = Run("rpc", name, k, 0, r, r, bound)
    conns = await open_conns(client_dsn, k, as_consumer=True)
    try:
        out, lat, wall = await fire(conns, rpc_checkout(item, sched), r)
    finally:
        await asyncio.gather(*[c.close() for c in conns])
    summarize(run, out, lat, wall)
    live_excl = ("scheduled", "rejected", "cancelled", "cancelled_by_customer",
                 "cancelled_by_restaurant", "cancelled_by_system", "cancelled_by_courier")
    with psycopg.connect(admin_dsn, autocommit=True) as a:
        if scheduled:
            a.execute("UPDATE public.orders SET scheduled_for = now() - interval '1 second' "
                      "WHERE status = 'scheduled'")
            run.activated = a.execute("SELECT public.activate_scheduled_orders()").fetchone()[0]
        run.sold = a.execute(
            "SELECT count(*) FROM public.orders WHERE status <> ALL(%s::public.order_status[])",
            (list(live_excl),)).fetchone()[0]
        run.final_stock = a.execute("SELECT stock_count FROM public.menu_items WHERE id = %s",
                                    (item,)).fetchone()[0]
        if has_ledger(a):
            run.violations = [f"{n}: {d}" for n, d in
                              a.execute("SELECT * FROM public.ravon_inventory_violations()").fetchall()]
        live_units = a.execute("""
            SELECT coalesce(sum(oi.quantity), 0) FROM public.order_items oi
            JOIN public.orders o ON o.id = oi.order_id
            WHERE oi.menu_item_id = %s AND o.status <> ALL(%s::public.order_status[])""",
                               (item, list(live_excl))).fetchone()[0]
    if run.outcomes.get("ok", 0) != run.sold:
        run.violations.append(f"{run.outcomes.get('ok', 0)} acknowledged, {run.sold} live")
    run.oversells = max(0, run.sold - bound)
    if run.final_stock is not None:
        run.lost_updates = live_units - (N_PORTIONS - run.final_stock)
        if run.final_stock + live_units != N_PORTIONS:
            run.violations.append(f"stock {run.final_stock} + live {live_units} != {N_PORTIONS}")
    run.conservation_violation = int(bool(run.violations))
    return run


# ---------------------------------------------------------------------------
# Aggregation and reporting.
# ---------------------------------------------------------------------------
def cells(runs: list[Run]) -> list[dict]:
    groups: dict[tuple, list[Run]] = {}
    for r in runs:
        groups.setdefault((r.target, r.strategy, r.k, r.latency_ms), []).append(r)
    out = []
    for (target, strategy, k, lat), rs in groups.items():
        out.append({
            "target": target, "strategy": strategy, "k": k, "latency_ms": lat,
            "runs": len(rs), "bound": rs[0].bound,
            "oversells": sum(r.oversells for r in rs),
            "max_oversell": max(r.oversells for r in rs),
            "runs_that_oversold": sum(1 for r in rs if r.oversells),
            "lost_updates": sum(r.lost_updates for r in rs),
            "conservation_violations": sum(r.conservation_violation for r in rs),
            "sold_min": min(r.sold for r in rs), "sold_max": max(r.sold for r in rs),
            "p50_ms_median": round(statistics.median(r.p50_ms for r in rs), 2),
            "p99_ms_median": round(statistics.median(r.p99_ms for r in rs), 2),
            "throughput_median": round(statistics.median(r.throughput_per_s for r in rs), 1),
            "probe_rtt_ms_median": (round(statistics.median(r.probe_rtt_ms for r in rs), 2)
                                    if all(r.probe_rtt_ms is not None for r in rs) else None),
        })
    return out


def markdown(cs: list[dict]) -> str:
    lines = ["| target | strategy | K | added latency | runs | sold (min to max) | oversells (sum) | "
             "max oversell in a run | lost updates (sum) | conservation violations | "
             "p50 ms | p99 ms | checkouts/s |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for c in cs:
        lines.append(
            f"| {c['target']} | `{c['strategy']}` | {c['k']:,} | {c['latency_ms']} ms | {c['runs']} | "
            f"{c['sold_min']} to {c['sold_max']} | {c['oversells']:,} | {c['max_oversell']:,} | "
            f"{c['lost_updates']:,} | {c['conservation_violations']} | {c['p50_ms_median']:,} | "
            f"{c['p99_ms_median']:,} | {c['throughput_median']:,} |")
    return "\n".join(lines)


def environment(argv: list[str], admin_dsn: str) -> dict:
    def sh(*cmd):
        try:
            return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout.strip()
        except Exception:
            return None
    with psycopg.connect(admin_dsn, autocommit=True) as a:
        pg = a.execute("SELECT version()").fetchone()[0]
        max_conn = a.execute("SHOW max_connections").fetchone()[0]
    return {
        "command": "python " + " ".join(argv),
        "sha": sh("git", "-C", str(HERE), "rev-parse", "HEAD"),
        "dirty": bool(sh("git", "-C", str(HERE), "status", "--porcelain", "--", str(HERE.parent))),
        "date_utc": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "machine": (sh("sysctl", "-n", "machdep.cpu.brand_string") or platform.processor()),
        "cpus": os.cpu_count(),
        "memory_bytes": sh("sysctl", "-n", "hw.memsize"),
        "os": platform.platform(),
        "postgres": pg, "max_connections": max_conn,
        "python": platform.python_version(), "psycopg": psycopg.__version__,
        "labels": ["local", "simulated"],
    }


def gate(runs: list[Run]) -> list[str]:
    """The CI gate, as pre-registered."""
    failures = []
    for r in runs:
        if r.target == "rpc" or r.strategy in SAFE:
            if r.oversells or r.conservation_violation:
                failures.append(f"{r.target}/{r.strategy} K={r.k} run {r.run}: "
                                f"oversells={r.oversells} violations={r.violations}")
    naive = [r for r in runs if r.strategy == "read_then_write"]
    if not naive:
        failures.append("read_then_write was not run: the gate needs its negative control")
    elif not any(r.oversells for r in naive):
        failures.append("read_then_write oversold 0 times in every run: the harness's own "
                        "negative control did not fire, so a 0 elsewhere proves nothing")
    return failures


async def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dsn", required=True, help="admin DSN of a database with db/schema applied and seeded")
    ap.add_argument("--target", default="strategies", help="strategies, rpc, or both comma-separated")
    ap.add_argument("--strategies", default=",".join(STRATEGIES))
    ap.add_argument("--k", default="100,1000")
    ap.add_argument("--runs", type=int, default=10)
    ap.add_argument("--latency", default="0", help="added ms, comma-separated; >0 needs --toxiproxy")
    ap.add_argument("--toxiproxy", help="Toxiproxy API URL, e.g. http://127.0.0.1:8474")
    ap.add_argument("--proxy-listen", default="127.0.0.1:25437")
    ap.add_argument("--out", help="write every run and cell to this JSON file")
    ap.add_argument("--gate", action="store_true", help="exit 1 on any oversell or conservation violation")
    args = ap.parse_args()

    targets = args.target.split(",")
    ks = [int(x) for x in args.k.split(",")]
    lats = [int(x) for x in args.latency.split(",")]
    if any(lats) and not args.toxiproxy:
        ap.error("added latency needs --toxiproxy")

    admin_dsn = args.dsn
    client_dsn = admin_dsn
    proxy = None
    if args.toxiproxy:
        params = conninfo_to_dict(admin_dsn)
        host, port = args.proxy_listen.rsplit(":", 1)
        proxy = toxi.Proxy(args.toxiproxy, "rush_pg", args.proxy_listen,
                           f"{params.get('host', '127.0.0.1')}:{params.get('port', 5432)}")
        proxy.create()
        params.update(host=host, port=port)
        client_dsn = make_conninfo(**params)

    with psycopg.connect(admin_dsn, autocommit=True) as a:
        a.execute((HERE / "strategies.sql").read_text())

    runs: list[Run] = []
    if "strategies" in targets:
        for k in ks:
            for lat in lats:
                for s in args.strategies.split(","):
                    for r in range(args.runs):
                        run = await run_strategy(admin_dsn, client_dsn, s, k, lat, r, proxy)
                        runs.append(run)
                        print(f"{s:22s} K={k:<5d} +{lat:>3d}ms run {r}: sold={run.sold:<5d} "
                              f"oversell={run.oversells:<4d} lost={run.lost_updates:<4d} "
                              f"cons={run.conservation_violation} p50={run.p50_ms:.1f} "
                              f"p99={run.p99_ms:.1f} {run.throughput_per_s:.0f}/s rtt={run.probe_rtt_ms} "
                              f"{run.outcomes}",
                              flush=True)
    if "rpc" in targets:
        for k in ks:
            for sc in RPC_SCENARIOS:
                for r in range(args.runs):
                    run = await run_rpc(admin_dsn, admin_dsn, sc, k, r)
                    runs.append(run)
                    print(f"rpc/{sc[0]:18s} K={k:<5d} run {r}: live={run.sold:<5d} bound={run.bound} "
                          f"oversell={run.oversells} cons={run.conservation_violation} "
                          f"p50={run.p50_ms:.1f} p99={run.p99_ms:.1f} {run.outcomes} "
                          f"{run.violations[:2]}", flush=True)
    if proxy:
        proxy.delete()

    cs = cells(runs)
    print()
    print(markdown(cs))
    if args.out:
        doc = {"environment": environment(sys.argv, admin_dsn), "cells": cs,
               "runs": [asdict(r) for r in runs]}
        pathlib.Path(args.out).write_text(json.dumps(doc, indent=1, default=str) + "\n")
    if args.gate:
        failures = gate(runs)
        for f in failures:
            print(f"GATE FAIL: {f}")
        if failures:
            return 1
        print(f"GATE OK: {len(runs)} runs, 0 oversells and 0 conservation violations in every "
              "correct strategy and in create_order; read_then_write oversold, so the detector works")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
