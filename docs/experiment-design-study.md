# Experiment design under interference — measuring the bias of A/B designs

`Sources/RavonCore/Dispatch/{SwitchbackExperiment,DispatchZone}.swift` — 7 tests.
Decision recorded in [ADR 0004](adr/0004-zone-partitioning.md).

**The result was not the one expected going in**, and the negative result is the part
worth reading.

All numbers re-measured against the working tree of `mmarufov/bucharest-v9` (parent
commit `737911a`). Where they disagree with an earlier write-up, these are what the code
produces today.

## The question

DoorDash randomises dispatch experiments over **(geographic zone × time block)** cells
rather than over individual orders, because orders in the same place at the same time
compete for the same courier fleet — the arms interfere, violating the independence
assumption every standard A/B test rests on.

The simulator makes something possible that production never does: **ground truth is
knowable.** Run the world entirely on algorithm A, then entirely on algorithm B, same
seed — the difference *is* the true effect. So instead of arguing about which design is
better, each design's **bias** can be measured directly.

Three designs, all on the same simulated world:

| design | randomisation unit |
|---|---|
| ground truth | none — two separate full-world runs |
| naive A/B | each individual order, coin-flipped |
| switchback | each (zone × time block) cell, 30-minute blocks |

## First result: both designs were badly biased

20 seeds, 12 couriers, 240 orders, one global courier pool:

```
ground truth lift:              +21.1 pts
naive-order-level-ab            mean |bias|  23.3 pts
switchback-zone-x-timeblock     mean |bias|  22.3 pts
```

Both estimators were off by more than the entire effect they were estimating, and the
switchback was not meaningfully better than the naive design. That contradicted the
expectation, so the next step was to find out why rather than tune until the expected
answer appeared.

## The diagnosis

The dominant error was **not** interference between arms. It was a **granularity
mismatch**.

A batch optimiser's effect is a property of the **whole dispatch decision**, not of an
individual order. `OptimalBatchDispatcher` earns its advantage by solving the assignment
across *all* pending orders at once. Split the orders 50/50 between arms and the treatment
arm only ever optimises over half of them — so what is being measured is not the algorithm
that would run in production. The treatment is not well defined at the order level.

And the switchback as first written had the same defect: randomising *which zone* runs
which algorithm does nothing if dispatch still draws from **one global courier pool**,
because the treatment arm still sees only a fraction of the orders.

**The fix is that dispatch itself must run per zone.** That is `ZonedDispatcher` — each
zone's couriers matched only to that zone's orders, making each zone a coherent small
market, and making the algorithm operate at the granularity the experiment randomises at.

## Second result: partitioning collapses the bias

20 seeds, randomisation grid matched to the dispatch grid, everything else held constant:

| dispatch partition | true lift | naive A/B mean \|bias\| | switchback mean \|bias\| |
|---|---|---|---|
| 1×1 (no partitioning) | 21.1 pts | 23.3 pts (20.4 – 29.0) | 22.3 pts |
| 2×2 zones | 6.3 pts | 8.3 pts (6.7 – 9.9) | 7.0 pts |
| 3×3 zones | 1.9 pts | **3.0 pts** (2.4 – 3.7) | **3.3 pts** |

Roughly a **7× reduction in absolute experiment bias**, achieved not by changing the
statistics but by changing the *system* so the algorithm operates at the granularity the
experiment randomises at. This is the second, non-obvious reason DoorDash partitions
markets into zones — beyond making the optimisation tractable, it is what makes the
optimisation **measurable**.

