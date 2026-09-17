# 0003 — Evaluate dispatch by deterministic simulation, with latent state

**Status:** Accepted · 2026-09-16
**Scope:** `Sources/RavonCore/Dispatch/MarketplaceSimulator.swift`

## Context

A dispatch algorithm cannot be A/B tested against real couriers in a city that has not
launched. There are no couriers. So the options for justifying
[ADR 0002](0002-min-cost-matching-over-greedy.md) were: argue from the algorithm's
properties, benchmark it on a synthetic matrix, or build a world and run it.

Arguing from properties is not nothing — the Hungarian algorithm is provably optimal for
the cost function it is given. But "provably optimal for a cost function I invented"
answers the wrong question. The question is whether solving the batch produces a better
*marketplace* than taking orders one at a time, and that depends on arrival patterns,
courier movement, kitchen timing and geography, none of which the optimality proof sees.

Benchmarking on a random cost matrix is worse: it measures the solver, not the policy.

## Decision

Build a deterministic discrete-event simulator and make it the evaluation method.

- **Seeded SplitMix64**, not `SystemRandomNumberGenerator`. Same seed, same numbers —
  which is the difference between a measurement and an anecdote, and what lets a dispatch
  regression show up as a changed number in CI.
- Synthetic arrivals over clustered restaurant locations around Dushanbe, couriers moving
  at finite speed, a 30-second dispatch tick, and the **real `Dispatcher` implementations**
  driving assignment — not a reimplementation of them.
- Results report more than the mean: assignment rate, mean and p95 wait-to-assign, mean
  delivery duration, total courier travel, a **Gini coefficient over jobs per courier**,
  and the count of couriers who did nothing all shift. Mean delivery time hides starvation
  completely; the Gini is there to expose it.

### Latent state was necessary, and it is the non-obvious part

Without hidden state the simulator is a closed formula: delivery time is computed from
distance, speed and prep time, all of which would also be a prediction model's inputs.
Any "ETA model" fitted against it would re-derive the generating equation, score R² ≈ 1.0,
and have measured nothing.

So `LatentVariability` introduces irreducible uncertainty *from the model's point of view*:
a persistent per-restaurant prep bias (some kitchens are just slow), per-order prep noise,
a per-courier speed multiplier, and a time-varying city-wide traffic multiplier. A model
may observe outcomes and aggregate features; it may never observe these parameters.

This is what lets the *true conditional distribution* be known while the model's estimate
is genuinely uncertain — which is the thing production systems never have, and what makes
calibration work (PIT, CRPS) and drift detection into problems with checkable answers.

Dispatch comparisons deliberately run with `latent = .none`. Latent noise only adds
variance to a paired test where both arms see the identical world, so it costs statistical
power and buys nothing. The same switch that makes prediction honest would make the
dispatch comparison noisier for no reason.

## Alternatives considered

**SimPy or an off-the-shelf discrete-event library.** Would mean a second language in the
loop, and the simulator has to call the real Swift `Dispatcher` types or it is testing a
copy. Re-implementing the dispatcher in Python to simulate it defeats the purpose.

**Replay from production logs.** The correct method, and unavailable: there is no
production. It is also strictly weaker for this question, because a log shows what
happened under one policy and cannot show what the other policy would have done.

**A closed-form queueing model.** M/M/c gives throughput bounds but no way to represent
"the nearest courier to order A is also the only courier who can reach order B" — which
is precisely the effect being measured.

## Consequences

**Good.** The dispatch claim is reproducible from a seed by anyone who clones the repo. A
change that makes dispatch worse fails CI rather than going unnoticed. And it made the
scarcity sweep possible — the finding that the optimiser's advantage vanishes above ~24
couriers is only available if you can re-run the same world with a different fleet size,
which production cannot do.

It also made [ADR 0004](0004-zone-partitioning.md) possible at all: knowing ground truth
is what turns "which experiment design is better?" from an argument into a measurement.

**Costs, and these bound every number in this repo.**

- **Straight-line Haversine distance.** No road network, no one-way streets, no traffic
  lights. Absolute times are optimistic. The *comparison* between strategies is unaffected
  because both arms use the same metric — but do not quote the absolute minutes as an ETA.
- **Kitchen prep drawn from a uniform distribution**, not learned from data.
- **No courier acceptance modelling.** An assigned courier takes the order. In reality
  they decline, which is the loop with no `courier_decline_order` RPC behind it.
- **Single-order assignment.** No batching or stacking, which is a large part of real
  dispatch efficiency.
- A simulator can only refute a policy in the world it models. It says the batch matcher
  wins under these assumptions; it cannot say by how much in Dushanbe.

**A defect found while writing this ADR.** Determinism is not complete.
`MarketplaceSimulator` generates order and courier IDs with `UUID()`
(`MarketplaceSimulator.swift:279,303`), which is unseeded. Dispatchers ignore IDs, so
every dispatch result is reproducible and `test_simulationIsReproducible` passes
legitimately. But `ArmAssignment.naiveOrderLevel` hashes the order UUID to pick an arm, so
**that experiment design's arm split is re-randomised on every process run**. Its bias
figures are stable only in aggregate (see [ADR 0004](0004-zone-partitioning.md), where
they are reported as a range over 10 repetitions). The switchback design hashes
zone × time-block and is fully reproducible. The fix is to derive IDs from the seeded RNG;
it is not applied here because this ADR is documentation-only.

## Verification

`swift test --filter 'Dispatch'` — includes `test_simulationIsReproducible`, which asserts
identical assignment counts, mean delivery time, travel and per-courier job counts across
two runs of the same seed.
