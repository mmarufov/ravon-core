# Kotlin backend — the plan

**Status:** planning only. No service code written. 2026-09-16.
**Brief:** `.context/PROMPT-kotlin-backend.md`. **Evidence:** `.context/research/` (15 documents, ~13121 lines, every claim cited to file:line), plus two generated fixtures: `dispatch-baseline-seeds-1-30.json` and `dispatch-rng-golden-vectors.json`. The orchestrator's own first-hand checks are in `.context/research/orchestrator-verification-log.md`.

This plan disagrees with the brief in several places. Each disagreement is stated where it lands, with the evidence, and collected in §0 so nothing is buried.

---

## 0. What the brief got wrong, and what changes because of it

The brief asked to be checked. It was. Fourteen claims were verified first-hand; seven are wrong or materially incomplete, and the research surfaced twelve things the brief does not know about. The ones that change the plan:

| # | Brief says | Reality | Changes |
|---|---|---|---|
| 0.1 | "163 passing tests and CI with 5 jobs" — assets you must not break | The tests pass. **Everything else is untracked.** `Dispatch/`, `OrderLifecycle.swift`, 5 test files (40 of the 163 tests), `scripts/`, `.github/` — all `??` in `git status`, 0 commits ahead of `origin/main`, **0 workflows registered on GitHub, CI has never run.** | Phase 0 step 1 is `git add` + PR. Nothing in this plan is safe until then. This outranks the dangling pin. |
| 0.2 | "Extract, don't rewrite" | **There is nothing to extract from.** The database is gone. Dispatch has zero consumers. `OrderLifecycle` has zero callers. The merchant has zero working RPCs — its four kitchen ops are direct `UPDATE orders` inside RavonCore. Three RPCs exist only as Swift signatures. RLS for 11 of 15 tables is unrecoverable. | This is a **rebuild against a specification**, not a strangler-fig. DoorDash's checkout precedent (extract one flow from a running monolith) does not apply. The plan drops the "shadow it against the SQL path" language — there is no SQL path. |
| 0.3 | Three services: `services/dispatch`, `services/ledger`, `services/order` | `02-TARGET-ARCHITECTURE.md:149` **refuses** Kotlin/gRPC microservices: "team parallelism you don't have." Nothing supersedes it. It is right about the failure mode. | **One deployable, three modules.** See §2. |
| 0.4 | Dispatch is in "the wrong layer" — a courier's phone can't compute a global assignment | True about where the code sits; false about what happens. **No client calls it.** It is a research artifact compiled as dead weight into three binaries. Meanwhile the *real* offer feed is an unfiltered realtime subscription on all of `orders` that shows every courier the same oldest order nationwide and **leaks the pickup and delivery codes** via `select("*")`. | Dispatch still goes first — for a better reason (it has a test oracle). But Phase 1 must also define the offer *projection*, because that leak is the actual dispatch bug. |
| 0.5 | 38 edges, "two entries marked `missingServerSide`" | **36** declared edges; no such marker exists. **5 RPCs across 8 edges** have no server implementation — every merchant edge. And the declared table **drifts from the SQL on 8 more edges** (the escalation ladder's from-set, no-show → `delivered` not cancelled, a missing `delivering → delivered`). Reconciled graph: **41 edges, ~17 guards.** | The Kotlin order module implements the reconciled graph, not the Swift table verbatim. Five merchant RPCs are new work. |
| 0.6 | `ServiceError.from` has zero call sites | **Ten.** 3 in core tests, 7 in app production code (courier 6, consumer 1). It is opt-in per call site, discards every payload field but `reason`, its regex is uppercase-only, and it covers 18 of 29 reason kinds. | Same requirement, honest justification. A reviewer who greps will find "zero" is false and discount the rest. |
| 0.7 | JWKS vs HS256 — "check whether Supabase still exposes a JWKS endpoint" | **ES256, P-256, JWKS live.** Verified on two projects in the account, one created 2026-09-09. The abandoned `Ravon_android/backend/.env.example` asks for `SUPABASE_JWT_SECRET` — the HS256 mistake was already made once. | Interceptor is ECDSA + `kid` selection. Libraries that only do RSA JWKS are disqualified. 20-minute revocation lag is a design input. |
| 0.8 | Consumer's deployment target is 26.2 (implying the others differ) | **All three** are 26.2. `Package.swift` says `.iOS(.v17)`. XcodeGen's stated justification ("would have caught the split") is falsified — there is no app-to-app split. | Drop XcodeGen from Phase 0. Fix the manifest. |
| 0.9 | Merchant is the easiest client to migrate (0 `import Supabase`) | Courier **also** has 0. Both are entirely RavonCore-gated; courier calls exactly 26 `SupabaseService` methods. | Two cheap cutovers, not one. |
| 0.10 | "Landmine: all three apps pin RavonCore to `a1e9d6c8`" | **Confirmed on `origin/main` for all three**, read out of the blobs directly. But the requirement is `kind = branch; branch = "mmarufov/auth-overhaul"` — a **floating branch requirement, not a pin**; `a1e9d6c8` is only what `Package.resolved` remembers, so no app build is reproducible today. Three supabase-swift versions on `origin/main`: 2.41.1 / 2.43.1 / 2.42.0. *(Two research agents reached opposite wrong conclusions here — one "the app code isn't on `main`", the other "the pin is workspace-only, the gate has zero merged consumers" — both from reading `~/conductor/repos/` clones that are 2–5 commits stale. Read app state with `git show origin/main:<path>`.)* | Fix = tag + change `kind = branch` → a version requirement in three `.pbxproj` files. No branch merging. Pin target `2.43.1`. |
| 0.11 | "S1/S2/S3 were never patched" | S1 was patched (mig 19) and **re-opened by mig 18** — `handle_new_user` copies `role` from `raw_user_meta_data`, which `AuthService.swift:63-72` sets client-side. One unauthenticated `POST /auth/v1/signup` = merchant. S2 half-patched against a column (`restaurants.owner_id`) that no migration creates. S3 could not have been patched from this repo (`CREATE OR REPLACE` preserves ACL; zero `REVOKE` anywhere). Twelve further findings, incl. `reassign_ghosted_order(uuid)` with no auth check. | Security is by construction (§9), with a sixth CI job that asserts grants. **The load-bearing primitive is the missing GRANT, not the missing policy.** |
| 0.13 | **`docs/adr/0005-extract-to-kotlin-not-rewrite.md` (written in parallel) repeats the framing §0.4 corrects** — "a courier's phone cannot see the other couriers" as a live layering problem. It is true about where the code sits and false about what happens: nothing calls it. Both documents are now tracked, so they must not silently disagree. | Add one sentence to ADR 0005 citing §0.4, or it is exactly the unenforced-contract failure this plan catalogues. |
| 0.12 | "34 SQL functions, 4 triggers, 3 pg_cron jobs" | 34 ✓, 4 ✓, **5 cron jobs** — `purge_soft_deleted_menu` (inline SQL, no function) and `activate_scheduled_orders` are missing from the inventory. `update_courier_heartbeat` — the hottest write path in the system — is assigned to no service. | Boundary map covers all of it (§3). |

Things the brief does not know about that the plan has to carry: `create_order` has **no idempotency key** (a retried checkout on Dushanbe 3G double-orders); consumer **modifiers are charged and discarded** (`p_items` is `{menu_item_id, quantity}`); **every consumer address has NULL coordinates**; `courier_earnings` is a **mutable current-state row**, not a journal (`ON CONFLICT DO UPDATE` destroys clawback history); earnings "today" is **device-timezone** (a US-based device excludes the first 12 hours of the Dushanbe day); Realtime needs **`REPLICA IDENTITY FULL`** on `orders` and nobody wrote it down; the consumer's Release build ships `API_BASE_URL = http://localhost:8000`; money is `numeric` on the server and `Double` in Swift with three rounding rules across three apps; there is **no payment method on `Order`** in a cash-heavy market; `ravon-core` is public and the three app repos are private.

---

## 1. The reconstructed schema

Per-column detail is in the three source documents; the **reconciliation** — disagreements,
single-source risks, unknowables, and the RLS design — is `.context/research/reconstructed-schema.md`.
**17 tables** are named in the repo: the 15 Swift touches, plus `courier_cancellation_log` (the
only one with complete DDL) and `order_item_modifiers` (dead; migration 02 folded it into
`order_items.modifiers_snapshot` and it has zero call sites — do not carry it forward).

### 1.1 The drift tool cannot see 14 % of the schema. Fix it before trusting it.

`scripts/schema_drift.py` is one of the five CI jobs and the project's declared gate for exactly
this failure class — *"not a compile error and not a test failure — a decode crash in a shipped iOS
app."* It has two measured blind spots:

**Comma-separated `case` lists — 36 of 265 wire keys dropped.** Its `SWIFT_CASE` regex captures
only the first identifier after `case`, and the models use the multi-case form heavily:
`case label, street, apartment, city, latitude, longitude` (`Address.swift:56`) registers as
`label` alone. Measured with a corrected parser: the tool parses **229** keys where **265** exist.
The dropped set includes **`Profile.role`** — the column behind the S1 privilege finding — and
**`MenuItem.price`**, which is money.

**Single-word keys are unreportable by construction.** `sql_identifiers`' regex requires at least
one underscore, and the report filter has `"_" in wire`, so a single-word column can never appear
in the output. After fixing the first bug, five distinct keys are single-word *and* absent from
every migration: `street`, `apartment`, `city`, `phone`, `rating`. `street` and `city` are
non-optional `String` in `Address`, so a mismatch throws the **entire** address fetch.

So **`0 drift, 15 unverified` is a floor, not a count** — the true unverified set is ≥ 20, and the
parse gap means an unknown number of real mismatches are never examined. Both fixes are small and
belong in Phase 0, with a regression test asserting the parser finds all 265 keys. **This also
rewrites Phase 2's exit criterion**: "`schema_drift.py` reports 0 unverified" is worth nothing
until the tool sees the whole schema.

### 1.2 Only two of the six "dashboard-created enums" are enums

`12-BACKEND-INVENTORY.md` is wrong about four of six. Verified: `order_status` (17 values) and
`user_role` (3) are real Postgres enums with **no `CREATE TYPE` anywhere**, so `V1` must author
both. `delivery_mode`, `sender_role` and `courier_earnings.earning_type` (which the doc omits) are
**`text` + CHECK**, not enums. `restaurant_status`'s kind is **UNKNOWN** — no cast, no `ALTER TYPE`,
no CHECK. And **`courier_status` does not exist at all**: it is a client-side computed property
(`CourierStatus.swift:21-24`) with zero wire mapping and zero references in any app.

This changes rebuild cost: a text+CHECK domain is cheap to extend, a Postgres enum is not.
Separately, `orders.cancellation_reason_code` has an **18**-value CHECK and
`CancellationReason.swift` declares the same 18 — an exact match, no drift.

### 1.3 Ten source disagreements; exactly one blocks

Full table in the research doc. The ones that change the DDL:

- **`orders.delivery_address_snapshot` is lossy in the Swift model.** The column is
  `to_jsonb(a.*)` over the whole `addresses` row — 11 fields. `AddressSnapshot` declares 6. Typing
  it as the 6-field shape **discards data already being written.**
- **Two columns are nullable in SQL and non-optional in Swift** — latent decode crashes:
  `courier_locations.last_updated` and `restaurants.delivery_time_min`. Rebuild both
  `NOT NULL DEFAULT`, which satisfies both sources.
- **`restaurants.owner_id` is referenced by five RLS policies and created by no migration.**
  Rebuild it as `NOT NULL REFERENCES profiles(id)` declared in `CREATE TABLE`, so a policy
  referencing a non-existent column becomes impossible.
- **`orders`' `NOT NULL` columns are defensively `COALESCE`d six times** in migrations 13/16 — the
  author did not trust that the constraint had applied, which suggests the live DB had diverged
  from the files. Rebuild with the declared `NOT NULL DEFAULT` and drop the `COALESCE`s so a NULL
  fails loudly.
- **The only blocking disagreement is the radius** (8 / 10 / 50 km) — a product decision, asked in
  the courier prompt, not a reconstruction failure.

### 1.4 Four tables exist only because Swift decodes them

`modifier_groups`, `modifier_options`, `menu_item_modifier_groups` and `order_status_history` have
**zero SQL evidence** anywhere. They are not optional: the modifier tables are how the consumer's
charged-and-discarded modifier feature is meant to work, and `order_status_history` is the audit
trail the state machine appends to. Every column in them is single-source and hard-decoded.

Also: four columns have **no CHECK** where Swift has a domain
(`orders.courier_delay_reason_code`, `courier_earnings.cancellation_reason_code`,
`courier_earnings.tier_pct` — whose domain is documented only in a migration comment —
`courier_cancellation_log.reason_code`). The database accepts values the client cannot decode. All
become CHECKs.

### 1.5 RLS is designed, not reconstructed

Only four tables have policies in any migration. The other eleven are **unrecoverable from any
source** — a Swift call site records what the client issued, never what the server permitted. This
is a harder gap than the column gap and the brief does not name it.

It also makes the plan's goal free: "no client write policies on `orders`" requires removing
nothing, only never creating it. The design rules are in §9; the one that must be said explicitly
is that **"RLS becomes defence-in-depth" is scoped to the five Kotlin-written tables only.** For
`addresses`, `chat_messages` and `profiles` RLS remains the primary gate — and two existing core
queries have no ownership predicate at all (`SupabaseService.swift:267`, `:1084`), so treating
their policies as optional turns them into open endpoints.

### 1.6 `V1__baseline.sql` is the largest unscoped item in the corpus

Neither `10-POLYGLOT-RESTRUCTURE.md` nor `migrations/README.md` mentions it, yet a checksummed
runner needs a `V1` that creates the world and only 1 of 17 tables has DDL today. Contents:
two `CREATE TYPE`s, 16 `CREATE TABLE`s with money as `bigint` minor units and `total_minor`
generated, the four text+CHECK domains, foreign keys (some provable only from PostgREST embed
syntax), the call-site-implied indexes, `app.order_transitions` seeded with the 41 edges, the
grant baseline, RLS, `REPLICA IDENTITY FULL` on `orders`, the realtime publication over exactly
five tables, and `schema/invariants.sql`.

### 1.7 Eight things are permanently unknowable

Every RLS policy's text; whether `restaurants.owner_id` ever existed; the definitions of six
referenced-but-absent functions; `generate_verification_code`'s trigger binding (migration 10
replaces the body and says "update the existing trigger", but no migration ever issues
`CREATE TRIGGER`); whether `ALTER DEFAULT PRIVILEGES … GRANT ALL ON FUNCTIONS TO anon` was in
effect; whether `orders.user_id` was `NOT NULL`; `restaurant_status`'s kind; and PostgREST's
`max-rows`. Each needs an explicit decision. None may be filled in from memory.

