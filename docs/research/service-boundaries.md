# Service boundary map — all 34 functions, 5 cron jobs, 5 phantom RPCs

Written by the orchestrator from `sql-function-catalogue.md` (the per-function READS/WRITES table),
`order-lifecycle-spec.md` §9 (the reconciled 41-edge graph), `app-courier-constraints.md` §1 (the
real offer feed), and `security-by-construction.md` §9 (the grant list). The brief asked for the
inventory's grouping to be **challenged**, not accepted; five of its decisions are overturned.

Criteria, applied in priority order:

1. Needs global state no single client can see → server-side
2. Writes money → ledger
3. Transitions order state → order
4. Must be atomic with an `auth.users` insert or another Supabase-owned operation → **stays in SQL, non-negotiable**
5. Pure or cheap in SQL with no cross-entity invariant → **stays in SQL**; moving it adds a network hop for nothing
6. Defence-in-depth that must survive a compromised or bypassed Kotlin service → **stays in SQL**
7. Dead → **delete**, and name the client that breaks

---

## 1. The fact that determines the whole map

**`orders` is written by 17 of the 34 functions, plus 5 direct client `UPDATE`s inside RavonCore.**

That is the real finding. Every interesting boundary question reduces to "who may write `orders`,"
and the answer cannot be "one module" — because four of those 17 writers are `pg_cron` sweeps that
should stay in SQL (§5), and they perform legitimate system-actor transitions that the 41-edge
graph declares.

So the design is not "the order module owns `orders`." It is:

> **One validated entry point, `app.order_transition(...)`, and the transition table lives in the
> database.** Both the Kotlin order module and the SQL sweeps call it. It looks up
> `(from, to, actor)` in `app.order_transitions` — a real table seeded from the 41-edge graph —
> rejects any undeclared edge, evaluates the guards, writes `orders`, and appends
> `order_status_history`. `ravon_app` holds **no direct `UPDATE` on `orders.status`**; only
> `order_transition` does.

This is strictly better than holding the state machine in Kotlin alone, and it is what the
project's own standard demands — *correctness enforced by something other than memory*. A Kotlin
table can be bypassed by the cron sweeps; a database table cannot be bypassed by anyone. It also
gives the Kotlin port a free conformance test: assert that the Kotlin transition table and
`app.order_transitions` contain the same 41 rows, which is exactly the check that would have
caught the 8-edge drift between `OrderLifecycle.swift` and migration 13/14/16.

---

## 2. Assignment table

`STAYS-SQL` = remains a SQL function, loses its client `GRANT EXECUTE` unless marked *keep grant*.

