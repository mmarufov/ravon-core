# 0004 — Partition the market into zones: tractability *and* measurability, at a real cost

**Status:** Accepted · 2026-09-16
**Scope:** `Sources/RavonCore/Dispatch/{DispatchZone,SwitchbackExperiment}.swift`

## Context

DoorDash partitions markets into geographic zones and randomises dispatch experiments
over **(zone × time block)** cells rather than over individual orders. The published
reason is interference: orders in the same place at the same time compete for the same
courier fleet, so the arms of a naive A/B test are not independent and the standard
estimator is biased.

The intent here was to reproduce that. The simulator makes something possible that
production does not: **ground truth is knowable.** Run the whole world on algorithm A,
then the whole world on algorithm B with the same seed, and the difference *is* the true
effect. So each design's bias can be measured directly instead of argued about.

Three designs on the same simulated world:

| design | randomisation unit |
|---|---|
| ground truth | none — two separate full-world runs |
| naive A/B | each individual order, coin-flipped |
| switchback | each (zone × time block) cell |

## First result: the expected answer did not appear

With one global courier pool, over 20 seeds, both designs were badly biased and the
switchback was **not meaningfully better**:

| design | mean \|bias\| vs a true lift of 21.1 pts |
|---|---|
| naive order-level A/B | 23.3 pts |
| switchback (zone × time block) | 22.3 pts |

The bias was larger than the effect being estimated. Rather than tune until the expected
answer appeared, the next step was to find out why.

## The diagnosis, and the decision

The dominant error was **not** interference between arms. It was a **granularity
mismatch**.

A batch optimiser's effect is a property of the **whole dispatch decision**, not of an
individual order. `OptimalBatchDispatcher` earns its advantage by solving assignment
across *all* pending orders at once. Split the orders 50/50 between arms and the treatment
arm only ever optimises over half of them — so the thing being measured is not the
algorithm that would run in production. The treatment is not well defined at the order
level.

The first switchback had the same defect for a different reason: randomising *which zone
runs which algorithm* changes nothing if dispatch still draws from **one global courier
pool**, because the treatment arm still sees a fraction of the orders.

**So the decision is that dispatch itself runs per zone.** `ZonedDispatcher` groups
couriers and orders by zone and runs the base dispatcher independently inside each one,
making every zone a coherent small market. The experiment then randomises at the same
granularity the algorithm operates at.

## Second result: partitioning collapses the bias

20 seeds, randomisation grid matched to the dispatch grid, everything else held constant.
The naive design's arm split is not reproducible across runs (see
[ADR 0003](0003-deterministic-simulation-as-evaluation.md)), so its figures are the mean
over 10 independent repetitions with the observed range:

| dispatch partition | true lift | naive A/B mean \|bias\| | switchback mean \|bias\| |
|---|---|---|---|
| 1×1 (none) | 21.1 pts | 23.3 pts (20.4 – 29.0) | 22.3 pts |
| 2×2 | 6.3 pts | 8.3 pts (6.7 – 9.9) | 7.0 pts |
| 3×3 | 1.9 pts | **3.0 pts** (2.4 – 3.7) | **3.3 pts** |

Absolute bias falls by roughly **7×** — achieved not by changing the statistics but by
changing the *system* so the algorithm operates at the granularity the experiment
randomises at. This is the second, non-obvious reason to partition a market: beyond making
the optimisation tractable, it is what makes the optimisation **measurable**.

## Three honest caveats, all of which cut against the headline

**1. The negative result.** At this scale, once dispatch is zone-partitioned, order-level
randomisation is about as unbiased as a switchback (3.0 vs 3.3 pts — same order of
magnitude, no winner). That does not contradict DoorDash; it localises *why* switchbacks
matter. With 12 couriers over 9 zones there is very little cross-arm competition left to
contaminate, so temporal blocking has almost nothing to buy. Their markets are far more
densely coupled with genuine carryover between time blocks, which is exactly the regime
where blocking pays. Reporting this as "I reproduced DoorDash's result" would be false.
The transferable finding is the granularity one.

**2. Relative bias does not improve — it gets worse.** Absolute bias drops 23.3 → 3.0 pts,
but the true effect drops 21.1 → 1.9 pts at the same time. As a fraction of the effect
being estimated, bias goes from ~1.1× to ~1.6×. "10× less bias" is the flattering framing
and it is not the whole picture: the experiment got cleaner in points and no better in
ratio, because the thing being measured shrank too.

**3. Zones cost real efficiency.** That shrinking effect is the third finding, and it was
unprompted: ground-truth lift fell from **+21.1 points to +1.9 points** under a 3×3
partition. A courier cannot serve an adjacent zone even when they are the closest
available, and that lost headroom comes directly out of the optimiser's advantage.

So zones are a genuine three-way trade: **tractability and measurability against
optimality.** Finer partitions make the mathematics cheaper and the experiment cleaner,
and make the thing being measured smaller.

## Alternatives considered

**Keep global dispatch, fix the statistics instead** — cluster-robust standard errors, a
network-interference estimator. These correct inference about a well-defined treatment.
They cannot fix a treatment that is not well defined at the randomisation unit, which was
the actual problem.

**Time-only switchback (no zones).** Whole-city blocks alternating between algorithms.
Valid, and it removes the granularity mismatch — but it gives one observation per block
instead of one per cell, so the power is far worse for the same wall-clock.

**Cluster by restaurant rather than by geography.** Plausible, since orders from one
restaurant share a kitchen queue. Rejected because courier competition is geographic, not
per-restaurant, and geography is also what makes the matching tractable.

## Consequences

**Good.** Experiments on dispatch are now believable at this scale. `ZonedDispatcher` also
gives the standard scaling story for free: shard by geography, run the matching per zone.

**Costs.** Measured optimality loss, above. A courier idle on a zone boundary is wasted.
The grid is a fixed square partition of a circle around the city centre; real zones follow
demand density and road topology.

**Open.** No spillover handling at boundaries, no dynamic re-zoning, and the block length
(30 minutes) is chosen, not tuned.

## Verification

`swift test --filter 'Switchback'` — 7 tests, including
`test_zonePartitioningCollapsesExperimentBias`, `test_biasDecreasesWithFinerPartitioning`
and `test_switchbackAndNaiveAreComparableOnceZoned`, which pins the negative result so it
cannot be quietly lost.

Full study: [docs/experiment-design-study.md](../experiment-design-study.md).
