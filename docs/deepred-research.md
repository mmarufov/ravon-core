# DeepRed — what DoorDash actually runs, and how Ravon compares

Research notes from DoorDash's own engineering blog, with an honest gap analysis against
what this repo contains. Sources at the bottom; everything in sections 1–4 is their
published material, quoted.

This is background for [ADR 0002](adr/0002-min-cost-matching-over-greedy.md),
[ADR 0003](adr/0003-deterministic-simulation-as-evaluation.md) and
[ADR 0004](adr/0004-zone-partitioning.md).

## 1. DeepRed's anatomy

> *"DoorDash delivers millions of orders every day with the help of DeepRed, the system at
> the center of our last-mile logistics platform."*

It is a **two-layer architecture**. This is the single most important structural fact.

```
        candidate generator
                 │
                 ▼
   ┌──────────────────────────────┐
   │  ML layer — predict          │   order ready time
   │                              │   travel time
   │                              │   P(Dasher accepts offer)
   └──────────────────────────────┘
                 │  point estimates + variance
                 ▼
   ┌──────────────────────────────┐
   │  Optimization layer          │   mixed-integer program
   │  (MIP, Gurobi)               │   → assignment
   │  partitioned by zone         │   → batching decisions
   │                              │   → strategic dispatch delay
   └──────────────────────────────┘
```

**The ML layer** estimates three things: how long until the food is ready, how long the
travel legs take, and — the one most people would never think of — **the probability a
Dasher accepts the offer**. Dispatch is not assignment; it is *offering*. An optimal
assignment that gets declined is worthless.

**The optimization layer** is a **mixed-integer program solved with a commercial solver
(Gurobi)**. It scores and ranks candidate offers, decides **batching** (one Dasher, several
orders), and can **strategically delay a dispatch** when waiting produces a better outcome.
The market is **partitioned into geographic zones** to keep the MIP tractable.

**The objective is an explicit two-way trade:**

> *"The scoring function is designed to recognize tradeoffs between **efficiency** (using
> Dasher time as efficiently as possible) and **quality** (getting deliveries to consumers
> as quickly as possible), while trying to account for explained and unexplained variance
> in ML estimates of order ready times, travel times, and Dasher acceptance rate."*

Note they carry the *variance* of the ML estimates into the optimizer, not just the means.

**Their evolution is directly relevant to us:**

> *"The newer MIP approach supports more complicated routes with 2 or more deliveries,
> addressing limitations of the **prior single-delivery system**."*

So DeepRed began as single-delivery assignment and grew into a batching MIP.

## 2. Routing: ruin-and-recreate

Once a route has multiple stops, ordering them is a vehicle-routing problem — NP-hard.

> *"Synchronous optimization [could take] hours or even days when it must be completed in
> seconds."*

Their answer: the **ruin-and-recreate** metaheuristic (destroy part of a solution,
rebuild it greedily, keep improvements) plus **multithreading** to optimise chunks
concurrently.

And a detail worth stealing outright:

> *"DoorDash also uses a trivial greedy route optimization algorithm as a **fallback**
> against failures and as a useful **benchmark** solution to ensure that the
> ruin-and-recreate solution is indeed the best possible quality."*

**Greedy as a benchmark to prove the smart algorithm is actually better** is exactly the
pattern already in `DispatchSimulationTests`. Same reasoning, independently arrived at.

## 3. Simulation — they do what we built

> *"For complex systems such as the DoorDash assignment system, simulating the impact of
> algorithmic changes is often faster and less costly than experimenting on features live
> in production."*

> *"Simulations give DoorDash insight about how dispatch models perform in different
> operating conditions, including how efficiently they could handle **high demand, low
> Dasher availability**, and other likely future scenarios."*

That is the courier-supply sweep in `test_advantageVanishesWhenCouriersAreAbundant` —
their stated use case, matched.

Their architectural choice worth noting: the simulator runs **against a replica of the
production assignment system**, and production code can be deployed to the simulation
cluster **without code changes**. Their published guidance is to *reuse existing
infrastructure and minimise simulation-specific behaviour in production systems*. Ravon
already satisfies this by construction — the simulator calls the real `Dispatcher`
protocol, not a copy of it.