| # | Function | Destination | Why | vs inventory |
|---|---|---|---|---|
| 1 | `restaurant_within_hours` | **STAYS-SQL** *keep grant (anon)* | Pure, `STABLE`, reads `restaurant_hours` only. Criterion 5. | agrees |
| 2 | `restaurant_is_orderable` | **STAYS-SQL** *keep grant (anon)* | Same. Public browsing data. | agrees |
| 3 | `get_restaurant_orderability` | **STAYS-SQL** *keep grant (anon)* | Returns `{is_orderable_now, reason, opens_at}` — no non-public fields. Checked for leakage. | agrees |
| 4 | `validate_cart` | **order** | Reads 4 tables and encodes the pricing + availability + min-order contract the checkout saga must share. Documented as taking no locks, so it is advisory — the authoritative check is inside `create_order`. Keeping two copies of that contract in two languages is the drift this whole exercise exists to stop. | agrees |
| 5 | `create_order` | **order** | Writes `orders`, `order_items`, `menu_items.stock_count`; needs an idempotency key it has never had. The saga. | agrees |
| 6 | `set_accepting_orders` | **STAYS-SQL** | **Overturns the inventory** (it proposed `services/merchant`). Two owner-checked statements against `restaurants`. Restaurant *config*, not order state. No cross-entity invariant. Criterion 5. | **disagrees** |
| 7 | `activate_scheduled_order` | **STAYS-SQL** | Called only by the sweep. Writes `orders` — so it becomes a caller of `order_transition` rather than writing `status` itself. | **disagrees** |
| 8 | `activate_scheduled_orders` | **STAYS-SQL** (cron) | See §5. | **disagrees** |
| 9 | `generate_verification_code` | **REWRITE, STAYS-SQL** | Trigger. Must become hash-only + CSPRNG + 6 digits (security R12). **No `CREATE TRIGGER` exists in any migration** — its binding is unrecoverable and must be authored fresh. | agrees |
| 10 | `sync_order_delivery_mode_from_address` | **order** | **Overturns the inventory** (it said stays-SQL). The consumer's only direct `orders` write exists *because* this trigger owns delivery-mode resolution and the client cannot participate. Fold it into `create_order`'s `p_delivery_mode`, which is what removes that write. | **disagrees** |
| 11 | `earnings_tier_for_cancel` | **STAYS-SQL** | Pure `CASE`. Becomes the lookup table behind the ledger's tier resolution (`status_at_event` → pct). Criterion 5. | **disagrees** (inventory said ledger) |
| 12 | `earning_type_for_status` | **STAYS-SQL** | Pure `CASE`. Same. | **disagrees** |
| 13 | `insert_courier_earning_for_cancel` | **DELETE → ledger** | Writes money via `ON CONFLICT DO UPDATE`, which **destroys clawback history**, and takes an **unbounded tier override** (security N2). Replaced by a `ledger_post` call. Nothing survives. | agrees |
| 14 | `compute_eta_minutes` | **STAYS-SQL**, grant revoked | **Overturns the inventory** (it proposed dispatch). Pure read-only `STABLE` function over 4 tables. Moving it to Kotlin buys nothing (criterion 5) and the docs plan a Python ETA model later — so the *interface* belongs to dispatch while the implementation stays SQL and is swappable. Loses its client grant: ETA becomes a field on the order projection, not a client-callable RPC. | **disagrees** |
| 15 | `update_courier_heartbeat` | **SPLIT** — see §4 | The inventory assigns it nowhere. It is the hottest write path in the system and the cause of a fanout storm. | **fills the hole** |
| 16 | `claim_order` | **order** | Writes `orders` + `courier_locations.current_order_id`. Three guards. Via `order_transition`. | agrees |
| 17 | `courier_arrived_restaurant` | **order** | `orders` transition. | agrees |
| 18 | `courier_pickup_order` | **order** | `orders` transition + code verification. | agrees |
| 19 | `courier_start_delivering` | **order** | `orders` transition ×2 (stamps ETA). | agrees |
| 20 | `courier_arrived_at_customer` | **order** | `orders` transition. | agrees |
| 21 | `courier_deliver_order` | **order** + ledger call | Transition + earnings posting. Accepts `delivering` **and** `courier_arrived_customer` (drift 1). | agrees |
| 22 | `cancel_order_by_consumer` | **order** + ledger call | Transition + clawback. | agrees |
| 23 | `cancel_order_by_courier` | **order** + ledger call | Transition, clawback, `courier_cancellation_log` insert, cooldown check. | agrees |
| 24 | `report_problem_post_pickup` | **order** | Transition + system chat message. | agrees |
| 25 | `courier_explain_delay` | **order** | Transition + system chat message. | agrees |
| 26 | `reassign_ghosted_order` | **order**, grant revoked | **Has no authorization check whatsoever** (security N1) and is granted to `authenticated` — any user can requeue any order. Internal only. | agrees |
| 27 | `fetch_available_orders` | **DELETE** | Called zero times. `RETURNS SETOF orders`, so it leaks `verification_code` and `delivery_verification_code` to every courier. Replaced by dispatch's offer projection. No client breaks — nothing calls it. | **disagrees** (inventory kept it in dispatch) |
| 28 | `run_courier_escalation_ladder` | **STAYS-SQL** (cron) | See §5. Three passes with `FOR UPDATE SKIP LOCKED`; writes 5 tables. Its money write goes through `ledger_post`; its `orders` writes through `order_transition`. | **disagrees** |
| 29 | `set_chat_sender_role` | **STAYS-SQL** | Trigger; forces `sender_role` from `profiles`. Defence-in-depth against a client claiming to be `system`. Criterion 6. | agrees |
| 30 | `courier_report_customer_no_show` | **order** | Stamps `no_show_started_at`. | agrees |
| 31 | `mark_no_show_deliveries` | **STAYS-SQL** (cron) | See §5. Note drift 4: it transitions to **`delivered`**, not cancelled — a no-show is a *successful* delivery with full earnings. | **disagrees** |
| 32 | `courier_report_restaurant_delay` | **order** | **Overturns the inventory** (it proposed `services/merchant`). This is a **courier** action that transitions order state and posts a 50 % earning — it is not a merchant concern at all. | **disagrees** |
| 33 | `handle_new_user` | **STAYS-SQL, REWRITTEN** | Must be atomic with the `auth.users` insert — criterion 4, non-negotiable. **Must stop reading `role` from `raw_user_meta_data`**: insert `'consumer'` unconditionally. | agrees, with the fix |
| 34 | `profiles_block_role_change` | **STAYS-SQL** | Defence-in-depth. Criterion 6. Also add `ROLE_CHANGE_FORBIDDEN` to the Swift decoder, which migration 19's own comment promised and never delivered. | agrees |

