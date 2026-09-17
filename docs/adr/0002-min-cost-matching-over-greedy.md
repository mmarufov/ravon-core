# 0002 — Solve dispatch as minimum-cost matching, and do not minimise distance

**Status:** Accepted · 2026-09-16
**Scope:** `Sources/RavonCore/Dispatch/{HungarianSolver,Dispatcher}.swift`

## Context

Ravon's dispatch was this query:

```sql
SELECT o.* FROM orders o JOIN restaurants r ON r.id = o.restaurant_id
WHERE o.courier_id IS NULL
  AND o.status IN ('accepted','preparing','ready')
  AND ST_DWithin(restaurant_point, courier_point, 50000)
ORDER BY o.created_at;
```

Filter by a 50 km radius, sort by age, render a list, first courier to tap `claim_order`
wins. That is a job board. It has no scoring, no fairness, and — the expensive part — no
lookahead. Assignment is the core technical problem of a delivery marketplace and it was
being decided by reaction time.

## Decision

Two separate decisions, and the second is the one worth defending.

### Solve the whole batch, not one order at a time

At each dispatch tick, take the idle couriers and the unassigned orders and choose the
set of pairs minimising total cost — a rectangular assignment problem, solved with the
Jonker–Volgenant form of the Hungarian algorithm with potentials, O(n²m), padding to
square to handle surplus couriers.

Greedy's specific failure is not "slightly worse choices." It is that handing the nearest
courier to the oldest order can consume the *only* courier inside the service radius of a
second order and strand that order entirely. Batch matching pays a little more on the
first assignment to keep the second feasible. That is where the measured throughput
difference comes from — not faster driving, fewer orders dropped.

Pairs that must never match (courier excluded from the order, further than 8 km from
pickup) return a `forbidden` sentinel so the solver treats them as unmatchable rather
than merely expensive. Leaving an order unassigned is a correct outcome; dispatching a
banned courier is not.

### The objective is not total distance

Pure distance minimisation is the obvious objective and it is wrong, in two specific ways:

- **starvation** — couriers at the edge of the city are never the nearest to anything, so
  they never work;
- **tail latency** — an old order keeps losing to newer ones that happen to have a closer
  courier, and nothing bounds how long it waits.

So the cost, in minutes, is:

```
cost = travelToPickup + waitAtRestaurant + deliveryLeg
     − min(orderAge     × 1.5, 25)      // urgency credit
     − min(courierIdle  × 0.4, 25)      // fairness credit
```

Two details that are easy to miss. `waitAtRestaurant` is real cost: a courier who beats
the kitchen stands at a counter, and that time delays whatever they would have done next.
And the credits are **capped**, so one stale order or one bored courier cannot dominate a
whole batch — an uncapped urgency term degenerates into strict FIFO and throws away the
optimisation.

Cost is allowed to go negative once credits apply. The solver is fine with that;
potentials are translation-invariant.

## Alternatives considered

**Keep greedy, tune the radius.** Tuning changes which orders are feasible, not the
lack of lookahead. Measured: greedy loses on 30 of 30 seeds.

**A mixed-integer program with a commercial solver (Gurobi).** What DoorDash's DeepRed
actually uses — because they also decide batching (several orders per courier) and
strategic dispatch delay, which are genuinely integer-programming problems. Ravon models
single-order assignment only, and for that the matching is *exactly* solvable in
microseconds. See [ADR 0007](0007-rejected-technologies.md) for the threshold at which
this flips.

**Auction / offer-and-accept.** Closer to how real dispatch works — DoorDash's optimiser
carries P(Dasher accepts) as a model input, because an optimal assignment that gets
declined is worthless. Ravon has no acceptance model and no `courier_decline_order` RPC,
so this is out of reach until both exist. It is the most honest gap in the design.

**Min-cost flow rather than Hungarian.** Equivalent at this size, and would be the right
generalisation once one courier can carry several orders. No reason to pay for the
generality now.

## Consequences

**Good.** Measured against greedy FCFS over 30 seeds (12 couriers, 240 orders, 180-minute
window): **+44.6% orders assigned to a courier** (min +29.9%, max +53.8%, optimal wins 30/30) and
**−45.3% mean modeled delivery time**, with **no measurable travel penalty** (mean −1.1%,
but the worst single seed is +2.1% — on some seeds it does drive further). All figures are
simulator output; see [ADR 0003](0003-deterministic-simulation-as-evaluation.md) for what
that does and does not license you to claim.

**The result that matters more than the headline.** The advantage is a function of
scarcity. Holding demand at 240 orders and varying supply, on seed 42:

| couriers | greedy | optimal | gain |
|---|---|---|---|
| 6 | 63 | 100 | **+58.7%** |
| 12 | 115 | 162 | +40.9% |
| 24 | 234 | 240 | +2.6% |
| 48 | 240 | 240 | **0.0%** |

This is a **peak-load optimisation**, worth the most exactly when couriers are the
bottleneck and worth nothing once supply exceeds demand. It is pinned as a test
(`test_advantageVanishesWhenCouriersAreAbundant`) so nobody later tunes dispatch for a
regime where it cannot matter.

**Costs.** The cost weights (1.5, 0.4, cap 25, 18 km/h, 8 km) are chosen, not learned.
They are a policy the simulator lets you measure, not a fact. The solver is verified
optimal *for the cost function given*; if the cost function is wrong the answer is
confidently wrong.

**Correctness.** `HungarianSolver.solve` is checked against exhaustive permutation search
over 300 random matrices of varying shape, asserting exact equality with the true optimum;
plus 200 valid-permutation checks, surplus-row handling, and forbidden pairs never being
selected even when they are the only option.

**Not wired to the app.** This is the engine and its evaluation. Making it live needs a
`dispatch_tick` job and replacing `claim_order` with an offer/accept flow. It also needs
to stop living in a client package — see [ADR 0005](0005-extract-to-kotlin-not-rewrite.md).

## Verification

`swift test --filter 'Dispatch|Hungarian'` — 15 tests, all passing. Runs as its own
required CI job (`dispatch-quality`).
