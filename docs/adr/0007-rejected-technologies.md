# 0007 — Technologies deliberately not used, and what would change that

**Status:** Accepted · 2026-09-16
**Scope:** whole-system

## Context

This system is modelled on a published reference architecture — DoorDash's engineering
blog is unusually detailed about what they run and why. The temptation when copying a
reference architecture is to copy the *component list*, because the component list is the
visible part.

That is the wrong thing to copy. Every piece of infrastructure in a large system is there
because a specific number got too big. Adopting the piece without the number gets you the
operational cost with none of the benefit, and — worse for a system maintained by one
person — it gets you a plausible-looking architecture that nobody can explain.

So each rejection below is recorded with the threshold that would reverse it. A rejection
without a threshold is not a decision, it is an excuse.

## Decision

Reject the following, each with its trigger.

---

### Gurobi (commercial mixed-integer programming solver)

**What DeepRed uses it for.** Their optimisation layer is a MIP, because they decide three
things at once: which courier gets which order, **batching** (one courier carrying several
orders on one route), and **strategic dispatch delay** (holding an assignment back because
waiting produces a better outcome). Those interact, and jointly they are genuinely
integer-programming.

**Why not here.** Ravon models single-order assignment only. That is not a MIP — it is the
rectangular assignment problem, which has an exact polynomial algorithm. The Hungarian
solver in `Sources/RavonCore/Dispatch/HungarianSolver.swift` returns the *provable
optimum*, verified against exhaustive permutation search over 300 random matrices. A
commercial solver cannot beat optimal. It would run slower, cost money, and add a native
dependency and a licence server.

**Threshold.** The moment batching enters the model. One courier carrying two or more
orders makes the problem a vehicle-routing problem, the assignment structure is gone, and
the exact algorithm no longer applies. At that point the sequence is: try open-source
first (OR-Tools CP-SAT, or a min-cost-flow formulation for the restricted two-order case),
and only reach for Gurobi if the open-source solver misses the dispatch tick deadline on
realistic instance sizes. Scale alone will not trigger this — the current solver is
O(n²m), so a few hundred couriers against a few hundred orders is microseconds, and
Dushanbe will not outgrow it.

---

### Cassandra

**What it is for.** Horizontally scalable writes across regions, tunable consistency,
no single primary to saturate. DoorDash used it for the checkout service precisely because
their write volume outgrew a single Postgres.

**Why not here.** Every entity in this system has strong relational structure and needs
multi-row transactions: an order, its line items, its status history and its ledger
entries must commit together or not at all. Cassandra gives that up by design — no joins,
no multi-partition transactions, and denormalised tables designed per query, which means
a new access pattern is a new table and a backfill. The double-entry ledger in particular
wants a deferred constraint at COMMIT, which is a relational-database feature with no
Cassandra equivalent.

Postgres also brings PostGIS, which dispatch depends on, and row-level security, which is
currently the only thing standing between a client and the data.

**Threshold.** Sustained write throughput a single well-tuned Postgres primary cannot
absorb — realistically several thousand writes per second after the obvious moves
(connection pooling, read replicas, partitioning the history tables by month) are
exhausted. Or a hard multi-region-active-write requirement. Ravon is one city. Neither is
close, and the intermediate step is Postgres partitioning and CQRS read models, not a new
database.

---

### Kafka

**Why not here.** Covered in full in [ADR 0006](0006-postgres-over-kafka.md): the
guarantees Kafka provides — durability, ordering, replay, fan-out — are implemented on
Postgres with an append-only transition table, CDC over websockets and `pg_cron`.
Transactional event emission is actually *better* this way, because the state change and
the event are one write rather than two with an outbox in between.

**Threshold.** Restated briefly: more than a handful of independent polling consumers;
analytics replay contending with transactional traffic; or — the likely real trigger —
multiple extracted services needing to exchange events, at which point sharing one
database table as a bus becomes the anti-pattern Kafka exists to fix. Numerically,
sustained event rates above roughly 5,000/second. Current arithmetic: about 2.5/second at
an optimistic launch peak.

---

### Service mesh (Istio, Linkerd)

**What it is for.** mTLS between services, retries and circuit breaking without
per-service code, traffic shifting for canaries, and uniform observability across a fleet
of services in many languages.

**Why not here.** There is one deployable today, and after [ADR 0005](0005-extract-to-kotlin-not-rewrite.md)
there will be at most four. A mesh's value scales with the number of service-to-service
edges; with four services the edges are few enough that gRPC's built-in TLS, deadlines and
retry policy cover it in configuration. A sidecar per pod would roughly double the
container count and add a control plane to operate, in exchange for automating something
that is currently three lines of gRPC channel config.

