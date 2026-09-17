# The dispatch engine — design, results, and what they do not license you to claim

`Sources/RavonCore/Dispatch/` — 6 files, 1,208 lines, 21 tests.
Decisions recorded in [ADR 0002](adr/0002-min-cost-matching-over-greedy.md) and
[ADR 0003](adr/0003-deterministic-simulation-as-evaluation.md).

**All numbers below are simulator output**, re-measured against the working tree of
`mmarufov/bucharest-v9` (parent commit `737911a`) rather than copied from an earlier
write-up. Where a figure here disagrees with an older document, this one is what the code
produces today.

## The problem

Ravon had no dispatch system. The entire assignment logic was:

```sql
SELECT o.* FROM orders o JOIN restaurants r ON r.id = o.restaurant_id
WHERE o.courier_id IS NULL
  AND o.status IN ('accepted','preparing','ready')
  AND ST_DWithin(restaurant_point, courier_point, 50000)
ORDER BY o.created_at;
```

Filter by a 50 km radius, sort by age, render a list, and the first courier to tap
`claim_order` wins. That is a job board. No scoring, no fairness, no lookahead — and
assignment is the core technical problem of a delivery marketplace.

## The design

**Assignment as minimum-cost bipartite matching.** Given the idle couriers and the
unassigned orders at a dispatch tick, choose the set of pairs minimising total cost.
Implemented as the Jonker–Volgenant form of the Hungarian algorithm with potentials,
O(n²m), handling rectangular inputs by padding to square.

**The cost function is where the judgment is.** The objective is deliberately *not*
"minimise total distance." Pure distance minimisation has two failure modes in a real
marketplace:

- couriers on the edge of the city never get work — **starvation**;
- an old order keeps losing to newer ones that happen to have a closer courier —
  **tail latency**.

So cost carries explicit credits, capped so one stale order cannot dominate a batch:

```
cost = travelToPickup + waitAtRestaurant + deliveryLeg
     − min(orderAge   × 1.5, 25)      // urgency
     − min(courierIdle × 0.4, 25)     // fairness
```

`waitAtRestaurant` matters and is easy to miss: a courier who beats the kitchen stands at
the counter, and that idle time is real cost — it delays whatever they would do next.

Pairs that must never match (courier excluded from the order, outside the 8 km service
radius) return a `forbidden` sentinel so the solver treats them as unmatchable rather
than merely expensive. Leaving an order unassigned is correct; dispatching a banned
courier is not.

**Why a simulator.** There is no way to A/B a dispatch algorithm against real couriers in
a pre-launch city, and "it feels faster" is not a claim worth making. So the marketplace
runs in deterministic simulation: seeded SplitMix64 clock, synthetic arrivals over
clustered restaurant locations around Dushanbe, couriers moving at finite speed, and the
real `Dispatcher` implementations driving assignment. Same seed, same numbers — which is
what makes it a measurement rather than an anecdote.

## Results

30 seeds · 12 couriers · 240 orders · 180-minute window · `latent = .none`:

| metric | greedy FCFS → optimal batch |
|---|---|
| orders assigned to a courier | **+44.6% mean** (min +29.9%, max +53.8%) |
| mean delivery time | **−45.3% mean** (range −51.7% to −39.7%) |
| total courier travel | −1.1% mean (range −4.2% to **+2.1%**) |
| seeds where optimal won | **30 / 30**, strictly |

Single run, seed 42:

```
greedy-fcfs:
  assigned            115/240 (47.9%)
  wait to assign      mean 85.6 min, p95 173.9 min
  delivery duration   mean 114.6 min
  courier travel      988.3 km total
  fairness            gini 0.069, 0 courier(s) idle all shift

optimal-batch:
  assigned            162/240 (67.5%)
  wait to assign      mean 46.8 min, p95 172.4 min
  delivery duration   mean 67.7 min
  courier travel      997.8 km total
  fairness            gini 0.063, 0 courier(s) idle all shift
```

**45% more orders assigned, 45% faster, for no measurable extra driving.**

That last clause is deliberately weaker than "on less fuel." The 30-seed mean travel
difference is −1.1%, but the spread crosses zero: the worst seed drives 2.1% *further*,
and seed 42 above is one of them (+1.0%). "Same fuel" is defensible; "less fuel" is not,
and the test that guards this (`test_throughputGainDoesNotCostExtraTravel`) asserts a 10%
ceiling precisely because tightening it to the mean would make it flaky.

## The finding that matters more than the headline

The advantage is a function of scarcity. Holding demand at 240 orders on seed 42 and
varying supply:

| couriers | greedy assigned | optimal assigned | gain |
|---|---|---|---|
| 6 | 63 | 100 | **+58.7%** |
| 12 | 115 | 162 | +40.9% |
| 24 | 234 | 240 | +2.6% |
| 48 | 240 | 240 | **0.0%** |

**The optimisation is worth the most exactly when couriers are the bottleneck, and worth
nothing once supply exceeds demand.** That is the dinner rush versus a slow Tuesday. It is
asserted as a test (`test_advantageVanishesWhenCouriersAreAbundant`) so nobody later tunes
dispatch for a regime where it cannot matter.

Report the headline number without this caveat and the first good interviewer asks "under
what conditions?" — and there is no answer. Lead with the caveat instead.

## Correctness

The solver is verified **against brute force** — exhaustive permutation search over 300
random matrices of varying shape, asserting the matching equals the true optimum. Plus:
200 valid-permutation checks (no column assigned twice), surplus rows returning unmatched,
forbidden pairs never selected even when they are the only option, and a Haversine check
against the real Dushanbe → Khujand distance (~205 km).

Suite total across the whole package: **102 XCTest + 61 swift-testing = 163 tests**, all
passing.

## Honest limitations — say these before you are asked

- **Single-order assignment.** Real dispatch batches multiple orders onto one courier
  (DoorDash calls it batching/stacking). Not modelled, and it is the single largest
  missing source of efficiency.
- **Straight-line distance.** No road network, no traffic. Haversine is a consistent
  underestimate, so absolute times are optimistic; the *comparison* between strategies is
  unaffected because both use the same metric.
- **Kitchen prep times are drawn from a uniform distribution**, not learned from data.
- **No courier acceptance modelling.** The simulator assumes an assigned courier takes the
  order. In reality they decline — which is exactly the loop that has no
  `courier_decline_order` RPC yet. DeepRed carries P(Dasher accepts) as a first-class
  model input for this reason.
- **Cost weights are chosen, not learned.** 1.5, 0.4, cap 25, 18 km/h, 8 km are a policy
  the simulator lets you measure, not a fact about Dushanbe.
- **Not wired to the app.** This is the engine and its evaluation. Making it live needs a
  `dispatch_tick` job and replacing `claim_order` with an offer/accept flow — and moving
  it off the client, since a phone cannot see the fleet
  ([ADR 0005](adr/0005-extract-to-kotlin-not-rewrite.md)).

## Reproducing this

```bash
swift test --filter 'Dispatch|Hungarian'     # 15 tests, the regression guards
swift test --filter 'Switchback'             # 7 tests, the experiment-design study
```

The tests assert *properties* (optimal never loses; the mean gain stays above 0.35; the
advantage vanishes with surplus couriers) rather than exact numbers, so they survive
reasonable cost-model tuning while still defending the claims. The figures in the tables
above were produced by driving `MarketplaceSimulator.run` directly over the same
configurations.