---

## 2. Architecture: one deployable, three modules

### 2.1 Resolving the contradiction the docs left open

`02-TARGET-ARCHITECTURE.md` refuses Kotlin/gRPC: *"Supabase Postgres + RPCs is the right backend for one developer. Microservices trade simplicity for team parallelism you don't have."* `10`/`11` adopt four Kotlin services and never cite `02`. `README.md` and `CLAUDE.md` are on `02`'s side ("authorization lives in Postgres"). The brief inherits `11` and says don't re-litigate.

Both are half right, and the research settles which half.

`02` is right about the failure mode: a solo developer cannot run four deployables. It is wrong about the remedy. The 19 migrations are the evidence: business logic in SQL is *why* the merchant has no RPCs (four kitchen ops became direct `UPDATE`s because writing SQL functions is painful), *why* the lifecycle table drifts from the ladder on 8 edges (nobody can test a `pg_cron` function), *why* `create_order` has no idempotency key, and *why* a security fix in migration 19 was undone by a trigger in migration 18 — the same PR. "Supabase RPCs are the right backend" produced an untestable second codebase that the schema-drift tool cannot fully see. That is not a scale problem; it is a correctness problem, and it is the one this project's own thesis names: *every fleet bug is an unenforced contract.*

`11` is right that the fix is typed, testable code behind a contract. It is wrong that the unit is "services." DoorDash's checkout extraction was **one** service.

**Decision: one Kotlin deployable (`ravon-api`), three Gradle modules (`dispatch`, `order`, `ledger`) plus `common` (proto, auth, db).** One process, one connection pool, one JWT interceptor, one container, one deploy, one set of logs. Module boundaries are enforced by Gradle `api`/`implementation` visibility and an ArchUnit rule — a compile error, not a network hop. The proto packages are already per-module, so if a module ever needs its own process, the contract is unchanged and the split is a deployment change. Until then, "microservices" is a directory layout.

This satisfies `02`'s objection (one operational surface) and `11`'s goal (typed logic). It is the honest solo-dev shape, and it is a stronger position than either document took. `02`'s Refuse table gets a superseded-by banner pointing here.

### 2.2 What stays on Supabase, and why RLS is demoted only for five tables

| Concern | Where | Why |
|---|---|---|
| Auth, sessions, OTP, password recovery | Supabase | `RavonAuthFlow` is shipped and works. Rewriting it is weeks with zero product value. The Kotlin side *consumes* the JWT; it never mints one. |
| Reads: restaurants, menus, hours, modifiers, addresses, profiles, order history | PostgREST via `api` schema | A typed client exists. Moving reads buys nothing and adds a hop. |
| Realtime: order status, chat, courier location, menu availability, restaurant status | Supabase Realtime | 8 channels, 5 tables. Genuinely good; rebuilding is pure cost. Requires `REPLICA IDENTITY FULL` on `orders` — now written down. |
| **Writes to `orders`, `order_items`, `order_status_history`, `courier_earnings`, ledger tables** | **Kotlin only** | Clients hold **no** INSERT/UPDATE/DELETE grant on these. Not "no policy" — no grant. RLS governs reads only. |
| Writes to `addresses`, `chat_messages`, `profiles` (non-role columns) | Client via PostgREST, RLS-primary | These are per-user rows with no cross-entity invariant. The consumer report is explicit: "RLS becomes defence-in-depth" must be scoped to `orders`, or `addresses`/`chat_messages` become open endpoints. Two existing queries have no ownership predicate at all (`SupabaseService.swift:267, :1084`) — fixed in Phase 0. |
| **Ledger schema, balance invariant, crash-injection proofs** | **`db/ledger/` — built by a separate agent: plain SQL + Python/Hypothesis harness + its own CI job** | Coordination note from the orchestrating chat (`.context/NOTE-for-kotlin-chat.md`). The Kotlin `ledger` module **wraps `ledger_post(...)`** and never touches `ledger_entries` directly — the whole point is that only the database can enforce the balance invariant. Interface contract in §7 Phase 3; `db/ledger/HANDOFF-for-kotlin.md` is the dependency. |
| `pg_cron` sweeps | Postgres, as `ravon_cron` role | `02` is right and `12` is wrong: nothing forces these out. They lose their client `GRANT EXECUTE` (the ladder calls `reassign_ghosted_order`, which has no auth check). See §3. |
| Triggers that must be atomic with Supabase-owned tables | SQL | `handle_new_user` stays — but stops reading `role` from metadata. |

The phrase "RLS becomes defence-in-depth" in the brief and `11` is too broad. It is true for exactly the five transactional tables the Kotlin role writes. For everything else RLS remains the primary gate, and the design must say so or someone will treat a policy on `addresses` as optional.

### 2.3 Where the code lives

**Not a monorepo of the apps. Not yet, and possibly never.**

`10` says "one repo" and `11`/the brief say "do not skip Phase 0." The research shows the monorepo *mechanism* is unspecified (no `subtree`/`filter-repo` decision, no history policy), the apps' code is not on `main`, four repos have mixed visibility, and the docs disagree with each other about what Phase 0 even contains. Doing a four-repo history merge while also fixing branches and pins is too much irreversible change at once, for one person, with no CI having ever run.

The *outcome* Phase 0 must deliver is: no dangling pin, one SDK version, reproducible app builds. Tags + a CI assertion deliver that. A monorepo is one way to make it structurally impossible; it is not the only way, and it is the expensive one.

**Decision:** the Kotlin backend and `proto/` live in **`ravon-core`** (`services/`, `proto/`, `db/`), next to the Swift package that consumes the generated client. One CI, one `buf breaking` baseline, one place. The three apps stay in their repos, pinned to **tags** of `ravon-core`. `ravon-core` is already public; the Kotlin source being public is fine — the security model is grants, not obscurity (§9), and no secret ever enters the repo (`scan_secrets.py` gains the `sb_secret_` pattern). The apps stay private. No visibility change.

Revisit after Phase 1 proves the toolchain. If tags + CI hold the fleet together for two phases, the monorepo was never needed.

---

## 3. Service boundary map

Full table for all 34 functions, the 5 cron jobs, the 3 dashboard-only RPCs and the 5 phantom
merchant RPCs: `.context/research/service-boundaries.md`. Five of the inventory's decisions are
overturned. The load-bearing conclusions:

### 3.1 `orders` has 17 writers, and that decides the architecture

17 of the 34 functions write `orders`, plus the 5 direct client `UPDATE`s inside RavonCore. Four of
those writers are `pg_cron` sweeps that should stay in SQL (§3.3), and they perform legitimate
system-actor transitions the 41-edge graph declares. So "the order module owns `orders`" is not
achievable. Instead:

> **One validated entry point — `app.order_transition(...)` — and the transition table lives in the
> database.** Both the Kotlin order module and the SQL sweeps call it. It looks up `(from, to, actor)`
> in `app.order_transitions`, a real table seeded from the 41-edge graph, rejects any undeclared
> edge, evaluates guards, writes `orders`, and appends `order_status_history`. `ravon_app` holds
> **no direct `UPDATE` on `orders.status`**.