**Threshold.** Roughly ten or more services, *or* more than two implementation languages
in the service tier — that is the point at which "every service implements retries
correctly" stops being true and the cross-cutting concern needs to leave application code.
Also earlier if a compliance requirement demands mTLS everywhere with rotating identities;
that is a hard requirement rather than a scaling one.

---

### Feature store (Feast, Tecton, or DoorDash's own multi-tier store)

**What it is for.** The real problem it solves is **training/serving skew**: a feature
computed one way in an offline training pipeline and another way in the online serving
path produces a model that quietly underperforms in production, and the discrepancy is
extremely hard to find. A feature store makes both paths read the same definition. The
multi-tier part (Redis in front of a columnar store) exists for p99 latency at very high
QPS.

**Why not here.** There is no model in production. There is no production. The ETA and
forecasting work is offline against simulator output, where training and serving are the
same process reading the same code, so the skew the feature store prevents cannot occur.
Adopting one now would mean maintaining feature definitions for features nothing serves.

**Threshold.** Two conditions, and **the first one alone is enough**: (a) the same feature
is computed in two places — an offline training job and an online request path — because
that is when skew becomes possible and nothing else prevents it; or (b) online feature
lookup latency becomes a measurable part of the request budget, which needs high QPS and
is much further away. Before either, the cheap intermediate is a single shared feature
module imported by both paths, which buys most of (a) for none of the operational cost.

---

### Bazel (or any distributed build system)

**What it is for.** Hermetic, reproducible, cached builds across a large polyglot
monorepo, with remote execution so a change rebuilds only its transitive dependents.
DoorDash gets real value from this: thousands of targets, many languages, hundreds of
engineers.

**Why not here.** The repository is ~7,500 lines of Swift in one SwiftPM target. A clean
build is seconds; the full test suite is under 20 seconds. Bazel would replace two
first-class, well-understood toolchains (SwiftPM and Gradle) with a third that has to be
taught about both, and Swift/iOS support via `rules_swift` is workable but not the
best-supported path in the ecosystem. The cost is paid every day by the only engineer;
the benefit arrives at a scale this repo will not reach.

Note that the **monorepo** idea is separately correct and is being adopted — one repo for
the iOS apps, the Kotlin services, the Python ML layer and the protobuf contracts, so a
contract change and its consumers land in one commit. Monorepo and distributed build
system are independent decisions that get conflated; SwiftPM, Gradle and a Makefile are a
perfectly good monorepo build until they are not.

**Threshold.** Full CI wall-clock consistently over about 15 minutes with no cheaper fix
left (caching, test sharding, only building changed targets), *or* more than three
language toolchains needing to share generated artefacts. Current CI: five jobs, minutes.

---

## Also rejected, more briefly

| Technology | Why not | Threshold |
|---|---|---|
| **Cadence / Temporal** | `pg_cron` plus idempotent workers covers the current escalation ladder — three timers and a rate limit, already written | When the checkout saga has more than a handful of compensating steps, or workflows must survive for days |
| **Three-tier entity cache** | Premature by several orders of magnitude; Postgres serves every read from buffer cache at this volume | When read QPS makes replica lag or p99 a product problem |
| **Kubernetes** | Four services do not need an orchestrator; a container host is enough | Multi-service autoscaling, or more than a couple of environments to keep identical |
| **GraphQL** | Three first-party clients built by one person; a typed generated client already exists and there is no over-fetching problem to solve | Third-party or many-team clients with divergent data needs |

## Consequences

**Good.** Every piece of infrastructure in the system is load-bearing. Nothing exists to
look impressive. The system can be explained end to end by the person who built it, which
is a property that quietly disappears the moment you adopt a component you do not
understand the failure modes of.

**Costs.** Several of these decisions will need revisiting, and revisiting is not free —
migrating to Kafka later is more work than starting on it, and the same is true of a
feature store. That cost is accepted knowingly: it is paid *if and when* the threshold
arrives, rather than certainly and immediately. For a system with one engineer and no
users, deferred work that may never be needed is strictly cheaper than work done now.

**The real risk** is that a threshold is crossed without anyone noticing, because nothing
measures these. Poll load, CI wall-clock and write throughput are not currently
instrumented. Writing the thresholds down is the cheap half; alerting on them is not done.
