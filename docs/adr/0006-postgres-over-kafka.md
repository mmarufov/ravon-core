# 0006 — Implement the event guarantees on Postgres, not on Kafka

**Status:** Accepted · 2026-09-16
**Scope:** `order_status_history`, `pg_cron` jobs, Supabase Realtime; whole-system

## Context

The order lifecycle produces a stream of events: every state transition, who caused it,
when, and what it obliged someone to do. Several consumers want that stream — the courier
app wants live status, the merchant app wants its queue, a future ledger wants a
settlement trigger, and an ops tool wants to reconstruct "what happened to this order?"
after the fact.

That shape — one producer, several independent consumers, replayable history — is the
textbook case for a log. The reference architecture this system is modelled on runs
Kafka, and the obvious move is to copy it.

The question worth asking first is *what Kafka is actually providing*, because the answer
is a list of guarantees, not a piece of infrastructure:

1. **Durability** — an event, once accepted, is not lost.
2. **Ordering** — events for one order are observed in the order they happened.
3. **Replay** — a new consumer can read history from the beginning.
4. **Fan-out** — consumers are independent; a slow one does not block a fast one.
5. **Decoupled throughput** — the producer is not limited by the slowest consumer.

Kafka is one way to get those. It is not the only way, and it is not free: a broker
cluster, ZooKeeper or KRaft, a schema registry to stop producers breaking consumers,
consumer-group rebalancing, partition-key design, and a second place where "the truth"
can live and disagree with the database.

## Decision

**Implement the guarantees on PostgreSQL. Do not run a broker.**

- **Durability and ordering** — `order_status_history` is an append-only table written in
  the same transaction as the state change. Either both happen or neither does. This is
  strictly *better* than a broker for the guarantee that matters most here: with Kafka,
  "row updated" and "event published" are two operations and you need an outbox pattern
  to stop them diverging. Writing the event to the same database removes the failure mode
  rather than mitigating it.
- **Replay** — the table *is* the history. A new consumer reads it with a `SELECT`. There
  is no retention window to expire off the end of.
- **Fan-out** — Supabase Realtime is Postgres change-data-capture over websockets. It
  already delivers order status, courier location and chat to the three apps.
- **Scheduled and delayed work** — `pg_cron`, which already runs the courier escalation
  ladder (every minute), no-show detection (every minute), and the restaurant
  accepting-orders flip (every five minutes).

The general principle, and it is the one worth carrying to other decisions: **name the
guarantee, then choose the cheapest thing that provides it.** "We need a log" is a
conclusion smuggled in as a premise.

## Alternatives considered

**Kafka (or Redpanda) with a proper outbox.** The correct answer at scale, and the
operational cost is real: a cluster to run, a schema registry to maintain, and — the part
that matters most for a system with one engineer — a second source of truth that can
disagree with Postgres. Rejected on the threshold below.

**Cadence / Temporal for the escalation ladder and saga.** Genuinely nice for
long-running workflows with compensation, and the order checkout saga is exactly that
shape. `pg_cron` plus an idempotent worker covers the current ladder, which is three
timers and a rate limit, and the escalation logic is already written and working.
Revisit when the saga has more than a handful of compensating steps.

**Postgres `LISTEN`/`NOTIFY` as the fan-out mechanism.** Considered and partly rejected:
`NOTIFY` is fire-and-forget, so a consumer that is disconnected misses the event with no
way to catch up. It is fine as a wake-up hint on top of a table poll, never as the
delivery guarantee. Supabase Realtime's CDC path is the same idea done properly.

**Redis Streams.** Lighter than Kafka, and it introduces the same fundamental problem —
state that is not in the database and can disagree with it — for a smaller operational
saving.

## Consequences

**Good.** One source of truth. Transactional event emission with no outbox. No broker to
operate, no partition keys to design, no consumer-group rebalance to debug at 2am. Replay
is a `SELECT` any engineer can write. The append-only transition log is also exactly the
substrate an order-timeline debug tool needs.

**Costs, and these are the honest ones.**

- **Consumers share the database's capacity.** A heavy replay competes with live traffic
  for the same buffer cache. Kafka's decoupling is a real property and this gives it up.
- **No native backpressure or per-consumer offset management.** Each consumer must track
  its own cursor, and nothing stops one from falling behind silently.
- **Polling consumers add load proportional to the number of consumers**, not to the
  number of events.
- **Retention is a manual problem.** The history table grows forever until someone
  partitions or archives it. Kafka expires segments for you.

## The threshold at which this flips

State it as a number rather than a feeling.

Dushanbe at an optimistic launch is on the order of 10 orders per minute at peak. An
order produces roughly 15 lifecycle events, so ~2.5 events/second, against a single
PostgreSQL instance that absorbs tens of thousands of small inserts per second. That is
about four orders of magnitude of headroom. Order volume is not what will force this
decision.

The realistic triggers, in the order they are likely to arrive:

1. **More than a handful of independent polling consumers**, at which point poll load
   scales with consumers rather than events and a real pub/sub becomes cheaper than more
   read replicas.
2. **Analytics replay competing with transactional traffic** — the first time a backfill
   makes checkout slow, the log wants to be somewhere else.
3. **Cross-service event flow.** Once [ADR 0005](0005-extract-to-kotlin-not-rewrite.md)
   lands and dispatch, order and ledger are separate services, services sharing one
   database table as a bus is the anti-pattern Kafka exists to fix. That is the decision
   point, and it is architectural rather than throughput-driven.
4. **Sustained event rates above roughly 5,000/second**, or retention requirements that
   make the history table unmanageable to partition.

Until one of those is true, a broker would be infrastructure carrying no load.

## Verification

Partially verifiable. `order_status_history`, the four triggers and the three `pg_cron`
jobs exist in the migrations under `.context/migrations/` and were running against the
Supabase project before it was deleted; **there is no live system to observe today**. The
throughput figures above are arithmetic, not a benchmark, and are labelled as such.
