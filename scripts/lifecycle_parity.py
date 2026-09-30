#!/usr/bin/env python3
"""Assert the order lifecycle is declared once, not twice.

`Sources/RavonCore/Models/OrderLifecycle.swift` declares the legal transitions as
Swift data. `db/schema/03_lifecycle.sql` seeds the same edges into
`public.order_transitions`, and a BEFORE UPDATE trigger on `orders` refuses any
status change with no matching row — so the SQL copy is load-bearing, not
documentation.

Two copies of a state machine drift. That is not hypothetical here: it is the
documented origin of the bug ADR 0001 was written about, where the merchant UI hid
an order at `.assigned` — exactly when the courier was standing at the counter asking
for the pickup code — because "what can happen next" had been re-derived by hand in
every screen and again in the SQL guards of migration 13.

This compares the two files directly and exits 1 on any difference, including the
guard set, because two edges share endpoints and differ only by guard
(`courier_arrived_customer -> delivered` is reachable by delivery code OR by proof
photo). No database required, so it runs in the same cheap CI job as the drift check.
"""
from __future__ import annotations

import pathlib
import re
import sys

SWIFT = pathlib.Path("Sources/RavonCore/Models/OrderLifecycle.swift")
SQL = pathlib.Path("db/schema/03_lifecycle.sql")

# Swift enum case name -> Postgres enum label. Only the multi-word ones differ.
STATUS = {
    "scheduled": "scheduled", "created": "created", "accepted": "accepted",
    "preparing": "preparing", "ready": "ready", "assigned": "assigned",
    "courierArrivedRestaurant": "courier_arrived_restaurant",
    "pickedUp": "picked_up", "delivering": "delivering",
    "courierArrivedCustomer": "courier_arrived_customer",
    "delivered": "delivered", "cancelled": "cancelled", "rejected": "rejected",
    "cancelledByCustomer": "cancelled_by_customer",
    "cancelledByRestaurant": "cancelled_by_restaurant",
    "cancelledBySystem": "cancelled_by_system",
    "cancelledByCourier": "cancelled_by_courier",
}

Edge = tuple[str, str, str, str, tuple[str, ...]]


def swift_edges() -> set[Edge]:
    text = SWIFT.read_text(encoding="utf-8")
    body = text.split("public static let transitions: [OrderTransition] = [", 1)[1]
    body = body.split("\n    ]", 1)[0]
    body = re.sub(r"//[^\n]*", "", body)          # strip comments
    edges: set[Edge] = set()
    for chunk in body.split(".init(")[1:]:
        frm = re.search(r"from:\s*\.(\w+)", chunk)
        to = re.search(r"to:\s*\.(\w+)", chunk)
        actor = re.search(r"actor:\s*\.(\w+)", chunk)
        rpc = re.search(r'rpc:\s*"([^"]+)"', chunk)
        if not (frm and to and actor and rpc):
            print(f"error: unparseable .init(...) in {SWIFT}", file=sys.stderr)
            raise SystemExit(2)
        guards = re.search(r"guards:\s*\[([^\]]*)\]", chunk)
        gs = tuple(sorted(
            g.strip().lstrip(".") for g in guards.group(1).split(",") if g.strip()
        )) if guards else ()
        edges.add((STATUS[frm.group(1)], STATUS[to.group(1)], actor.group(1), rpc.group(1), gs))
    return edges


def sql_edges() -> set[Edge]:
    text = SQL.read_text(encoding="utf-8")
    # Strip comments BEFORE splitting on the statement terminator. One of the
    # explanatory comments inside the VALUES list contains a semicolon
    # ("...return the order to the pool; everything else terminates it"), and
    # splitting first truncated the statement there — 6 edges parsed instead of
    # 36, reported as 30 spurious mismatches. Same ordering trap as the SQL
    # comment stripper in schema_drift.py.
    text = re.sub(r"--[^\n]*", "", text)
    body = text.split("INSERT INTO public.order_transitions", 1)[1]
    body = body.split(";", 1)[0]
    edges: set[Edge] = set()
    for frm, to, actor, rpc, guards in re.findall(
        r"\(\s*'([a-z_]+)'\s*,\s*'([a-z_]+)'\s*,\s*'([a-z]+)'\s*,\s*'([a-z_]+)'\s*,\s*'\{([^}]*)\}'\s*\)",
        body,
    ):
        gs = tuple(sorted(g.strip() for g in guards.split(",") if g.strip()))
        edges.add((frm, to, actor, rpc, gs))
    return edges


def main() -> int:
    for path in (SWIFT, SQL):
        if not path.is_file():
            print(f"error: {path} not found", file=sys.stderr)
            return 2

    sw, sq = swift_edges(), sql_edges()
    print(f"lifecycle parity: {len(sw)} edges in Swift, {len(sq)} edges in SQL")

    only_swift = sorted(sw - sq)
    only_sql = sorted(sq - sw)

    for edge in only_swift:
        print(f"  MISSING IN SQL   {edge[0]} -> {edge[1]}  by {edge[2]} via {edge[3]} {list(edge[4])}")
    for edge in only_sql:
        print(f"  MISSING IN SWIFT {edge[0]} -> {edge[1]}  by {edge[2]} via {edge[3]} {list(edge[4])}")

    if only_swift or only_sql:
        print(
            f"\n{len(only_swift) + len(only_sql)} edge(s) differ. The lifecycle is "
            f"declared in two places and they disagree — which is the exact failure "
            f"ADR 0001 exists to prevent. Update whichever copy is wrong; do not "
            f"delete this check.",
            file=sys.stderr,
        )
        return 1

    print("lifecycle parity OK — the Swift table and the SQL table are the same graph")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