### The 3 dashboard-only RPCs

| RPC | Destination | Note |
|---|---|---|
| `get_merchant_stats` | **order** (read model) | Definition died with the project. Draft body in `.context/plans/merchant-app-overhaul-*.md:228-243` has **no owner check** — a known finding. Rebuild with `OwnedRestaurantId`. |
| `find_nearby_couriers` | **DELETE** | Flagged unauthenticated. Its only purpose was courier discovery, which is now dispatch's internal concern, not a client RPC. |
| `add_tip` | **ledger** | Spec in `migration-20-*.md:91-99`. Clamp-vs-reject is an open product decision (consumer prompt §B). |

### The 5 phantom merchant RPCs — all NEW work in `order`

`merchant_accept_order`, `merchant_reject_order`, `merchant_start_preparing`,
`merchant_mark_order_ready`, `merchant_cancel_order`. Named in `OrderLifecycle.swift`, defined
nowhere. The first four are implemented today as direct client `UPDATE`s with a compare-and-swap
guard; the fifth has no implementation at all, so **the merchant cannot cancel an order** and
`cancelled_by_restaurant` is model-reachable but operationally dead.

The four CAS predicates are the specification — they document the from-states exactly. The new
RPCs must also **distinguish the two failure modes the CAS conflates**: an empty result set today
means either "someone else moved it" or "it was cancelled underneath you," and the merchant sees
one message for both (merchant prompt §A).

---

## 3. The five `pg_cron` jobs — the inventory says move them; nothing forces that

The inventory proposes "Kotlin scheduled workers, replacing `pg_cron`." `02-TARGET-ARCHITECTURE.md:151`
says the opposite: *"`pg_cron` already does the job; the escalation ladder is written."*

**`02` is right, and this deletes a phase from the plan.** What would moving them buy? Nothing:

- All five are pure SQL over Postgres tables. No external I/O, no API calls, no ML.
- `run_courier_escalation_ladder` and `mark_no_show_deliveries` use `FOR UPDATE SKIP LOCKED`.
  Re-implementing that correctly in Kotlin means either accepting duplicate concurrent runs or
  adding leader election — new failure modes in exchange for nothing.
- A Kotlin scheduler in a single deployable that must be up for orders to exist adds a second
  reason for the sweeps to stop. `pg_cron` stops only when Postgres stops, and if Postgres is down
  nothing else works either.

What *must* change about them, though, is not scheduling:

| Job | Schedule | Change required |
|---|---|---|
| `auto_resume_accepting_orders` | `*/5 * * * *` | none |
| `activate_scheduled_orders` | `* * * * *` | `orders` writes go through `order_transition`. **Missing from the inventory's job list.** |
| `purge_soft_deleted_menu` | `0 3 * * *` | **Inline SQL in the cron body — no wrapper function.** Any port must reconstruct it from `07_…:9-15`. **Missing from the inventory's list.** |
| `courier_escalation_ladder` | `* * * * *` | `orders` → `order_transition`; money → `ledger_post`; **revoke its client `GRANT EXECUTE`** |
| `mark_no_show_deliveries` | `* * * * *` | `orders` → `order_transition`; **revoke its client `GRANT EXECUTE`** |