## 4. Experimentation: switchback tests — **the biggest gap**

This is the most sophisticated thing they publish, and Ravon has nothing like it.

**Standard A/B testing is invalid in their marketplace.** Treatment and control orders
happening at the same time in the same area **are not independent** — they compete for the
same Dasher fleet. Give order A a better algorithm and it takes the courier that order B
needed. The measured effect is contaminated by interference (a SUTVA violation).

Their answer: **switchback experiments** — randomise the *algorithm* over
**(geographic zone × time block)** cells rather than over orders, so a whole zone runs one
variant for a whole block and the market serves as its own comparison. They built an
**assignment-specific bucketing system** with a "two-zone process," on their
experimentation platform **Curie**. Design considerations they call out: time trends,
carryover between blocks, block length, and correlated observations — plus balancing
network effects, learning effects and statistical power.

---

## 5. Honest gap analysis

Updated after the dispatch, zoning and experiment work landed. Two rows that were the
largest gaps when this research was written are now closed.

| DeepRed component | What it does | Ravon today | Gap |
|---|---|---|---|
| Optimization layer — assignment | choose Dasher per order | min-cost bipartite matching (Hungarian), verified optimal vs brute force | **equivalent** for single-delivery |
| Optimization layer — batching | 2+ deliveries per route | one order per courier | **their headline evolution — biggest remaining gap** |
| Optimization layer — dispatch delay | hold an order for a better match | dispatch immediately | missing |
| Zone partitioning | tractability *and* measurability | `ZonedDispatcher`, measured optimality cost | **match**, with the cost quantified |
| ML layer — travel time | predict leg duration | Haversine ÷ fixed speed | crude but honest |
| ML layer — order ready time | predict kitchen | uniform random in sim; merchant-typed `estimated_prep_time` in app | no model |
| ML layer — **P(accept)** | will the Dasher take it? | assumes acceptance | **conceptual gap — the interesting one** |
| Efficiency vs quality objective | explicit trade | capped urgency + fairness credits | same idea, their terms |
| Estimate variance in objective | carry uncertainty, not just means | point estimates | missing |
| Routing (ruin-and-recreate) | order the stops | n/a — needs batching first | after batching |
| Greedy as benchmark | prove the smart one wins | `GreedyDispatcher`, 30-seed paired comparison | **match** |
| Simulation platform | evaluate offline under varied supply | deterministic, seeded, supply sweep | **match** |
| Switchback experiments | unbiased eval under interference | built and bias-measured against ground truth | **match**, with a negative result |

The two closed rows are written up in [the dispatch study](dispatch-engine.md) and
[the experiment-design study](experiment-design-study.md). The switchback result is
deliberately *not* a clean reproduction of theirs — see that write-up for why, and why
the honest version is the more useful finding.

---

## 6. What to build next, ranked

### 1. Batching (2 deliveries per route)

Their stated evolution from the "prior single-delivery system," and now the largest gap.
Bipartite matching structurally **cannot** express it — one courier to one order is the
definition of a matching. It needs a set-packing formulation over candidate *routes*
(single-order routes plus feasible pairs), which is the same modelling jump DoorDash made,
and it is the point at which an exact polynomial algorithm stops being available
([ADR 0007](adr/0007-rejected-technologies.md) records the solver threshold this creates).
With batching in place, ruin-and-recreate becomes meaningful.

### 2. Acceptance-probability layer

Makes the two-layer architecture real rather than nominal. Even a simple logistic model
on distance, payout and courier idle time gives an expected-value objective:
`P(accept) × value − (1 − P(accept)) × re-offer cost`. This is the DeepRed idea most
people miss entirely, because it reframes dispatch from **assignment** to **offering**.
It also has a concrete prerequisite in this system: there is no `courier_decline_order`
RPC, so the decline loop does not exist to learn from.

### 3. Strategic dispatch delay