This is better than holding the state machine in Kotlin alone, and it is what the project's own
standard demands. A Kotlin table can be bypassed by a cron sweep; a database table cannot be
bypassed by anyone. It also gives the port a free conformance test — assert the Kotlin table and
`app.order_transitions` hold the same 41 rows — which is exactly the check that would have caught
the 8-edge drift between `OrderLifecycle.swift` and migrations 13/14/16.

### 3.2 `update_courier_heartbeat`: split three ways, and delete its `orders` write

The inventory assigns it nowhere. It is the hottest write path in the system, and it writes
`orders.eta_minutes` for every active delivery — which fires the unfiltered `available-orders`
realtime channel, which makes every idle courier re-scan `orders`. Roughly **A × C / 5 full-table
selects per second.**

- **Position ingest → stays in SQL, client-called.** A per-courier row with no cross-entity
  invariant. Routing a 5-second ping through a Kotlin unary call adds a hop, a JWT verification and
  a JVM wake-up for zero correctness gain.
- **The `orders.eta_minutes` write → deleted.** ETA is a pure function of position and order
  (`compute_eta_minutes` is `STABLE`) — compute it on read as a projection field, or let dispatch
  push it on its own cadence. This one deletion removes the amplification.
- **Suspension enforcement → the interceptor**, which already reloads authorization state per call
  because JWT revocation lags 20 minutes (§5.3).

### 3.3 The `pg_cron` sweeps stay, which deletes a phase

The inventory proposes "Kotlin scheduled workers, replacing `pg_cron`." `02-TARGET-ARCHITECTURE.md:151`
says *"`pg_cron` already does the job."* **`02` is right.** All five jobs are pure SQL; two use
`FOR UPDATE SKIP LOCKED`, and reimplementing that in Kotlin means accepting duplicate concurrent
runs or adding leader election — new failure modes for nothing. A Kotlin scheduler also adds a
second reason for the sweeps to stop, whereas `pg_cron` stops only when Postgres does, and then
nothing works anyway.

What must change is not the scheduling. **Three of the five are granted to `authenticated` today —
any signed-in user can trigger a market-wide sweep.** They move to a dedicated `ravon_cron` role
outside the PostgREST-exposed schema. That is a grant change, not a rewrite. Their `orders` writes
go through `order_transition` and their money writes through `ledger_post`.

### 3.4 No `services/merchant`

Proposed for three functions. All three leave: `set_accepting_orders` stays in SQL (restaurant
config, owner-checked, two statements); `get_merchant_stats` is a read model on `order`; and
`courier_report_restaurant_delay` is a **courier** action that transitions order state and posts a
50 % earning — calling it "merchant" was a naming error. A module for three functions, one
misclassified and one that should not move, is a directory, not a boundary.

### 3.5 Three functions are deleted outright

`fetch_available_orders` (zero callers, and `RETURNS SETOF orders` leaks both verification codes),
`find_nearby_couriers` (unauthenticated; courier discovery is now dispatch's internal concern, not
a client RPC), and `insert_courier_earning_for_cancel` (its `ON CONFLICT DO UPDATE` destroys
clawback history and it takes an unbounded tier override). No client breaks on any of the three.

### 3.6 Every shared table's write ownership is resolved by column-level grants

`courier_locations` is the interesting one: the client writes the position columns and `ravon_app`
writes `current_order_id`. Disjoint sets, enforced by Postgres rather than by convention. Full
matrix in the research doc — `courier_earnings` is retired entirely (it is current-state, not a
journal), and `profiles.role` has **no writer at all** outside an operator path.

