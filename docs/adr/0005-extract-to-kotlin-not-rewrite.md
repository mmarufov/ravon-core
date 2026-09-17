# 0005 — Extract a Kotlin service tier; do not rewrite the backend

**Status:** Proposed · 2026-09-16 — **nothing in this ADR is built.** There is no
`services/` directory in this repo.
**Scope:** whole-system

## Context

Three things are wrong with where the logic currently lives, and they are different
problems.

**1. Dispatch is in a client package.** `Sources/RavonCore/Dispatch/` — the matcher, the
cost model, the simulator — ships inside the Swift package the three iOS apps embed. A
courier's phone cannot see the other couriers. Minimum-cost matching over a fleet is
meaningless without the fleet. It is there because that is where it could be built and
measured, and it is a layering error stated plainly.

**2. The order lifecycle is 13 `SECURITY DEFINER` SQL functions.** They are a second
codebase: no type relationship to the Swift clients, no unit-test harness, no way to
assert a property over the whole graph. [ADR 0001](0001-order-lifecycle-as-declared-data.md)
declares the lifecycle as data in Swift, but the *database* still enforces its own copy.
They agree today because a human checked.

**3. There is no backend at all.** The Supabase project was deleted: the host returns
NXDOMAIN and the Management API returns 404 "Resource has been removed" for the project
ref. Which means this is a **rebuild, not a migration** — there is no dual-write, no
shadow-read, no cutover risk. It is the cheapest possible moment to change architecture,
and that is the actual reason the decision is being made now.

An audit of the migrations and Swift call sites found 34 SQL functions, 4 triggers, 3
`pg_cron` jobs, 21 RPCs called from Swift, and 15 tables touched by Swift — of which
**only one was ever created by a migration**. Three RPCs the clients call
(`get_merchant_stats`, `find_nearby_couriers`, `add_tip`) and six Postgres enums exist in
no migration at all; they were created through the dashboard. The migrations are not a
sufficient rebuild source. The Swift models are an independent second record, which is
why `scripts/schema_drift.py` cross-references the two.

## Decision

Extract the concerns that need **global server-side state or transactional integrity**
into Kotlin services behind gRPC. Leave everything else on Supabase, deliberately.

| Concern | Destination | Why |
|---|---|---|
| Dispatch (matching, cost model, simulator) | → Kotlin | Needs the whole fleet; fixes the layering error above |
| Ledger (double-entry, balances, payouts) | → Kotlin | Money needs transactional integrity and testable logic |
| Order state machine / checkout saga | → Kotlin | Replaces 13 untyped, untestable SQL functions |
| Fraud rules | → Kotlin | Config-driven, needs backtest/shadow/live modes |
| Auth, sessions, OTP | **stays Supabase** | Already shipped and working; a rewrite is weeks for zero product value |
| Row-level security | **stays Postgres** | Becomes defence in depth behind the service, not the primary gate. Keeping it is strictly safer |
| CRUD reads (menus, restaurants, addresses, history) | **stays PostgREST** | A generated typed client already exists |
| Realtime subscriptions | **stays Supabase Realtime** | Postgres-CDC websockets are good; rebuilding them is pure cost |
| ETA, forecasting, anomaly detection | → Python | The right tool, and the one the reference architecture uses |

**Strangler fig, in this order**, chosen by risk:

- **Phase 0** — restructure only, no new behaviour. One repo, `proto/` with a CI
  compatibility gate, thin app wrappers. Ends with everything still working.
- **Phase 1** — `services/dispatch`. First because it has **no database writes**, so
  there is no auth or RLS interaction to get wrong. Port the matcher, cost model and
  simulator; expose one `Assign` RPC; delete the Swift copy rather than leave it to rot.
- **Phase 2** — `services/ledger`. New surface, no migration risk. First service that
  writes, so the JWT interceptor lands here.
- **Phase 3** — `services/order`. The 13 SQL RPCs become a saga with per-step idempotency
  and compensation to a clean failed state. Highest risk; last; shadowed against the SQL
  path before cutover.

**gRPC Swift 2** on the client side. It is rebuilt on async/await and Swift 6 concurrency,
Apple uses it in first-party services, and there is a public WWDC session building an iOS
app as a gRPC client. Connect-Swift is the fallback if codegen ergonomics get painful —
and because it is wire-compatible, that switch is client-side only.

**Auth across two transports.** The clients hold a Supabase JWT. A Kotlin server
interceptor verifies it against Supabase's JWKS endpoint (keys cached), checks
`iss`/`aud`/`exp`, and takes `sub` as the user id. The service connects to Postgres as its
**own role**, not as the end user, so it can write rows clients cannot. One identity
provider, two transports, no duplicate user table.

## Alternatives considered

**Full rewrite onto Kotlin + Postgres, dropping Supabase.** Cleaner end state, and it
invites the harder question: why did you rewrite working code? Auth, OTP, RLS and realtime
are weeks of work to reimplement with no product improvement. DoorDash's own precedent is
extraction — in 2020 they pulled the consumer checkout flow out of the Python monolith as
one Kotlin service rather than big-banging the monolith. Copying the *migration strategy*
is more faithful than copying the end state.

**Stay entirely on Supabase; write dispatch as a Postgres function.** Keeps one system.
But the matcher in PL/pgSQL is untestable by the existing harness, cannot reuse the
verified Hungarian solver, and grows the untyped SQL codebase that is already problem #2.

**Node/TypeScript instead of Kotlin**, sharing types with a future web client. Reasonable.
Kotlin wins on the JVM's concurrency story for a dispatch tick and on matching the
reference architecture — the decision is partly about what this system is modelled on, and
that is a legitimate reason to state out loud rather than dress up as a technical
inevitability.

## Consequences

**Good.** Dispatch ends up where it can see the fleet. The order lifecycle gets one
implementation instead of two. Money gets a transactional home. Auth, realtime and reads
keep working throughout, because they are never touched.

**Costs, stated plainly.**

- `protoc` enters the iOS build — SwiftPM plugins handle it, but it is new build surface
  and a new CI failure mode.
- A JVM service needs hosting. This is a portfolio system, not a production one; say so.
- **Two transports to reason about** — gRPC for commands, PostgREST and websockets for
  reads and subscriptions. This is what an incremental migration looks like partway
  through. It is not a design smell, but it does need explaining, which is why it is drawn
  explicitly in [the architecture diagram](../architecture.md).
- The simulator follows the dispatcher into Kotlin: ~1,200 lines of Swift ported,
  including the brute-force verification. Mechanical, but a real day or two — and the
  Swift copy must be deleted, not kept.

**Risk.** The rebuild source is incomplete. Reconstructing the schema means unioning the
19 migrations with the Swift models and accepting that some columns are attested by only
one of the two.

## Verification

None. This ADR describes work that has not been done. The status line stays **Proposed**
until `services/` exists and builds.