Hold an order briefly when a better courier is likely to free up. Cheap in simulation and
a good "what did you learn" result either way: it trades tail latency for efficiency,
which is the efficiency-versus-quality axis DoorDash names explicitly.

### 4. Carry estimate variance into the objective

They optimise over distributions, not point estimates. The simulator already has the
latent state needed to make this a real problem
([ADR 0003](adr/0003-deterministic-simulation-as-evaluation.md)) — a probabilistic ETA
with calibration checks would feed it.

### Deliberately not doing

- **Gurobi.** At single-order assignment size the problem solves *exactly* in
  microseconds, so a commercial solver cannot improve the answer. The threshold at which
  that stops being true is recorded in [ADR 0007](adr/0007-rejected-technologies.md).
- **Fitted ML models on synthetic data.** A hand-specified model you can explain beats a
  fitted model you cannot, and fitting to the simulator's own generating process measures
  nothing unless the latent state is switched on.

---

## 7. How this compares, stated honestly

> "I read up on DeepRed and rebuilt its shape: a two-layer dispatcher where estimates feed
> an optimiser. My optimisation layer is a min-cost bipartite matching solved with the
> Hungarian algorithm — equivalent to what DeepRed did before their next-generation MIP,
> since matching cannot express batching. My objective carries the same
> efficiency-versus-quality trade they describe, as capped urgency and fairness credits.
>
> Then I did what their simulator blog says to do: evaluated it offline under varying
> supply instead of guessing, using the real dispatcher behind the same protocol rather
> than a copy. Across 30 seeds: 44.6% more orders assigned and 45.3% lower mean modeled
> delivery time, for no measurable extra driving — and the advantage goes to zero once
> couriers outnumber demand, so it is a peak-load optimisation, not a general win.
>
> I also built their switchback design and measured its bias against simulator ground
> truth, which is something they cannot easily do in production. It did not reproduce
> their headline: at my scale, once dispatch was zone-partitioned, plain order-level
> randomisation was about as unbiased as the switchback. What I got instead was a
> granularity result — a batch optimiser's effect is a property of the whole dispatch
> decision, so the experiment has to randomise at the granularity the algorithm operates
> at.
>
> The gap I would close next is the one I think is most interesting: DeepRed's ML layer
> predicts whether the Dasher will even *accept* the offer. That reframes the whole thing
> from an assignment problem to an offering problem, and my current model just assumes
> acceptance."

Knowing what has *not* been built, and why it matters, is the strongest signal available.

---

## Sources

- [Using ML and Optimization to Solve DoorDash's Dispatch Problem](https://careersatdoordash.com/blog/using-ml-and-optimization-to-solve-doordashs-dispatch-problem/)
- [Next-Generation Optimization for Dasher Dispatch at DoorDash](https://careersatdoordash.com/blog/next-generation-optimization-for-dasher-dispatch-at-doordash/)
- [Scaling a routing algorithm using multithreading and ruin-and-recreate](https://careersatdoordash.com/blog/scaling-a-routing-algorithm-using-multithreading-and-ruin-and-recreate/)
- [4 Essential Steps for Building a Simulator](https://doordash.engineering/2022/08/16/4-essential-steps-for-building-a-simulator/)
- [Switchback Tests and Randomized Experimentation Under Network Effects at DoorDash](https://careersatdoordash.com/blog/switchback-tests-and-randomized-experimentation-under-network-effects-at-doordash/)
- [Balancing Network Effects, Learning Effects, and Power in Experiments](https://careersatdoordash.com/blog/balancing-network-effects-learning-effects-and-power-in-experiments/)
- [Iterating Real-time Assignment Algorithms Through Experimentation](https://careersatdoordash.com/blog/optimizing-real-time-algorithms-experimentation/)
- [Meeting DoorDash Growth with a Self-Service Logistics Configuration Platform](https://doordash.engineering/2024/01/23/meeting-doordash-growth-with-a-self-service-logistics-configuration-platform/)
- [Experimentation Platform at DoorDash (Curie)](https://opendatascience.com/experimentation-platform-at-doordash/)