The parenthesised ranges on the naive rows are not sampling noise in the usual sense; see
[Reproducibility caveat](#reproducibility-caveat-a-real-defect) below.

## Three things that cut against that headline

### 1. The honest negative result

**At this scale, once dispatch is zone-partitioned, order-level randomisation is about as
unbiased as a switchback** (3.0 vs 3.3 points — same order of magnitude, no clear winner).

That does not contradict DoorDash; it localises *why* switchbacks matter. With 12 couriers
spread over 9 zones there is very little cross-arm competition left to contaminate, so
temporal blocking has almost nothing left to buy. Their markets are far more densely
coupled, with genuine carryover between time blocks — which is exactly the regime where
blocking pays. Reporting this as "I reproduced DoorDash's result" would be false; the
transferable finding is the granularity one.

It is pinned as a test (`test_switchbackAndNaiveAreComparableOnceZoned`) so it cannot be
quietly lost later.

### 2. Relative bias does not improve — it gets worse

Absolute bias falls 23.3 → 3.0 points. But the true effect falls 21.1 → 1.9 points over
the same range. As a *fraction of the effect being estimated*, bias goes from about 1.1×
to about 1.6×.

"10× less bias" is the flattering framing, and it is not the whole picture. The experiment
got cleaner in points and no better in ratio, because the thing being measured shrank at
the same time.

### 3. Zone partitioning costs real efficiency

That shrinking effect is a finding in its own right, and it was unprompted. Ground-truth
lift **fell from +21.1 points to +1.9 points** when dispatch was partitioned 3×3. A
courier cannot serve an adjacent zone even when they are the closest available, and that
lost headroom comes directly out of the optimiser's advantage.

So zones are a genuine three-way trade: **tractability and measurability against
optimality.** Finer partitions make the experiment cleaner and the mathematics cheaper,
and make the thing being measured smaller.

## Reproducibility caveat — a real defect

`MarketplaceSimulator` generates order and courier IDs with `UUID()`
(`MarketplaceSimulator.swift:279,303`), which is not seeded. Dispatchers ignore IDs, so
every dispatch result is fully reproducible from the seed and
`test_simulationIsReproducible` passes legitimately.

But `ArmAssignment.naiveOrderLevel` hashes the order UUID to choose an arm. **That design's
arm split is therefore re-randomised on every process run**, and its bias figures are not
reproducible from a seed — only stable in aggregate. The naive columns above are the mean
of 10 independent repetitions, with the observed range in parentheses; across those
repetitions the 1×1 figure ranged from 20.4 to 29.0 points.

The switchback design hashes zone × time-block, which is derived from seeded state, and is
bit-for-bit reproducible (22.25 pts on every repetition at 1×1).

The existing `test_armAssignmentIsDeterministic` does not catch this: it checks that
`arm(for:)` is a pure function of a record *within one run*, which is true. The fix is to
derive entity IDs from the seeded RNG. It is not applied here because this write-up is
documentation-only.

## What to say about it

> "I wanted to test a dispatch change, and the naive approach — randomise orders into two
> arms — is invalid, because orders in the same place at the same time draw from the same
> courier pool. DoorDash handles this with switchback tests that randomise over zone and
> time block instead.
>
> Because I had a simulator, I could do something they can't easily do in production: I
> knew ground truth, so I measured each design's bias instead of reasoning about it. Both
> designs came out with about 22–23 points of bias against a true effect of 21 points —
> the switchback was no better in any way that mattered.
>
> The reason turned out to be more interesting than interference. A batch optimiser's
> effect is a property of the whole dispatch decision, not of one order — so if you split
> the orders between arms, the treatment arm optimises over half the orders and you're
> measuring a different algorithm. Randomising over zones didn't fix it either, because
> dispatch still drew from one global courier pool.
>
> So I made dispatch run per zone. Absolute bias dropped from ~23 points to ~3 — about
> 7×, without touching the statistics. That's the second reason to partition a market:
> not just tractability, but measurability.
>
> Two caveats I'd volunteer. First, at my scale, once dispatch was zoned, plain
> order-level randomisation was about as unbiased as the switchback. Twelve couriers over
> nine zones leaves almost no cross-arm competition, so temporal blocking had nothing left
> to buy. I didn't reproduce their headline. Second, partitioning cost me something real:
> the true effect of the optimiser dropped from 21 points to 1.9, because couriers can't
> cross zone boundaries. So as a *fraction* of the effect, my bias actually got slightly
> worse. Zones trade optimality for tractability and measurability."

That is a better answer than a clean confirmation would have been, because every number in
it was measured and the reasoning survived being wrong once.

## Reproducing this

```bash
swift test --filter 'Switchback'    # 7 tests
```

The tests assert properties — bias above 10 points unpartitioned, below 6 partitioned, at
least halved by partitioning, monotone in partition fineness — rather than exact figures.
The tables above were produced by driving `SwitchbackExperiment.run` directly, repeating
the naive design 10 times for the reason given above.