**Net: 13 functions stay in SQL (not the inventory's 6, which listed 8), 11 of them losing their
client `GRANT EXECUTE`; 3 are deleted; 5 are new.**

---

## 4. The `proto/` contract

### 4.1 Layout and versioning

```
proto/
  buf.yaml                        # v2
  buf.gen.yaml                    # kotlin + swift outputs
  ravon/common/v1/money.proto     # Money, Currency
  ravon/common/v1/error.proto     # Reason enum (the 29 kinds), ErrorDetail
  ravon/common/v1/order_status.proto   # OrderStatus, OrderActor, DeliveryMode, CancellationReason
  ravon/dispatch/v1/dispatch.proto
  ravon/order/v1/order.proto
  ravon/ledger/v1/ledger.proto
```

Shared enums live in `common/v1` because `OrderStatus` is used by two modules and duplicating a
17-value enum is how the 8-edge drift happened in Swift. Naming follows the protobuf convention:
`ORDER_STATUS_UNSPECIFIED = 0`, then the 17 states; `CANCELLATION_REASON_UNSPECIFIED = 0` then the
18 values (which match `CancellationReason.swift` exactly — §1.2).

**`v1` → `v2` rule:** never, unless a field's *meaning* changes. Adding fields, adding RPCs and
adding enum values are all non-breaking and stay in `v1`. This matters more here than in a normal
service: **shipped iOS apps have no forced-upgrade mechanism**, so the day a `v2` exists, `v1` must
be served forever alongside it. The gate in §4.3 exists to make that day never arrive by accident.

### 4.2 The four decisions that are easy to get wrong

**Money is `int64` minor units. Not `double`, not `google.type.Money`.**

```proto
message Money {
  int64 minor = 1;            // diram; 100 = 1 somoni
  string currency_code = 2;   // always "TJS"
}
```

The merchant research supplies the argument, and it is not a preference — **the current `Double`
path silently destroys stored money.** `MenuItemEditView.swift:27` seeds the price field with
`String(Int(item.price))`, and `:135` sends it back unconditionally, so an item stored at `99.50`
becomes `99.00` the moment a merchant opens the edit sheet to toggle availability and saves. The
`.numberPad` keyboard (15 sites, zero `.decimalPad`) means they cannot type the 50 diram back.
`google.type.Money` loses because its `units`/`nanos` split invites exactly the same rounding
divergence the fleet already has three versions of.

**One rounding rule, and it is the consumer's:** integer when the value is whole, else two
decimals. Formatting stays on the client; the wire carries minor units only.

**Timestamps are `google.protobuf.Timestamp`, and the day boundary is server-side.**
Asia/Dushanbe, UTC+5, no DST. The courier app currently computes "today" with `Calendar.current`,
so a device in America/Los_Angeles excludes the first twelve hours of the Dushanbe business day —
and the period boundary is entirely client-supplied today (`fetchEarnings` sends a client-computed
`gte`). The ledger's `GetEarnings` computes the boundary itself. No client chooses its own day.

**Typed errors: `google.rpc.Status` + `ErrorInfo`.**

```proto
// ErrorInfo.reason = one of the 29 Reason enum values
// ErrorInfo.domain = "ravon.dev"
// ErrorInfo.metadata = the structured fields: status, order_id, need, until,
//                      recent_cancels, menu_item_id, have, accuracy, code, max, subtotal
```

The metadata map is the whole point. The existing Swift decoder extracts `reason` with a regex and
**discards every sibling key**, fabricating placeholders (`courierCancelCooldown(recentCancels: 3)`,
`accuracyTooLow(meters: 0)`). So the consumer's reasonable ask — "tell me the tip cap so I can show
it" — is unimplementable today. Status-code mapping:

| Class | gRPC code | Reasons |
|---|---|---|
| authorization | `PERMISSION_DENIED` | `UNAUTHORIZED` (13 sites), `ROLE_CHANGE_FORBIDDEN`, `COURIER_EXCLUDED_FROM_ORDER` |
| state-machine refusal | `FAILED_PRECONDITION` | `INVALID_STATUS_TRANSITION` (10), `ORDER_ALREADY_TERMINAL`, `ORDER_NO_LONGER_PICKUPABLE`, `CANNOT_CANCEL_POST_PICKUP`, `RESTAURANT_CLOSED`, `RESTAURANT_PAUSED`, `RESTAURANT_NOT_ACCEPTING`, `OUT_OF_HOURS`, `OVERLOADED`, `COURIER_MUST_BE_ONLINE`, `COURIER_SUSPENDED`, `COURIER_ALREADY_HAS_ACTIVE_ORDER`, `COURIER_CANCEL_COOLDOWN`, `ITEM_UNAVAILABLE`, `INSUFFICIENT_STOCK`, `MIN_ORDER_NOT_MET`, `MISSING_PROOF_IMAGE`, `TIP_WINDOW_CLOSED` |
| bad input | `INVALID_ARGUMENT` | `INVALID_REASON_CODE`, `INVALID_EXTRA_MINUTES`, `INVALID_VERIFICATION_CODE`, `WRONG_DELIVERY_CODE`, `SCHEDULED_TIME_INVALID`, `ACCURACY_TOO_LOW`, `INVALID_TIP_AMOUNT` |
| lookup | `NOT_FOUND` | `ORDER_NOT_FOUND` (7), **and the restaurant-row-missing case** |
| unauthenticated | `UNAUTHENTICATED` | `NOT_AUTHENTICATED` |
| idempotency conflict | `ALREADY_EXISTS` | same key, different payload |

Three cleanups the SQL surface needs on the way in. `CANCEL_AFTER_PICKUP_NOT_ALLOWED` and
`CANNOT_CANCEL_POST_PICKUP` are two spellings of one condition — collapse them.
**`RESTAURANT_CLOSED` has three distinct causes, not two**: row-not-found and `status = 'closed'`
are conflated at `04:153-157`, and any other non-`active` status raises it again at `:162-165` — so
that is a three-way split, with the first becoming `NOT_FOUND`. And the two tip reasons
(`INVALID_TIP_AMOUNT`, `TIP_WINDOW_CLOSED`) plus `INSUFFICIENT_STOCK` must be added: the existing
Swift decoder covers only 18 of the 29, is **uppercase-only by regex**, and the migration-20 tip
design uses lowercase codes that therefore cannot parse. **Pin one SCREAMING_SNAKE vocabulary.**

**Idempotency key is a request field, not metadata.** `string idempotency_key = N` on every
mutating request. A field is in the proto, so it is in the generated type, so the compiler asks for
it; metadata is a stringly-typed side channel that is easy to forget and invisible in the contract.
The server stores `(key, request_hash, response)`; same key + same hash replays the stored
response, same key + different hash returns `ALREADY_EXISTS`. Clients retry `UNAVAILABLE`,
`DEADLINE_EXCEEDED` and `INTERNAL` only — never `INVALID_ARGUMENT`, `ALREADY_EXISTS` or
`FAILED_PRECONDITION`. This is what `create_order` has never had, and a retried checkout on a
throttled 3G link currently creates a second order.

**Custom `ServiceOptions` for client reliability config: no.** Doc 10 proposes declaring timeouts
and retry policy in the `.proto` and reading them by reflection. That is a real DoorDash pattern
and it is premature for one service whose three clients share one Swift wrapper — the timeouts live
in that wrapper, in one place, already. Revisit if a second client language appears.

### 4.3 The CI compatibility gate

`buf` **v1.73.0**, `bufbuild/buf-action` **v1.5.0** (both checked live 2026-09-16 — re-verify the
CLI invocation against current docs rather than copying a command from memory).

`buf lint` plus `buf breaking --against '.git#branch=main,subdir=proto'`. The baseline is the
`main` branch in this repo, not a BSR module or a checked-in image: one repo, one source of truth,
no extra hosted dependency, and the diff is reviewable in the PR that causes it.

Must **reject**: renumbering a field, deleting a field, changing a field's type, renaming an enum
value, deleting an RPC, changing an RPC's request or response type, moving a message between
packages. Must **allow**: adding a field, adding an RPC, adding an enum value, adding a message,
marking anything `deprecated`, and editing comments.

**Prove the gate works by making it fail on purpose.** Phase 1 opens a throwaway PR that renumbers
one field, watches the job go red, and links that PR from the ADR. A gate nobody has seen fail is
a gate nobody should trust — and this repo has a CI suite that has **never executed at all**, which
is exactly how that happens.

### 4.4 Connect-Swift inside RavonCore

**Generated Swift is checked in**, under `Sources/RavonCore/Generated/`, and regenerated by a
`make proto` target that CI verifies is clean (`git diff --exit-code` after regeneration). Reasons:
`protoc` never enters three Xcode builds; the generated code is reviewable in the PR that changes
the contract; and a contributor without `buf` installed can still build the package.

*A correction to the brief's stated reason:* it justifies this partly with "one is a
hand-maintained `.pbxproj`." **None of the three is.** All three projects are `objectVersion = 77`
with `PBXFileSystemSynchronizedRootGroup` and exactly three `PBXBuildFile` entries — framework
links, not sources — so adding a `.swift` file needs **zero** `.pbxproj` edits. The real constraint
is better: each app links exactly **one** SwiftPM product, `RavonCore`. Adding a second requires a
reviewable `.pbxproj` edit in three repos, and *that* is the mechanism enforcing "the apps never
import Connect."

RavonCore wraps the generated client so the apps see only its existing API shape. That wrapping is
also where the seam goes — and there is no seam today: `grep` finds **zero** protocol declarations
in `Sources/` and **zero** test files referencing `SupabaseService`, `URLSession` or any mock.
`SupabaseService.swift:134` resolves its client from the global `AuthService.shared`. So the 163
existing tests need no mocks and keep passing untouched; the work is *creating* the injection point
for the new tests, not retrofitting one. Connect generates protocol-conforming mocks, which is what
the new tests use.

---

## 5. Auth: one identity, two transports

### 5.1 Resolved: ES256 over JWKS

Verified live, not from docs. `GET https://<ref>.supabase.co/auth/v1/.well-known/jwks.json` on both projects in the account returns

```json
{"keys":[{"alg":"ES256","crv":"P-256","kty":"EC","use":"sig","key_ops":["verify"],"kid":"75c79453-…","x":"…","y":"…"}]}
```

`toj-staging` was created 2026-09-09. This is what a fresh Ravon project gets. The legacy HS256 shared secret is *not* what user access tokens are signed with — the static `anon` key being an HS256 JWT is a separate, older mechanism and must not be used to infer the user-token algorithm (the consumer research made exactly this mistake and caught itself).

### 5.2 The interceptor

Client side: `AuthService.shared.supabaseClient.auth.session.accessToken` goes out as `Authorization: Bearer <jwt>` on every Connect call. RavonCore owns this; the apps never touch it.

Server side, one gRPC `ServerInterceptor` in `common/auth`:

1. Read `authorization` metadata. Missing → `UNAUTHENTICATED`.
2. Parse the JWS header; require `alg == ES256` (reject `none`, reject HS256 — an attacker who obtains the public key could otherwise forge an HMAC with it).
3. Select the key by `kid` from a cached JWK set (Nimbus `JWKSourceBuilder` with a 10-minute refresh and rate-limited retrieval; see §6 for library choice). Unknown `kid` → force one refresh, then `UNAUTHENTICATED`.
4. Verify signature. Check `iss == https://<ref>.supabase.co/auth/v1`, `aud` contains `authenticated`, `exp` in the future with 30 s leeway.
5. Extract `sub` as `UserId`. **Extract nothing else.** The `Principal` type has no `role` field. Role, suspension, and ownership are loaded from the database on every privileged call. This is rule R18 in `security-by-construction.md` and it exists because the JWT's `user_metadata` claim is user-writable via `PUT /auth/v1/user`.
6. Put `Principal(userId)` in the coroutine context. Handlers that need a role call `RoleRepository.load(userId)`; handlers that need ownership call `requireRestaurantOwnership(principal, restaurantId): OwnedRestaurantId` and every merchant repository method accepts only `OwnedRestaurantId`, never a bare `UUID`. A forgotten ownership check is a compile error.

### 5.3 The 20-minute window, stated as accepted risk with a mitigation

Supabase's JWKS is cached 10 minutes at their edge plus up to 10 minutes in clients. Supabase's own products bypass this cache; a self-verifying backend does not. So after a key revocation, a token signed with the revoked key remains valid to the Kotlin service for up to ~20 minutes.

Mitigation, in order: (a) access tokens are already short-lived (Supabase default 1 h); (b) every privileged call reloads authorization state from the database, so a *suspended* courier is stopped on the next call regardless of token validity; (c) an operator endpoint `POST /admin/jwks/refresh` forces a cache drop for the incident case. What is *not* mitigated: a token whose signing key was revoked but whose `sub` is not otherwise disabled. Accepted — this is the same window Supabase documents for any external verifier.

### 5.4 The database role

The service connects as `ravon_app` — a Postgres role, not the `service_role` JWT and not an `sb_secret_` key through PostgREST. A bearer key bypasses RLS wholesale, has no column granularity, and a log line is a full compromise. A role gets column-level grants, `pg_hba` network pinning, and a connection limit. The full grant list is in §9.

---

## 6. The Kotlin stack

Boring, well-documented, actively maintained. Versions checked live 2026-09-16 against the GitHub
releases API and Maven Central — pin these, and re-check at implementation time rather than
trusting this table's age.

| Concern | Choice | Version | Runner-up, and why it lost |
|---|---|---|---|
| Build | Gradle Kotlin DSL | 9.x | Maven — the protobuf codegen plugin story is worse and `buf` integration is a custom exec either way. Amper is too young for a foundation. |
| Server | **Armeria** `GrpcService` | **1.41.1** (2026-09-01) | See §6.1 — this is the load-bearing choice. |
| Service stubs | grpc-kotlin coroutine stubs, hosted by Armeria | **1.5.0** | Plain grpc-java: no coroutines, and the order saga is coroutine-shaped. Caveat in §6.1. |
| DB access | **jOOQ** | **3.21.8** | Exposed and JDBI both fine, but jOOQ's generated types turn a column rename into a compile error, which is this project's whole thesis. It also does not fight explicit transactions or `SELECT … FOR UPDATE`, which `create_order` needs. Codegen runs against a Testcontainers Postgres that Flyway has migrated — verify that is still the documented approach when you get there. |
| Migrations | **Flyway** | **13.7.0** | Owns `app` and `api` **exclusively**; Supabase CLI owns nothing there. See risk 4. |
| Tests | **Kotest** + Testcontainers | **6.2.5** / **2.0.5** | JUnit 5 is the safer default, but `kotest-property` is needed for the 17 lifecycle invariants and the money-conservation proofs, and running two frameworks is worse than picking the one that does both. |
| JWT | **nimbus-jose-jwt** | **10.3** | auth0 `java-jwt` + `jwks-rsa` is disqualified: RSA-oriented, and Supabase signs **ES256**. See §6.2. |
| Proto tooling | `buf` CLI + `buf-action` | **1.73.0** / **1.5.0** | — |
| iOS client | Connect-Swift | **1.2.3** | See §4. |

### 6.1 Armeria, and why the transport choice is settled by two facts

The apps use **Connect-Swift**, so the question is what a JVM server must speak to satisfy it
without a proxy. Two verified facts settle it:

- **Connect-Swift supports the Connect, gRPC and gRPC-Web protocols** — but `.grpc` "requires
  including `ConnectNIO` and swapping out the HTTP client," whereas `.connect` and `.grpcWeb` work
  with the stock `URLSessionHTTPClient`.
- **Armeria's `GrpcService` serves gRPC, gRPC-Web and Protobuf-JSON by default.** It does *not*
  speak the Connect protocol.

So the pairing is **Armeria serving gRPC-Web, Connect-Swift configured `networkProtocol: .grpcWeb`
on the standard `URLSessionHTTPClient`.** That delivers the "no Envoy" property concretely, and it
keeps iOS on the system networking stack — which matters more than it sounds on a throttled
Dushanbe 3G link, because `URLSession` handles cellular transitions, background suspension and
proxy configuration that a bundled NIO HTTP/2 stack would have to reimplement.

gRPC-Web cannot do client-streaming or bidirectional streaming. That is **fine and worth stating**:
streaming is a non-goal (§8) because Supabase Realtime keeps order-status, chat, location and menu
subscriptions. If that ever changes, Armeria already serves full gRPC on the same port and the
client switches to `.grpc` + `ConnectNIO` — a client-side change.

Armeria also supplies, without extra dependencies, the things a solo operator actually needs:
decorators for the JWT interceptor, health checks, request logging, graceful shutdown, and a
built-in `DocService` that makes the RPCs explorable in a browser. Protobuf-JSON stays enabled so
every RPC is `curl`-able during development — which recovers most of what the Connect protocol
would have given.

**One honest caveat:** grpc-kotlin's latest release is **v1.5.0, dated 2025-09-16** — twelve months
without a release at time of writing. It is stable rather than abandoned, and Armeria hosts
standard grpc-java service implementations so the coroutine stubs are a convenience rather than a
dependency. If it goes stale, the fallback is plain grpc-java with a thin `suspend` wrapper, which
is a per-service change and not an architecture change. Check its release cadence before
committing.

### 6.2 The interceptor library, and the 20-minute window's built-in answer

`nimbus-jose-jwt` is the only candidate that cleanly does ES256 + JWKS + `kid` selection.
`JWKSourceBuilder` provides rate-limited retrieval, refresh-ahead caching, retry on transient
network failure, and outage tolerance — and, decisively, **the cache is refreshed when the key
selector encounters an unknown key ID.**

That is the mitigation for §5.3's revocation lag, and it is a library feature rather than something
to build: after a Supabase key rotation, the first token bearing the new `kid` forces a refresh
instead of failing. The residual exposure is only a *revoked* key still inside its cache window,
which is what the per-call authorization reload covers.

`jwks-rsa` is disqualified outright — it is RSA-oriented, and every Supabase project now signs with
ES256 (P-256). A library that cannot select an EC key from a JWK set is not a candidate.

### 6.3 Local development

`docker compose` with three services: `postgres:17` (matching Supabase's engine — the two live
projects report 17.6.1), the Kotlin app, and nothing else. Flyway runs on app start in dev and as
a separate step in CI. Supabase auth is **not** run locally: the interceptor verifies against the
real project's JWKS over the network, so a dev token is a real token from the real auth stack.
That avoids standing up the whole Supabase stack locally, and it means the auth path under test is
the auth path that ships.

The iOS simulator reaches the container at `http://localhost:8080` via
`RavonCore.configure(apiURL:)`. On device, a LAN address. Never a compiled-in default — the
consumer app's Release build currently ships `API_BASE_URL = http://localhost:8000`, which is the
precedent this rule exists to prevent.

### 6.4 Deployment

**Fly.io, region `fra` (Frankfurt) or `waw` (Warsaw)** — Fly has no Central Asia region, and
Frankfurt is the realistic low-latency European hop for Dushanbe. **Do not inherit `sjc`** from
the abandoned `Ravon_android/backend/fly.toml`: San Jose to Dushanbe is roughly the worst
available choice.

**`min_machines_running = 1`, not 0.** The abandoned config had `auto_stop_machines = 'stop'` with
`min_machines_running = 0`, which is right for a hobby web app and wrong here: a JVM cold start on
a shared-cpu machine is seconds, and dispatch sits in the ordering path. Pay for one always-on
machine.

1 GB shared-cpu is adequate for one deployable. Base image: a JRE-only image (`eclipse-temurin`
JRE variant or a `jlink`ed runtime) rather than a full JDK; `-XX:MaxRAMPercentage=75`,
`-XX:+UseSerialGC` at this heap size, and `-XX:TieredStopAtLevel=1` only if startup time turns out
to matter more than throughput.

### 6.5 Observability — day one versus premature

Day one: structured JSON logs to stdout with a request id; Armeria's built-in metrics on a
`/metrics` endpoint; the health check Fly already polls; and an error counter per RPC per typed
reason. That last one is the cheap thing with real value — it tells you which of the 29 error
reasons actually fire in production, which nothing in this system currently knows.

Premature: distributed tracing (one deployable — the trace is the log line), APM, a metrics
backend, alerting beyond Fly's built-in health alerting, log aggregation. Add tracing when there
is a second deployable to trace between.

---

## 7. Phases

### Ordering, and why it differs from both source documents

`10` says ledger first. The brief says dispatch → ledger → order and "do not reorder without saying why." Here is why the plan inserts a phase and keeps the brief's relative order.

**Dispatch goes first, but not for the brief's reason.** "No database writes" is true and shallow. The real reasons: (1) it is the only component with a **complete, verified reference implementation and a test oracle** — a Kotlin port can be proven equivalent by differential testing against the Swift original on the same 300 matrices and 30 seeds; (2) it has **zero consumers**, so zero regression surface; (3) it therefore isolates **toolchain risk from logic risk** — Phase 1's job is to prove Gradle + buf + grpc-kotlin + Connect-Swift codegen + container + deploy work at all, on a problem where correctness is decidable. Ledger-first cannot do that: it is blocked on a money-type change and a payment-method column that touch all three apps.

**A schema/auth phase is inserted before ledger.** The brief folds "first service that writes, so the interceptor lands here" into the ledger phase. But writing anything requires a re-provisioned Supabase project, a V1 baseline schema (the largest unscoped piece of work in the corpus — it must be written from scratch), RLS designed fresh for 11 tables, the `ravon_app` role and its grants, and the `db-invariants` CI job. Pulling that out of the ledger phase is what lets the ledger phase be about money instead of plumbing. It also has a perfect exit criterion: **`scripts/schema_drift.py` goes from 15 unverified to 0** against the live project — a tool that already exists and is already in CI.

**Order stays last**, but "highest risk" is the wrong reason — there is no live system, so there is no cutover risk anywhere. Order is last because it has the most *new* work: five merchant RPCs that never existed, an idempotency layer `create_order` never had, modifiers that were never persisted, and a 41-edge graph reconciled from a 36-edge table.

### Phase 0 — commit, unbreak, decide. Zero new behaviour.

Ends with: everything tracked, CI green for the first time, all three apps building from a tag, one SDK version, docs telling the truth.

| Step | What | Verification |
|---|---|---|
| 0.1 | **Commit the untracked foundation** in `ravon-core` — `Dispatch/`, `OrderLifecycle.swift`, 5 test files, `scripts/`, `.github/`, `AGENTS.md`, **and the parallel tracks' work: `docs/`, `ml/`, `db/`** (all untracked as of this writing) — and open the PR. | `git status` clean. CI runs for the first time. All 5 jobs green. |
| 0.1b | **Decide what of `.context/` becomes tracked.** `.gitignore:9` excludes `.context/` entirely, and it has never been tracked in any commit — so **this plan, the 15 research documents, the two dispatch fixtures and the three app prompts are all invisible to git.** That is worse than the untracked code in 0.1, which at least appears as `??` in `git status`. Move the durable artifacts into tracked paths: this plan → `docs/kotlin-backend-extraction.md`; the boundary map, reconstructed schema and dispatch spec → `docs/`; `dispatch-baseline-seeds-1-30.json` and `dispatch-rng-golden-vectors.json` → `Tests/RavonCoreTests/Fixtures/`. Leave genuinely ephemeral material (state reports, prompts, scratch) in `.context/`. Also add `*.egg-info/` to `.gitignore` — `ml/ravon_ml.egg-info/` is currently not ignored and would be committed as a build artifact. | `git check-ignore docs/kotlin-backend-extraction.md` → no match. `git add -An .` stages no `egg-info`. |
| 0.2 | Fix `Package.swift`: `.iOS(.v17)` → `.iOS(.v18)`, `.macOS(.v14)` → `.macOS(.v15)` (the apps are on 26.2; the package floor was a lie; and `macos-15` is the CI runner). Fix `README.md`/`CLAUDE.md`/`AGENTS.md`: platform, test count (73 → 163), `create_order` signature (4 args → 5), delete `AGENTS.md` duplication (identical bytes; keep one, symlink the other). | `swift test` green. `diff CLAUDE.md AGENTS.md` is a symlink. |
| 0.3 | **Tag `v0.9.0`** on `main` after 0.1 merges. | `git tag` non-empty. |
| 0.4 | **Re-pin the apps.** In each app repo, change the RavonCore requirement from `kind = branch; branch = "mmarufov/auth-overhaul"` to `upToNextMinorVersion: 0.9.0` in `.pbxproj`. Pin `supabase-swift` to one version everywhere (`exact: 2.43.1`, the newest the fleet resolves). Delete `mmarufov/auth-overhaul` on origin only after all three `Package.resolved` show a `version`. | Each app: `xcodebuild` clean from a fresh clone of `main`. `Package.resolved` shows `version`, not `branch`. `grep -c 'kind = branch' *.pbxproj` → 0. |
| 0.5 | **Consumer:** consolidate credentials (9 edits, 3 files; delete `APIClient.swift`; strip the six `INFOPLIST_KEY_*` build settings including the `localhost:8000` Release value). Remove the direct `orders.delivery_mode` write (`ConfirmOrderViewModel.swift:121`) — it becomes a `create_order` parameter in Phase 4; until then, drop the override UI. | `grep -rn "<dead-ravon-project-ref>\|localhost:8000" DuDash/` → 0. `grep -rn 'from("orders")' DuDash/` → 0. |
| 0.6 | **One `Money` type in RavonCore** — `struct Money { let minor: Int64; let currency = "TJS" }`, one formatter (`"\(whole) сомони"` integer, or 2dp only when `minor % 100 != 0`; the consumer's existing rule), Cyrillic pluralisation in one place. Delete both `₽` sites. Fix `SupabaseService.swift:60`'s `Int()` truncation. Apps adopt the formatter (merchant: 13 sites + `.decimalPad`; courier: `%.0f` sites; consumer: `formatPrice`). | `grep -rn "₽\|сум\b" Sources/ apps/` → 0. Property test: `Money.format` round-trips for 10k random minor amounts. |
| 0.7 | **Wire `ServiceError.from` into the throw path** of every RPC wrapper in `SupabaseService`, rewrite it to parse the full DETAIL JSON object (not a regex), cover all 29 kinds + `ROLE_CHANGE_FORBIDDEN`. Apps drop their 7 opt-in call sites. | `grep -rn "ServiceError.from" apps/` → 0. Test: every reason kind decodes with its structured fields. |
| 0.8 | **Realtime hygiene** in `RealtimeService`: ref-counted subscriptions, one slot per channel (not one shared `orderChannel`), `unsubscribeAll()` covers restaurant-status, tear down on sign-out, tolerate `.integer` and fractional-second timestamps. Document `REPLICA IDENTITY FULL`. | Tests for subscribe/unsubscribe pairing. |
| 0.9 | Add ownership predicates to `SupabaseService.swift:267` and `:1084`. | Test. |
| 0.9b | **Fix `scripts/schema_drift.py`** (§1.1): parse comma-separated `case` lists, widen `sql_identifiers` to all lowercase tokens, drop the `"_" in wire` filter. The tool is one of the five CI jobs and is currently blind to 36 of 265 wire keys — including `Profile.role` and `MenuItem.price`. | Regression test asserting the parser finds all 265 keys. Expect the unverified count to *rise* from 15 to ≥ 20; that is the fix working. |
| 0.10 | **Export `Calendar.dushanbe` and a timezone-pinned formatter** from core; fix the four device-timezone sites (three courier, one core). | Test: "today" boundary is stable across `TimeZone.current`. |
| 0.11 | Write `docs/adr/0002-one-deployable-three-modules.md` (§2.1) and `docs/adr/0003-connect-swift-over-grpc-web.md` (§4.1–4.4), following the convention a parallel agent has already established in `docs/adr/0001-order-lifecycle-as-declared-data.md`. Add a superseded-by banner to `02-TARGET-ARCHITECTURE.md`'s Refuse table. | — |

Not in Phase 0, deliberately: XcodeGen (justification falsified), "semantic theming" (it was a `Money` type all along — that is 0.6), monorepo (§2.3).

### Phase 1 — `dispatch` module. The toolchain proof.

**Hard acceptance test (from `.context/NOTE-for-kotlin-chat.md`): the Kotlin dispatcher + simulator must reproduce the Swift simulator's results seed-for-seed.** The baseline was recorded this session, *before* any port, at the exact config `DispatchSimulationTests` uses (12 couriers, 240 orders, 180 min, seeds 1–30): `.context/research/dispatch-baseline-seeds-1-30.json` — per seed, per dispatcher (greedy and optimal), all of `ordersAssigned`, `meanDeliveryMinutes`, `totalCourierTravelKm`, `meanWaitToAssignMinutes`, `p95WaitToAssignMinutes`, `giniCoefficient`, `couriersWithNoWork`, `jobsPerCourier`. The Kotlin port is correct when every one of those numbers matches. Anything less is not a port.

This is feasible because the simulator's RNG is **SplitMix64, hand-implemented** (`MarketplaceSimulator.swift:14-23`), not `SystemRandomNumberGenerator` — the 64-bit state update ports to Kotlin `ULong` verbatim. The residual risk is narrower and must be named: Swift's `Double.random(in:using:)` and `Int.random(in:using:)` map those 64 bits to a range with stdlib-specific algorithms. **The port must reimplement Swift's exact mapping, not call Kotlin's `Random`.** Every draw must happen in the same order, and every floating-point expression must be evaluated in the same order. The fixture makes a divergence visible on the first seed.

**The port is mechanical, and the three details that decide whether it succeeds are now pinned**
(full spec: `.context/research/dispatch-spec.md`, written from first-hand reading of all six files):

1. **Tie-breaking.** Both comparisons in the solver's inner search are strict `<` over ascending
   `j`, so the **lowest column index wins every tie**. Same in `GreedyDispatcher`'s inner loop.
   Use `<=`, or iterate a `HashMap`, or parallelise the scan, and the matching changes on ties.
   There is no RNG and no hash-order dependence in the solver — it is fully deterministic, so a
   Kotlin port can be byte-identical.
2. **The cost model, in minutes.** `toPickup + waitAtRestaurant + deliveryLeg − urgencyCredit −
   fairnessCredit`, with `averageSpeedKmh = 18`, `maxAssignmentRadiusKm = 8`,
   `orderAgeCreditPerMinute = 1.5`, `courierIdleCreditPerMinute = 0.4`, `maxCreditMinutes = 25`
   capped per-credit. **Costs go negative once credits apply and that is load-bearing** — it is
   what lets a stale order outrank a cheap new one. Do not clamp at zero. Infeasible pairs are
   `1e9`, not infinity, and are discarded at extraction rather than excluded during matching.
   Rectangular padding is zero-cost dummy columns, so rows must be couriers.
3. **The RNG mapping, not the RNG.** `SeededRNG` is SplitMix64 and ports to Kotlin `ULong`
   verbatim. The risk is Swift's stdlib mapping from 64 raw bits into a range — and the
   closed-range and half-open forms differ. `.context/research/dispatch-rng-golden-vectors.json`
   records 16 values of each of the five draw kinds the simulator makes, from seed 42, next to the
   raw `next()` outputs. Match those first; they turn the risk into a unit test. One RNG drives the
   whole run, so **draw order** matters as much as draw value — the order is enumerated in the spec
   (`randomPoint` draws radial then bearing; `gaussian` is Box–Muller u1-then-u2 and discards the
   second output, so every call consumes exactly two draws).

Two things the port must decide rather than copy. **`GreedyDispatcher` sorts orders by `createdAt`
alone** — fine while the simulator generates distinct timestamps, ambiguous the moment two orders
share one; sort by `(createdAt, id)` in Kotlin and add the same tiebreak to Swift before deleting
it. And **`Math.sin/cos/atan2` are not bit-guaranteed across JVM platforms** — if the baseline
diverges in the last digits, switch to `StrictMath`.

**A third radius surfaced.** The cost model forbids a pair beyond **8 km**; the Swift offer-feed
wrapper defaults to **10 km**; the SQL default is **50 km**. Dushanbe is ~25 km across. Only the
8 km figure is exercised by anything and only it has a stated rationale. Pick one number for all
three before `Assign` ships — the courier prompt asks about 10 vs 50, but the real question is the
single value.

**`Assign` takes `now` as a request field, not the server clock.** The cost model is a pure
function of `(couriers, orders, now)`, so making the clock explicit keeps a given request
reproducible and testable. The courier-facing offer projection is a **separate message** —
restaurant name and location, dropoff area, haul km, estimated earnings, expiry, and
**no verification codes and no address snapshot for an unclaimed order.** That is the actual
dispatch bug being fixed (§0.4), and once codes are hash-only server-side (§9 rule 7) the leak is
not merely fixed but unexpressible.

**One measured number in the source documents is overstated, and it is going on a résumé.** Ran
the real engine over seeds 1–30 this session: orders assigned **+44.6 %** (docs say +42 % —
understated, good), mean delivery **−45.3 %** (accurate), optimal wins **30/30**. But courier
travel is **−1.06 % mean with a worst single seed of +2.13 %** — the docs and the coordination note
say "−1.4 % courier travel," and the mean hides a sign flip. Over the ten seeds the test actually
checks it is −0.78 % mean, +1.87 % worst. The defensible claim is **"a +44.6 % throughput gain for
no measurable travel penalty"**, not "−1.4 % less travel." A reviewer who reruns the simulator
will find the +2.13 % seed. Both test comments have been corrected to the measured values.

| Step | What | Verification |
|---|---|---|
| 1.1 | **Pin the baseline in Swift first.** Check `dispatch-baseline-seeds-1-30.json` in as `Tests/RavonCoreTests/Fixtures/dispatch-baseline.json`; add `test_simulatorMatchesRecordedBaseline` asserting every field per seed. ✅ **The guard tightening the note asked for is already done** — `test_optimalDispatchIsSubstantiallyBetterUnderLoad` now asserts `mean >= 0.35` (was `> 0.20`), and both test comments carry the measured numbers instead of the overstated ones. | Guard change verified green (7/7 dispatch, 7/7 Hungarian incl. the 300-matrix brute-force check). Fixture test still to add. |
| 1.2 | `services/` Gradle project: `common`, `dispatch` modules; `proto/ravon/dispatch/v1/`; `buf.yaml` + `buf.gen.yaml`; codegen into Kotlin and into `Sources/RavonCore/Generated/` (checked in). | `./gradlew build` green. `buf lint` green. |
| 1.3 | Port `Geo`, `HungarianSolver`, cost model, `DispatchZone`, `Dispatcher`, `MarketplaceSimulator`, `SwitchbackExperiment`. Port the 300-matrix brute-force test and the 17 Hungarian/simulation/switchback tests. | Kotlin `DispatchBaselineTest` loads the same JSON fixture and matches every field. `mean >= 0.35` asserted in Kotlin too. |
| 1.4 | `buf breaking` job in CI against `main`. Prove it works by opening a PR that renumbers a field and watching it fail. | The failing PR is linked from the ADR. |
| 1.5 | Expose `DispatchService.Assign` (unary) and `SimulateBatch` (dev-only, behind a flag). JWT interceptor is **not** in this phase — `Assign` is unauthenticated in Phase 1 and unreachable from the internet (bound to localhost / private network). | RavonCore test calls `Assign` through the generated Connect-Swift client against a local container. |
| 1.6 | Container image, `fly.toml` (**not** `sjc`; region per §6), `/health`, `min_machines_running = 1`. | Deployed; health green; `Assign` answers from a phone on the sim. |
| 1.7 | Delete `Sources/RavonCore/Dispatch/` and its five test files. The fixture and `test_simulatorMatchesRecordedBaseline` move to Kotlin. **Tell the `ml/` agent first:** `ml/export/main.swift` is a one-shot Swift bridge that produced the committed `ml/data/orders.csv.gz`. It does not break when the simulator goes — but *re-exporting* will require a Kotlin equivalent, so either port the exporter in this step or confirm the frozen dataset is sufficient. | `swift test` green minus the dispatch tests; the CI `dispatch-quality` job now runs `./gradlew :dispatch:test`. |

Ends with: a running container that answers `Assign`, provably equivalent to the Swift engine on 30 seeds × 2 dispatchers × 11 fields, called from a RavonCore test through the generated Connect-Swift client, behind a `buf breaking` gate that has been seen to fail on purpose. The Swift `Dispatch/` directory deleted.

### Phase 2 — Schema V1, live project, auth, invariants CI.

Ends with: a fresh Supabase project with the reconstructed schema applied by Flyway into `app`, PostgREST exposed on `api` only, `ravon_app` role with §9's grants, the JWT interceptor merged with an integration test that rejects a forged token, the `db-invariants` job green, and **`schema_drift.py` reporting 0 unverified — against the *fixed* tool** (§1.1; the current one is blind to 36 of 265 wire keys, so 0 against today's version would mean only that it looked at 86 % of the schema).

### Phase 3 — `ledger` module: a facade over `db/ledger/`.

**The dependency has landed.** `db/ledger/schema.sql` now exists — 1,030 lines, with `tests/`
alongside it. It answers most of the interface questions below, so the table that follows is kept
as the record of what was asked, annotated with what the schema actually delivered:

| Asked for | Delivered |
|---|---|
| An idempotency key, replay vs conflict | ✅ `p_idempotency_key` + `p_request_fingerprint`; returns `ledger_post_result(transaction_id, replayed)` — `replayed` distinguishes "wrote it now" from "returned the original" |
| Amounts as `bigint` minor units | ✅ signed convention: `debit = +amount`, `credit = -amount`, so `SUM(signed)` over the whole ledger is 0 and conservation is one cheap query |
| Typed failures | ✅ `ledger_raise(reason, http_status, detail)` — e.g. `INVALID_IDEMPOTENCY_KEY`/422. **Map these onto the proto `Reason` enum in §4.2; they are a second vocabulary today.** |
| A stable transaction id | ✅ `transaction_id uuid` |
| Payouts in scope, or mine? | ✅ **theirs** — `ledger_payouts` table exists. Phase 3 does not build a payout state machine. |
| Chart of accounts incl. cash | ✅ `ledger_accounts`; confirm a cash-in-courier-hand account exists before Phase 4 adds `payment_method` |

Two things to reconcile, neither blocking:

- **The role is `ravon_ledger_app`, not `ravon_app`.** `schema.sql:989-1016` grants `SELECT` on the
  ledger tables and `EXECUTE` on `ledger_post`, and revokes `INSERT/UPDATE/DELETE/TRUNCATE`. Either
  the Kotlin service holds both roles, or §9's grant list adopts their name. Prefer one role with
  their grants folded in — two connection pools for one process is waste.
- **There is no `HANDOFF-for-kotlin.md`** yet, only `schema.sql` and `tests/`. The schema's header
  comments are thorough enough to work from; ask for the handoff only if something below is unclear.

**Original scope note, still true.** The ledger *schema* — accounts, entries, the `DEFERRABLE INITIALLY DEFERRED` zero-sum constraint trigger, append-only enforcement, and the Hypothesis crash-injection harness that proves conservation — is being built by a separate agent in `db/ledger/` as plain SQL with its own CI job. As of this writing `db/` exists and is empty; `db/ledger/HANDOFF-for-kotlin.md` is the dependency and must be read when it appears.

The Kotlin `ledger` module therefore does **not** design money storage. It is a gRPC facade that (1) authenticates the caller, (2) authorises the operation against database state, (3) maps a domain event to exactly one `ledger_post(...)` call, and (4) returns a typed result. **It never writes `ledger_entries` directly** — `ravon_app` holds no INSERT on that table; only `ledger_post` (SECURITY DEFINER, owned by a role the service cannot assume) does.

What this module needs from `ledger_post`, stated as the interface contract to reconcile against the handoff:

| Need | Why |
|---|---|
| An **idempotency key** parameter: replay → same result; same key + different payload → a distinguishable error | DoorDash's contract has to be implementable at the facade; the DB is the only place a replay can be detected atomically with the post. |
| Amounts as **`bigint` minor units** (diram) | The proto carries `int64 minor`; no `numeric`/`double` crosses the boundary. |
| A **typed failure** (SQLSTATE + `DETAIL` reason) for: unbalanced, unknown account, duplicate key, amount out of domain | Maps onto the same `ErrorInfo` reasons as every other RPC. |
| A stable **transaction id** returned | Audit trail and `order_status_history` cross-reference. |
| Whether **payouts** and `(courier, period)` uniqueness are in the ledger schema | If not, the payout state machine (`pg_advisory_xact_lock` + provider idempotency key persisted *before* the outbound call) lands here. |
| The **chart of accounts**, incl. a cash-in-courier-hand account | Tajikistan is cash-heavy and `Order` has no payment method today; the order module adds `payment_method`, the ledger needs somewhere to book cash. |

What this module owns:

| Step | What | Verification |
|---|---|---|
| 3.1 | JWT interceptor applied (first authenticated module). | Integration test: forged ES256, expired, wrong `aud`, HS256-signed-with-the-public-key → all `UNAUTHENTICATED`. |
| 3.2 | `LedgerService`: `PostTransaction`, `GetBalance`, `ListEntries`. Each `PostTransaction` → one `ledger_post`. | Property test: N random posts with random replays → entry count equals the number of *distinct* keys. |
| 3.3 | Event mappers, each a pure function `(event) → LedgerPosting`: delivery completed (fee split: merchant payable, courier payable, platform revenue, remainder to rounding), courier cancel at tier (25/50/100% per mig 12 — **no tier-override parameter**; tier looked up from `status_at_event`), tip (replace semantics, clamp to `min(50% subtotal, 200 TJS)`, `total` never includes tip), refund, no-show (earnings = full). | Table-driven tests per mapper; the fee-split remainder is asserted to land in the rounding account. |
| 3.4 | Earnings read model for the courier app: `GetEarnings(period)` with the **day boundary computed server-side in `Asia/Dushanbe`**; `totalDeliveries` counts only `delivery` postings; fees summed from *earned*, not nominal. Replaces the client-side summation that over-counts and double-counts today. | Test: postings at 23:59 and 00:01 Dushanbe land in different days regardless of `TimeZone.current`. |
| 3.5 | `courier_earnings` retired as a write target; becomes a view over postings or is dropped. | `db-invariants`: `ravon_app` has no INSERT on `courier_earnings`. |

**Nothing further is designed here on purpose.** A dedicated ledger-design pass was planned and is
deliberately dropped: the coordination note reassigned the schema, the zero-sum constraint trigger,
the immutability enforcement and the crash-injection proofs to `db/ledger/`. Designing them twice
would produce a second spec to disagree with the first — the exact failure this plan spends §0
cataloguing. The interface table above is this module's half of the contract; reconcile it against
`db/ledger/HANDOFF-for-kotlin.md` when that lands, and raise anything it does not cover.

### Phase 4 — `order` module.

Highest *new-work* content of any phase — not highest risk, because there is no live system to cut
over from. The order module owns 19 RPCs:

| Group | RPCs | Source |
|---|---|---|
| Checkout | `ValidateCart`, `CreateOrder` | port of 2 SQL functions; `CreateOrder` gains the idempotency key it has never had |
| Merchant kitchen | `AcceptOrder`, `RejectOrder`, `StartPreparing`, `MarkOrderReady` | **new.** Specified by the four client-side CAS predicates (`SupabaseService.swift:394-445`) |
| Merchant cancel | `CancelOrderByMerchant` | **new.** Nothing in the fleet can produce `cancelled_by_restaurant` today |
| Courier lifecycle | `ClaimOrder`, `ArrivedAtRestaurant`, `PickupOrder`, `StartDelivering`, `ArrivedAtCustomer`, `DeliverOrder` | port of 6 |
| Courier exceptions | `CancelOrderByCourier`, `ReportProblemPostPickup`, `ExplainDelay`, `ReportCustomerNoShow`, `ReportRestaurantDelay` | port of 5 |
| Consumer | `CancelOrderByConsumer` | port of 1 |
| Read models | `GetMerchantStats`, `GetOrder`, `ListOrders` | `GetMerchantStats` rebuilt from a draft that had no owner check |

Steps, each ending green:

| Step | What | Verification |
|---|---|---|
| 4.1 | `app.order_transitions` table seeded with the reconciled 41 edges + `app.order_transition(...)` as the sole writer of `orders.status` (§3.1). Revoke `UPDATE (status)` on `orders` from `ravon_app`. | `db-invariants` asserts the revoke. A test asserts the Kotlin transition table and `app.order_transitions` hold the same 41 rows. |
| 4.2 | Port the 17 lifecycle invariants to `kotest-property`, including the Tarjan SCC liveness proof, **with invariant 13 fixed and 17 expected to change** (the no-show edge targets `delivered`, not `cancelled_by_system`). Add the six invariants the Swift suite is missing. | 23 property tests green against the Kotlin table. |
| 4.3 | Idempotency store + the DoorDash contract: `(key, request_hash, response)`; replay returns the stored response, hash mismatch returns `ALREADY_EXISTS`. | Property test: N random calls with random replays produce exactly one order per distinct key. |
| 4.4 | The 19 RPCs, each mapping its guards to a typed `ErrorInfo` with populated metadata. | Table-driven test per RPC covering every reason it can raise, asserting the metadata fields are present. |
| 4.5 | `CreateOrder` gains `p_delivery_mode` and `modifier_option_ids`, retiring the migration-10 trigger and the consumer's direct write. **Both must land together** — shipping the policy removal first produces a silent unloggable bug in the primary conversion flow. | Consumer builds with no `from("orders")`; an order created with modifiers persists them. |
| 4.6 | Cut the three clients over: swap the bodies of RavonCore's `SupabaseService` methods to Connect calls. Merchant (22 files) and courier (27) need **zero** source changes beyond typed-error handling, because both have zero `import Supabase`. Consumer needs the credential and write changes from Phase 0. | All three apps build and their flows work against the local container. |
| 4.7 | Delete the 22 superseded SQL functions and revoke the 11 remaining client grants. | `db-invariants` asserts no `prosecdef` function is `EXECUTE`able by `anon`/`authenticated` outside the allowlist. |

The saga's compensation story is narrower than the brief implies. `create_order` is already a
single Postgres transaction with row locks; it does not need a distributed saga. What it needs is
the idempotency key and a clean failure path — the only genuinely multi-step flow is
delivery-completion (transition + ledger posting), and both halves are in one database, so one
transaction covers it. **Do not build a saga orchestrator for a problem a transaction solves.**

---

## 7b. Decisions taken

Recorded so later phases do not relitigate them. Dated 2026-09-16, decided by the project owner.

| # | Question | Decision | Consequence |
|---|---|---|---|
| D1 | Rescue the untracked + gitignored work | **Commit, push, open the PR** | Phase 0.1/0.1b executed. CI runs for the first time. |
| D2 | `add_tip` clamp or reject | **Clamp**, returning the applied amount | No deployment ordering constraint; the consumer's invisible-error bug stops being a blocker. Client must render the *applied* amount, not the tapped one. `orders.total` still excludes tip. |
| D3 | Dispatch radius: 8 / 10 / 50 km | **8 km** | The value the 30-seed baseline was measured at, so the fixture stays valid as the Kotlin port's oracle. Courier asked to sanity-check it against real Dushanbe geography. |
| D4 | Address coordinates | **Shared map picker in RavonCore** | Strongest option, and it fixes the silently-broken tracking map. But it puts client UI work on Phase 1's critical path — consumer asked for an honest estimate and a plan for existing coordinate-less addresses. |

---

## 8. Non-goals

Ruled out, with the reason. Several are things the source documents flirt with.

| Not doing | Why |
|---|---|
| Gurobi / any commercial solver | The Hungarian solver is exact at this size; verified optimal against brute force on 300 matrices. |
| Kafka, Flink, Cassandra, CockroachDB | Wrong scale by three orders of magnitude. Postgres with a transactional outbox is the whole event story. |
| Service mesh, Kubernetes | One deployable (§2.1). A mesh for one process is a costume. |
| Cadence / Temporal | `10:166` cites it for payout locks. A `pg_advisory_xact_lock` + unique `(courier, period)` gives the same guarantee with zero infrastructure. `02` was right. |
| Kotlin scheduled workers replacing `pg_cron` | Nothing forces the jobs out. They stay, lose their client grant, run as `ravon_cron`. |
| Feature store, ML platform | Out of scope for *this* plan. Note `ml/` now **exists** and is being built in parallel by another agent (Python, `numpy`/`scipy`, probabilistic ETA + anomaly detection). It is deliberately decoupled: `ml/export/main.swift` writes a committed snapshot to `ml/data/` and its own header states that "the Kotlin extraction happening in parallel can delete or move the simulator without breaking the ML layer." See §7 Phase 1.7 for the one obligation that creates. |
| Rewriting auth/OTP in Kotlin | Shipped, works, no product value in moving it. |
| Replacing Supabase Realtime with gRPC streaming | Realtime handles 8 channels well. This is why Connect-Swift (unary-only) is sufficient and gRPC Swift 2 (streaming, iOS 18, Swift 6.1) is not needed. |
| gRPC-Web / Envoy | Connect speaks HTTP/1.1 and HTTP/2 natively to iOS. No proxy. |
| Moving reads off PostgREST | A typed client exists; moving reads adds a hop and removes nothing. |
| Event-sourcing the order | The lifecycle is a state machine with a transition table and an audit trail (`order_status_history`), not an event log. Keep it that way. |
| Android client | `Ravon_android` stays abandoned. The proto makes it cheap *later*; it is not in scope now. |
| Monorepo of the apps | §2.3. Tags + CI first. |
| XcodeGen | Justified with a failure that does not exist (0.8). Three `.pbxproj` files that agree with each other are not a problem. |
| Fraud rules engine | Doc `10` Phase 4. Not this plan. |
| Custom proto `ServiceOptions` for client reliability config | Premature for one service and three clients that share one Swift wrapper. Timeouts live in the RavonCore client. Revisit if a second client language appears. |

---

## 9. Security by construction

Full rules R1–R18 with enforcement mechanism in `security-by-construction.md` §7; the Kotlin role's grant list in §9 there. The principles that shape everything above:

1. **The load-bearing primitive is the missing GRANT, not the missing policy.** A policy is only reached if the table-level grant exists. Clients get no INSERT/UPDATE/DELETE grant on `orders`, `order_items`, `order_status_history`, `courier_earnings`, or any ledger table. A future `CREATE POLICY` then cannot re-open anything.
2. **Every function is unreachable by default.** `REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC, anon, authenticated; ALTER DEFAULT PRIVILEGES … REVOKE EXECUTE ON FUNCTIONS …` in `V1`. Grants come from a checked-in allowlist. Postgres defaults new functions to `EXECUTE TO PUBLIC`, and `CREATE OR REPLACE` preserves ACL — this is exactly how S3 survived migration 13.
3. **PostgREST sees `api` only.** Tables and functions live in `app`. Client-readable views in `api` are `WITH (security_invoker = true)`. Reachability becomes schema membership.
4. **`role` is never client input.** `handle_new_user` inserts `'consumer'` unconditionally. Merchant/courier roles come from an operator path with its own audit trail. The interceptor's `Principal` has no role field. No `pg_proc` body may match `raw_user_meta_data|user_metadata` — CI asserts it.
5. **Money is derived, not supplied.** `total_minor GENERATED ALWAYS AS (…) STORED`; `bigint` minor units; `CHECK (… >= 0)`. Unwritable by every role including `ravon_app`.
6. **Ledger entries are append-only** — `UPDATE`/`DELETE` revoked from *every* role including the service; zero-sum enforced by a `DEFERRABLE INITIALLY DEFERRED` constraint trigger at COMMIT.
7. **Codes are hashed, CSPRNG, 6 digits, attempt-capped at 5.** The plaintext does not exist server-side, so no read path can leak it — which is the current offer feed's actual bug.
8. **A sixth CI job, `db-invariants`,** applies `V1` to a throwaway Postgres and runs `schema/invariants.sql` — one assertion per rule above. *A scanner's totals block is never evidence of a fix. Only an assertion that fails the build is.* The second security report said `critical: 0` a month before the only critical fix was written.

---

## 10. Risks, ranked

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| 1 | **The foundation is untracked.** One workspace teardown or `git clean -fd` destroys the dispatch engine, the lifecycle spec, the drift tool, and the CI. | High — Conductor workspaces are disposable by design | Total | Phase 0 step 1. Do it today. |
| 1b | **The plan is gitignored.** `.gitignore:9` excludes `.context/`, which has never been tracked — so the plan, all 15 research documents, both fixtures and the three app prompts exist only in this worktree and are invisible to `git status`. The untracked *code* at least shows up as `??`. | High — same teardown risk as risk 1, with no visible warning | Total loss of the reasoning, not just the code | Phase 0 step 0.1b. Move durable artifacts to `docs/` and `Tests/.../Fixtures/`. |
| 2 | **V1 baseline is reconstructed, not introspected.** 14 of 15 tables and all enums were dashboard-created. The union of three sources still has gaps the verifiers list. A wrong nullability is a decode crash in a shipped app. | Certain that *some* column is wrong | Medium per column | `schema_drift.py` as Phase 2's exit gate. Nullable-wins resolution rule. Every single-source column flagged. |
| 3 | **RLS for 11 tables is unrecoverable and must be designed fresh.** No source in the repo records what the server permitted. | Certain | High if wrong | Design from the by-construction rules, not from memory. `db-invariants` asserts the grant matrix. Scope "defence-in-depth" to the five Kotlin-written tables only. |
| 4 | **Two migration systems on one database.** Supabase owns `auth`/`storage` and its own history; Flyway owns `app`. Someone runs the wrong one against the wrong schema. | Medium | High | Flyway owns `app` and `api` exclusively; Supabase CLI owns nothing in `app`. `db-invariants` fails if any object in `app` lacks a Flyway history row. Never `supabase db push`. |
| 5 | **Seed-for-seed reproduction fails on a floating-point or range-mapping detail.** RNG is SplitMix64 (portable), but Swift's `Double.random(in:using:)` / `Int.random(in:using:)` range mapping and floating-point evaluation order must be reproduced exactly. | Medium | High — the note makes this *the* acceptance test | Baseline recorded before the port (`dispatch-baseline-seeds-1-30.json`). Port Swift's stdlib mapping, not Kotlin's `Random`. Differential-test seed 1 before writing seed 2. |
| 6 | **The 20-minute JWKS revocation lag.** | Certain | Low–Medium | §5.3. Per-call DB reload of authorization state; short tokens; operator refresh endpoint. |
| 7 | **`Double` → minor units touches every model and all three apps.** A missed site truncates or rounds differently. | High | Medium | `Money` type makes a raw `Double` price unconstructible in Swift. Proto carries `int64 minor`. `numeric` → `bigint` is a `V1` decision, not a migration. |
| 8 | **iOS 26.2 is approximately nobody in Tajikistan.** Not a backend risk, but the apps have no users until it is fixed, and the platform floor decision in 0.2 interacts with it. | Certain | Product | Flag to the user. Connect-Swift supports iOS 13, so the backend does not constrain the answer. |
| 9 | **Solo-dev operational surface.** A JVM service that must be up for orders to exist. | Certain | High when down | One deployable. Health checks. `min_machines_running = 1` (not 0 — a dispatch service cannot cold-start on demand). The apps' `ServiceState` circuit breaker renders "backend down" as a state, not as an empty Tuesday. |
| 10 | **Second transport, second endpoint config.** Last time a second transport was added, Release shipped pointing at `localhost:8000`. | High without a rule | High | Endpoint comes from `RavonCore.configure(apiURL:)` only, injected at launch like the Supabase URL. CI greps the app bundles for `localhost`. |
| 11 | **Phase 1 ships a service nothing calls.** | Certain by design | Low | Stated honestly: Phase 1 is toolchain proof plus the offer projection *contract*. Wiring the courier's offer feed to it is Phase 4, when order state moves. |
| 12 | **Two agents, one `db/` directory.** The ledger schema is built in parallel by another agent; Phase 2's `V1` for `app` and their `db/ledger/` must not collide on Flyway versioning, schema name, or the invariants CI job. | Medium | Medium | Their handoff doc is the interface. Proposal to confirm with the orchestrating chat: `db/ledger/` owns schema `ledger`; Phase 2 owns `app` and `api`; one Flyway history with `V<n>__ledger_*.sql` files authored by them; one CI job runs both invariant files. |
| 13 | **The drift tool is blind to 14 % of the schema** (§1.1), so "0 drift" has been reassuring for three generations of docs while `Profile.role` and `MenuItem.price` were unexamined. | Certain | Medium | Phase 0 step 0.9b. The unverified count should *rise* after the fix. |
| 14 | **The merchant has no working RPCs and cannot cancel.** Five RPCs must be written from the lifecycle table with no SQL to port from. | Certain | Medium | The reconciled 41-edge graph is the spec. Merchant's four CAS `UPDATE`s document the guards exactly. |

---

## 11. Managing the three app workspaces

The three apps are separate repos worked by separate agents. Coordination is by prompt: this chat
writes a prompt per app, the human relays it, and the reply comes back here. Prompts are checked
in at `.context/integration-prompts/kotlin-phase0/` — `_shared.md` (background for the human,
not pasted), plus `consumer.md`, `merchant.md`, `courier.md` (paste-ready).

### Sequencing

**RavonCore goes first and alone.** Nothing in the app prompts can be done until this repo commits
its untracked foundation and cuts tag `v0.9.0` — until then there is nothing to re-pin *to*. Then
all three app prompts go out in parallel; they have no dependencies on each other. Merchant has 10
uncommitted files and must land or stash them first.

### Why prompts, and not a monorepo

This is the mechanism §2.3 chooses over consolidating the repos. It has a real cost — the
`_shared.md` step-1 instruction that created the dangling-branch landmine is exactly this mechanism
failing, because it handed the apps a *branch* as a dependency target and the follow-up tag was
never cut. So the rule that comes out of that: **never give an app agent a branch, a commit SHA, or
a local path as a dependency target. Only a tag.** A prompt that asks an app to pin to anything
else is a bug in the prompt.

### What each app is asked to do, and what is asked back

| | Phase 0 tasks | Blocking answers wanted |
|---|---|---|
| **consumer** | Heaviest load: re-pin; consolidate credentials (9 edits, 3 files, 4 of 5 locations dead, incl. `localhost:8000` shipping in Release); remove the fleet's only app-level `orders` write; adopt `Money`; drop its `ServiceError.from` site and fix the invisible tip error next to it; timezone calendar | Modifier wire shape (charged and discarded today); **tip clamp vs reject**; **address coordinates** (all NULL — dispatch needs dropoff); full RavonCore surface |
| **merchant** | Light: re-pin; adopt `Money` (13 value + 9 label sites; and decide `.numberPad` → `.decimalPad`); timezone; delete its buggy reimplementation of core's hours logic | The four kitchen ops' **error contract** (the CAS empty-result is currently indistinguishable from "cancelled underneath you"); every error string it text-matches; **specify `merchant_cancel_order`** (nothing can produce `cancelled_by_restaurant` today); `get_merchant_stats` fields + timezone; full RavonCore surface |
| **courier** | Light: re-pin; adopt `Money`; **fix the earnings timezone** (a US-based device drops the first 12 h of the Dushanbe day); fix the summary-singleton bug; drop six `ServiceError.from` sites | **What the offer card renders** (the projection must omit the codes it currently leaks); **radius 10 or 50 km**; **specify the decline RPC** (declining is an infinite loop today); authoritative 26-method surface; location-streaming contract; agreement that the earnings numbers are wrong |

Three of those are product decisions this chat cannot make alone — tip clamp-vs-reject, address
coordinates, and the dispatch radius. They are called out as blocking in the prompts rather than
assumed.

### Two other agents are working in this same worktree

Coordination is not only cross-repo. As of this writing two parallel tracks have appeared here:

- **`db/ledger/`** — the ledger schema, zero-sum constraint trigger, immutability enforcement and
  Hypothesis crash-injection harness, per `.context/NOTE-for-kotlin-chat.md`. `db/` exists and is
  empty; `db/ledger/HANDOFF-for-kotlin.md` is the interface. Phase 3 is a facade over its
  `ledger_post(...)`, and this plan deliberately does **not** design money storage.
- **`ml/`** — Python probabilistic ETA and anomaly detection, with `docs/architecture.md` and
  `docs/adr/0001-order-lifecycle-as-declared-data.md`. It is properly decoupled: a one-shot Swift
  exporter produced a committed dataset, so it does not depend on the simulator surviving.

Two consequences. **ADR numbering is already established** (`docs/adr/000N-kebab-title.md`, 0001
taken), so this plan's ADRs are 0002 and 0003. And **Phase 0 step 0.1 must commit their work too**
— `docs/`, `ml/` and `db/` are all untracked right now, alongside everything else in §0.1. One
`git clean -fd` in this worktree destroys three tracks of work, not one.

### The pattern to repeat per phase

Each later phase gets the same treatment: one prompt per affected app, tasks with a grep-or-build
verification, and an explicit *Report back* list. Two rules learned from this round:

1. **Every file:line in a prompt was read from outside that repo, so state that** and invite
   correction. Several claims in the source briefs were stale for exactly this reason — one
   research pass concluded the app code was not on `main` at all, which turned out to be stale
   `~/conductor/repos/` checkouts 2–5 commits behind `origin/main`.
2. **Ask for the app's full RavonCore call surface every time.** For merchant and courier, which
   have zero `import Supabase`, that list *is* their entire coupling to the backend — and the
   claim that their cutover is cheap rests on it being accurate.