Three of these are currently granted to `authenticated` — **any signed-in user can trigger a
market-wide sweep.** They run as a dedicated `ravon_cron` role and are not in the PostgREST-exposed
schema (security R16). That is the actual fix, and it is a grant change, not a rewrite.

---

## 4. `update_courier_heartbeat` — the hole in the inventory, and the answer splits it

The inventory assigns it to no service. It is the highest-frequency write in the system (rate
limiter ceiling: one per courier per second), the only writer of the smart-ghost fraud signals
`last_moved_at` / `accuracy_meters`, the enforcer of suspension, **and** it writes
`orders.eta_minutes` for every active delivery.

That last clause is the problem. From `app-courier-constraints.md` §1: every heartbeat writes
`orders` → every `orders` write fires the **unfiltered** `available-orders` realtime channel →
every idle courier runs a full `orders` scan. That is roughly **A × C / 5 full-table selects per
second** for A active deliveries and C idle couriers. The hottest write path in the system is
wired to a broadcast.

**Decision: split it three ways, and none of the three is a Kotlin request-path write.**

| Concern | Destination | Why |
|---|---|---|
| Position ingest (`courier_locations` upsert: lat, lng, heading, speed, accuracy, `last_moved_at`, ghost strikes) | **STAYS-SQL**, client-called via PostgREST | A per-courier row with no cross-entity invariant — exactly the class §2.2 of the plan keeps client-written under RLS. Routing a 5-second ping through a Kotlin unary call adds a hop, a JWT verification, and a JVM wake-up for zero correctness gain. |
| **`orders.eta_minutes` write** | **REMOVED** | The fanout storm. ETA is a pure function of position and order (`compute_eta_minutes` is `STABLE`) — compute it **on read**, as a field on the order projection, or let the dispatch module push it on its own cadence. Do not write `orders` as a side effect of a location ping. This single deletion removes the `A × C / 5` amplification. |
| Suspension enforcement | **interceptor** | Already required: §5.2 of the plan reloads authorization state from the database on every privileged call precisely because JWT revocation lags ~20 min. A suspended courier is stopped there, not by a heartbeat's `RAISE`. |

So `update_courier_heartbeat` stays in SQL, shrinks, and stops being an `orders` writer. The
`ACCURACY_TOO_LOW` / `COURIER_SUSPENDED` / `NOT_AUTHENTICATED` errors it raises survive as-is.

---

## 5. No `services/merchant`

The inventory proposes a module for three functions. All three leave:

- `set_accepting_orders` → stays in SQL (restaurant config, owner-checked, two statements)
- `get_merchant_stats` → `order` (it is a read model over `orders`)
- `courier_report_restaurant_delay` → `order` (it is a **courier** action that transitions order
  state and posts an earning; classifying it as "merchant" was a naming error)

A module for three functions, one of which is misclassified and one of which should not move, is
not a boundary. It is a directory.

---

## 6. Write-ownership matrix — every shared table resolved

Two writers on one table is the failure mode. Every case, and how it is resolved:

