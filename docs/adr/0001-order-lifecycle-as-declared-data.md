# 0001 — Model the order lifecycle as declared data, not scattered status checks

**Status:** Accepted · 2026-09-16
**Scope:** `Sources/RavonCore/Models/OrderLifecycle.swift`, `Tests/RavonCoreTests/OrderLifecycleInvariantTests.swift`

## Context

An order in a three-sided marketplace has 17 states and four actors that can move it:
consumer, merchant, courier, and the system itself (cron jobs, escalation ladders,
no-show detection). Before this change, the question "can this actor do this right now?"
was answered independently in at least four places: a SQL `SECURITY DEFINER` function
guarding the RPC, a SwiftUI `if` deciding whether to show a button, a service-layer
precondition, and a merchant-app list filter.

Four copies of one rule is four chances to disagree. The failure mode is not a crash —
it is a button the consumer app renders that the database then rejects, or worse, one it
hides for an action the database would have allowed. Neither shows up in a unit test of
either half.

The deeper problem is that the rule was never written down anywhere. There was no
artifact you could point at and ask "is this graph even correct?"

## Decision

Declare the lifecycle once, as data:

```swift
public static let transitions: [OrderTransition] = [ … ]   // 36 edges
```

Each edge carries its `from`, `to`, the `actor` permitted to take it, the named RPC that
performs it, the `guard`s that must hold (9 of them), and the `obligation`s it creates
(5 — proof photo, verification code, and so on). Everything else is derived:
`canTransition(from:to:by:)`, UI visibility, and the set of actions an actor may take.

Because it is data, it can be *tested as a graph* rather than as a collection of cases.
17 property-based invariants run over the whole structure, including:

- every non-terminal status has an exit, and every terminal status is absorbing;
- every status is reachable from an entry point, and every status can reach a terminal
  state;
- anything that creates an obligation is visible to the actor who owes it;
- the consumer- and courier-cancel predicates used by the UI agree with the table;
- a Tarjan strongly-connected-components pass (`OrderLifecycle.stronglyConnectedComponents()`)
  over the graph.

The SCC pass found the fact worth knowing: **the graph is cyclic**, and there is exactly
one cycle — a courier cancellation genuinely returns the order to the dispatch pool.
Termination is therefore *not* guaranteed by acyclicity. It is guaranteed by a
server-side rate limit on requeues, which `test_everyCycleIsBoundedByAGuard` now pins.
Had the graph been checked for acyclicity in the naive way, the check would have failed
and the natural response would have been to "fix" the graph by deleting a real edge.

The suite also caught a modelling error in its own author's first version of the table.
That is the argument for the whole approach in one sentence.

## Alternatives considered

**Leave the checks where they are and add tests.** Tests of four independent copies
verify that each copy does what it does; they cannot verify the copies agree. And there
is still no artifact to review.

**Put the state machine only in SQL, as the RPCs already did.** SQL functions are a
second codebase with no type relationship to the Swift clients, no unit test harness, and
no way to assert a property over the whole graph. The clients would still need their own
copy to decide what to render. This is also part of why the order RPCs are the last thing
to be extracted ([ADR 0005](0005-extract-to-kotlin-not-rewrite.md)).

**A third-party state-machine library.** They give you transition enforcement at runtime.
The value here is the *offline* properties — reachability, liveness, obligation
visibility — and those need the graph as an inspectable value, which is the part a
library does not provide.

**Generate the Swift from the SQL (or vice versa).** Correct in principle and the right
answer once the service tier owns the lifecycle. Today the migrations are an incomplete
record of the schema (14 of 15 tables were never created by a migration), so generating
from them would encode the gaps.

## Consequences

**Good.** One place to change a rule. The UI cannot drift from the server's permission
model without a test failing. New states are cheap: add an edge, and the invariants tell
you what you broke. The graph is reviewable by someone who does not read Swift.

**Costs.** The table is verbose, and an edge with a subtle guard still needs a human to
notice the guard is wrong — the invariants prove structural properties, not business
correctness. There is currently one orphan: `OrderStatus.cancelled` is a legacy value
with no edges in the table, retained only so old rows decode.

**Not yet true.** The database does not enforce the table; it enforces its own copy in
13 SQL functions. The two agree today because a human checked. Closing that gap is the
point of moving the order service to Kotlin, where the same declared table can be the
only implementation.

## Verification

`swift test --filter 'OrderLifecycle'` — 17 tests, all passing. Runs as its own required
CI job (`lifecycle-invariants`).