| Table | Writers after the split | Resolution |
|---|---|---|
| **`orders`** | `order` module (Kotlin) **and** 4 SQL cron sweeps | **`app.order_transition(...)` is the only writer of `status`.** Both call it; it validates against the `app.order_transitions` table. `ravon_app` gets column-level `UPDATE` on the non-status columns only. |
| **`order_items`** | `order` only | Clean. No client grant. |
| **`order_status_history`** | `order_transition` only (appends) | Append-only; `UPDATE`/`DELETE` revoked from every role. |
| **`ledger_entries`** | `ledger_post` only | `ravon_app` has **no** `INSERT`. Owned by a role the service cannot assume. The escalation ladder's clawback also calls `ledger_post`. |
| **`courier_earnings`** | nobody — **retired** | Becomes a view over ledger postings, or is dropped. It is current-state, not a journal. |
| **`courier_locations`** | heartbeat (client, position columns) **and** `order` module (`current_order_id`) | **Column-level grants.** Client gets `UPDATE (latitude, longitude, heading, speed, accuracy_meters, last_moved_at, …)`; `ravon_app` gets `UPDATE (current_order_id)`. Disjoint sets, enforced by Postgres. |
| **`menu_items.stock_count`** | `order` module (`create_order`) and `activate_scheduled_order` (SQL) | Both decrement stock as part of order creation. Fold the scheduled path through the order module's own creation routine, or give `activate_scheduled_order` the same `ravon_app` column grant. Prefer the former. |
| **`restaurants`** | `set_accepting_orders` (SQL, owner-checked) and `auto_resume_accepting_orders` (cron) | Same two columns, same semantics, one is the timed undo of the other. Fine. |
| **`profiles`** | `handle_new_user` (SQL trigger, INSERT) and the ladder (`is_suspended_until`) | Different columns. **No role writer at all** — `role` is an operator-only column with its own audit trail (security R1). |
| **`chat_messages`** | clients (INSERT) and 5 SQL functions (system messages) | Append-only; `set_chat_sender_role` trigger forces the role, so a client cannot forge `system`. Fine. |
| **`courier_cancellation_log`** | `order` module only | Clean. |

---

## 7. Per-module summary

**`order`** — the big one. Owns `orders` (through `order_transition`), `order_items`,
`order_status_history`, `courier_cancellation_log`, `menu_items.stock_count`,
`courier_locations.current_order_id`. 17 RPCs: 13 existing lifecycle functions + 5 new merchant
RPCs + `validate_cart` + `get_merchant_stats`, minus the ones folded. Calls `ledger_post` for every
money event.

**`dispatch`** — owns no tables. Reads `courier_locations`, `orders`, `restaurants`, `addresses`.
Exposes `Assign` and the courier offer projection. Owns the *interface* to `compute_eta_minutes`
so a Python model can replace the implementation.

**`ledger`** — owns nothing directly; a facade over `db/ledger/`'s `ledger_post`. 4 RPCs:
`PostTransaction`, `GetBalance`, `ListEntries`, `GetEarnings`. Plus `add_tip`.

**Stays in SQL** — 13 functions: the orderability trio (anon-granted), `set_accepting_orders`,
`activate_scheduled_order(s)`, `generate_verification_code` (rewritten), `earnings_tier_for_cancel`,
`earning_type_for_status`, `compute_eta_minutes`, `set_chat_sender_role`, `handle_new_user`
(rewritten), `profiles_block_role_change`, plus a shrunken `update_courier_heartbeat`. Five cron
jobs keep running. **Eleven of these lose their client `GRANT EXECUTE`.**

**Deleted** — 3: `insert_courier_earning_for_cancel`, `fetch_available_orders`,
`find_nearby_couriers`. None has a client that breaks.

---

## 8. Where this map disagrees with the inventory, summarised

| Inventory said | This map says | Because |
|---|---|---|
| 4 pg_cron functions → Kotlin workers | **stay in SQL**, lose their client grants | Nothing forces them out; moving them adds leader election for zero gain. `02` was right. Deletes a phase. |
| `services/merchant` (3 functions) | **no such module** | One misclassified, one should not move, one is a read model. |
| `compute_eta_minutes` → dispatch | **stays in SQL**, dispatch owns the interface | Pure `STABLE` read function; a Python model replaces it later. |
| `earnings_tier_for_cancel`, `earning_type_for_status` → ledger | **stay in SQL** | Pure `CASE` lookups. They become the ledger's tier table. |
| `fetch_available_orders` → dispatch | **delete** | Zero callers, and it leaks both verification codes. |
| `sync_order_delivery_mode_from_address` stays in SQL | **→ order** | It is *why* the consumer writes `orders` directly. |
| `set_accepting_orders` → merchant module | **stays in SQL** | Restaurant config, owner-checked, no invariant. |
| `update_courier_heartbeat` — unassigned | **split 3 ways**, and its `orders` write **deleted** | It is the fanout storm. |
| "6 stay in SQL" (lists 8) | **13 stay in SQL** | Arithmetic error in the inventory, plus the overturns above. |
