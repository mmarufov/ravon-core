# SQL function catalogue — `.context/migrations/01–19`

Compiled 2026-09-16 by direct read of all 19 migration files (2,555 lines) plus the
21 Swift `rpc(...)` call sites. Every claim below cites `file:line`. Nothing here is
inferred from the inventory doc; where the inventory disagrees it is called out.

---

## 1. Headline counts

| Thing | Real number | Inventory claim | Verdict |
|---|---|---|---|
| Unique SQL function names | **34** | 34 | **correct** (but by a non-obvious route — see 1.1) |
| `CREATE OR REPLACE FUNCTION` statements | **39** | not stated | 5 are redefinitions |
| `CREATE TRIGGER` statements | **4** | 4 | correct |
| Trigger-returning functions | **5** | implied 4 | **1 trigger function has no `CREATE TRIGGER`** (see 1.2) |
| `pg_cron` jobs scheduled | **5** | 3 | **WRONG — see 1.3** |
| `RAISE EXCEPTION` statements | **63** | not stated | — |
| Distinct `DETAIL.reason` strings | **29** | not stated | Swift decoder handles only 18 (see §6) |
| `CREATE TABLE` statements | **1** (`courier_cancellation_log`) | 1 | correct |
| `CREATE VIEW` statements | **1** (`restaurants_orderable`) | not stated | — |
| RPCs Swift calls | **21** | 21 | correct |
| Swift-called RPCs absent from all migrations | **3** | 3 | **correct** (see §5b) |

### 1.1 How 34 is reached

39 `CREATE OR REPLACE FUNCTION` statements exist. Five functions are defined twice:

| Function | First definition | Redefinition | Signature identical? |
|---|---|---|---|
| `run_courier_escalation_ladder()` | `14_courier_escalation_ladder_cron.sql:18` | `17_system_messages_sender_role_fix.sql:18` | yes |
| `courier_explain_delay(uuid,text,text)` | `13_courier_status_transition_rpcs_v2.sql:606` | `17_system_messages_sender_role_fix.sql:112` | yes |
| `report_problem_post_pickup(uuid,text,text)` | `13_courier_status_transition_rpcs_v2.sql:564` | `17_system_messages_sender_role_fix.sql:155` | yes |
| `courier_report_customer_no_show(uuid)` | `16_no_show_and_restaurant_delay.sql:14` | `17_system_messages_sender_role_fix.sql:193` | yes |
| `courier_report_restaurant_delay(uuid,int)` | `16_no_show_and_restaurant_delay.sql:78` | `17_system_messages_sender_role_fix.sql:227` | yes |

Because all five redefinitions keep the exact argument list, `CREATE OR REPLACE`
**replaces** rather than overloads — no duplicate `pg_proc` rows. 39 − 5 = **34**.
Migration 17's only behavioural change in each is adding `sender_role` to the
`chat_messages` INSERT column list.

### 1.2 `generate_verification_code` has no trigger in any migration

`10_dual_verification_codes_and_delivery_mode.sql:33` says *"Update the existing INSERT
trigger function"* and replaces the function body at `:34`, but no migration ever issues
`CREATE TRIGGER` for it. The four `CREATE TRIGGER` statements are:

- `orders_sync_delivery_mode` — `10_dual_verification_codes_and_delivery_mode.sql:71`
- `chat_messages_set_sender_role` — `15_chat_rls_and_sender_role.sql:35`
- `on_auth_user_created` — `18_handle_new_user_trigger.sql:36`
- `profiles_block_role_change` — `19_lock_down_profile_role.sql:35`

The trigger name, timing and table binding for `generate_verification_code` are
**UNKNOWN — needs live introspection** (the project is deleted, so they are now
unrecoverable from this repo).

### 1.3 CORRECTION: there are 5 cron jobs, not 3

`12-BACKEND-INVENTORY.md:18` lists three: accepting-orders flip, `courier_escalation_ladder`,
`mark_no_show_deliveries`. Actual `cron.schedule` calls:

| Job name | Schedule | Defined at | In inventory? |
|---|---|---|---|
| `auto_resume_accepting_orders` | `*/5 * * * *` | `05_set_accepting_orders_with_until.sql:46` | yes |
| `purge_soft_deleted_menu` | `0 3 * * *` | `07_soft_delete_purge_cron.sql:5` | **NO** |
| `activate_scheduled_orders` | `* * * * *` | `06_scheduled_orders.sql:110` | **NO** |
| `courier_escalation_ladder` | `* * * * *` | `14_courier_escalation_ladder_cron.sql:120` | yes |
| `mark_no_show_deliveries` | `* * * * *` | `16_no_show_and_restaurant_delay.sql:145` | yes |

Two of the five are missing from the boundary map. `purge_soft_deleted_menu` is
**inline SQL in the cron body** (no wrapper function) — it is the only scheduled
job with no corresponding SQL function, so a Kotlin worker port must reconstruct it
from `07_soft_delete_purge_cron.sql:9-15`, not from any function.

---

## 2. The catalogue

Conventions: "VOLATILE (implicit)" means no volatility keyword was written, so Postgres
defaults to VOLATILE. "INVOKER (implicit)" means no `SECURITY DEFINER` keyword.
Tables listed under WRITES include writes performed by helper functions the body
`PERFORM`s, marked `(via helper)`.

---

### 2.1 `restaurant_within_hours`

- **Location**: `03_orderability_function_and_view.sql:6`
- **Args**: `p_restaurant uuid, p_at timestamptz DEFAULT now()`
- **Returns**: `boolean` · **Lang**: plpgsql · **STABLE** · **SECURITY DEFINER** · `SET search_path = public`
- **READS**: `restaurant_hours`
- **WRITES**: none
- **RAISE**: none
- **GRANT EXECUTE**: `authenticated, anon` (`:152`)
- Notes: hardcodes `Asia/Dushanbe` (`:22`). Missing hours row ⇒ returns `true` (always-open), `:33-35`. `opening_time = closing_time` is the intentional closed marker, `:41-43`. Handles past-midnight windows, `:47-50`.

### 2.2 `restaurant_is_orderable`

- **Location**: `03_orderability_function_and_view.sql:55`
- **Args**: `p_restaurant uuid, p_at timestamptz DEFAULT now()`
- **Returns**: `boolean` · **Lang**: sql · **STABLE** · **SECURITY DEFINER** · `SET search_path = public`
- **READS**: `restaurants`, `restaurant_hours` (via 2.1)
- **WRITES**: none
- **RAISE**: none
- **GRANT EXECUTE**: `authenticated, anon` (`:153`)
- Notes: only consumer is the view `restaurants_orderable` (`:73-77`), which is `GRANT SELECT ... TO authenticated, anon` (`:79`).

### 2.3 `get_restaurant_orderability`

- **Location**: `03_orderability_function_and_view.sql:83`
- **Args**: `p_restaurant_id uuid, p_at timestamptz DEFAULT now()`
- **Returns**: `jsonb` · **Lang**: plpgsql · **STABLE** · **SECURITY DEFINER** · `SET search_path = public`
- **READS**: `restaurants`, `restaurant_hours` (via 2.1)
- **WRITES**: none
- **RAISE**: none — signals via the returned payload, not exceptions
- **Return payload `reason.kind` values**: `RESTAURANT_CLOSED` (`:102`, `:110`), `RESTAURANT_PAUSED` (`:118`), `RESTAURANT_NOT_ACCEPTING` + `until` (`:127-128`), `OUT_OF_HOURS` + `opens_at` (`:139`), `OK` (`:146`)
- **GRANT EXECUTE**: `authenticated, anon` (`:154`)
- Notes: declares `hours_today restaurant_hours%ROWTYPE` at `:96` and never uses it. `opens_at` is hardcoded `null` in every branch (`:103,111,119,130,140,147`) — the client is expected to compute it, per the comment at `:135-136`.

### 2.4 `validate_cart`

- **Location**: `04_create_order_v3_and_validate_cart.sql:6`
- **Args**: `p_restaurant_id uuid, p_items jsonb, p_scheduled_for timestamptz DEFAULT NULL`
- **Returns**: `jsonb` · **Lang**: plpgsql · **STABLE** · **SECURITY DEFINER** · `SET search_path = public`
- **READS**: `restaurants`, `orders` (concurrency count), `menu_items`, `restaurant_hours` (via 2.1)
- **WRITES**: none — no row locks, explicitly documented at `:4`
- **RAISE**: none
- **Return payload `reason.kind`**: `OK` (`:20`), `RESTAURANT_CLOSED` (`:33`, `:43`), `RESTAURANT_PAUSED` (`:46`), `RESTAURANT_NOT_ACCEPTING` + `until` (`:49`), `OUT_OF_HOURS` + `opens_at` (`:52`), `OVERLOADED` (`:66`), `MIN_ORDER_NOT_MET` + `need` (`:102`)
- **Per-item `status`**: `DELETED` (`:82`), `UNAVAILABLE` (`:84`), `INSUFFICIENT_STOCK` + `have` (`:88-89`), `OK` (`:93`)
- **GRANT EXECUTE**: `authenticated` (`:118`)
- Notes: `UNAVAILABLE` and `DELETED` do **not** set `orderable := false` (`:82-84`) — only `INSUFFICIENT_STOCK` (`:91`) and the min-order check (`:104`) do. So a cart containing a deleted item can come back `orderable: true`, and the subsequent `create_order` will hard-fail with `ITEM_UNAVAILABLE`.

### 2.5 `create_order`

- **Location**: `04_create_order_v3_and_validate_cart.sql:127`
- **Args**: `p_restaurant_id uuid, p_address_id uuid, p_items jsonb, p_notes text DEFAULT NULL, p_scheduled_for timestamptz DEFAULT NULL`
- **Returns**: `uuid` · **Lang**: plpgsql · **VOLATILE (implicit)** · **SECURITY DEFINER** · `SET search_path = public`
- **READS**: `restaurants` (`FOR UPDATE`, `:153`), `orders` (`:188`), `addresses` (`:202`), `menu_items` (`FOR UPDATE`, `:212`; again `:256`)
- **WRITES**: `orders` INSERT (`:238`), `order_items` INSERT (`:257`), `menu_items` UPDATE `stock_count` (`:267`)
- **RAISE** (10, all `ERRCODE = 'P0001'`):

| Line | Message | DETAIL |
|---|---|---|
| `:155` | `restaurant_closed` | `{"reason":"RESTAURANT_CLOSED"}` |
| `:159` | `restaurant_paused` | `{"reason":"RESTAURANT_PAUSED"}` |
| `:163` | `restaurant_not_active` | `{"reason":"RESTAURANT_CLOSED"}` ← same reason, different message |
| `:167` | `restaurant_not_accepting` | `{"reason":"RESTAURANT_NOT_ACCEPTING","until":<accepting_orders_until>}` |
| `:173` | `restaurant_out_of_hours` | `{"reason":"OUT_OF_HOURS"}` |
| `:181` | `scheduled_time_invalid` | `{"reason":"SCHEDULED_TIME_INVALID"}` |
| `:196` | `restaurant_overloaded` | `{"reason":"OVERLOADED"}` |
| `:214` | `item_unavailable` | `{"reason":"ITEM_UNAVAILABLE","menu_item_id":<uuid>}` |
| `:219` | `insufficient_stock` | `{"reason":"INSUFFICIENT_STOCK","menu_item_id":<uuid>,"have":<int>}` |
| `:231` | `min_order_not_met` | `{"reason":"MIN_ORDER_NOT_MET","need":<numeric>}` |

- **GRANT EXECUTE**: `authenticated` (`:277`)
- Notes: schedule window is `now()+5min .. now()+7days` (`:179-180`). Total is `subtotal + delivery_fee` only — no tax, no tip (`:236`). `modifiers_snapshot` is hardcoded `'[]'` (`:263`) despite migration 02 adding the column for real modifier data.
- **Defect**: no ownership check on `p_address_id`. `:202` snapshots *any* `addresses` row into `orders.delivery_address_snapshot`, and `:244` writes `p_address_id` into the order. A caller who knows another user's address UUID can create an order against it and read the whole address row back from their own order. There is also no `NOT FOUND` guard — a bogus address id yields a NULL snapshot and the order is still created.

### 2.6 `set_accepting_orders`

- **Location**: `05_set_accepting_orders_with_until.sql:7`
- **Args**: `p_restaurant_id uuid, p_accepting boolean, p_until timestamptz DEFAULT NULL`
- **Returns**: `void` · **Lang**: plpgsql · **VOLATILE (implicit)** · **SECURITY DEFINER** · `SET search_path = public`
- **READS**: `restaurants` (`:21`)
- **WRITES**: `restaurants` (`:31`, `:35`)
- **RAISE**: `:26` — `RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';` — **no `DETAIL` at all**
- **GRANT EXECUTE**: `authenticated` (`:42`)
- **Defect**: this is the only owner-gated RPC in the whole surface that emits no structured `DETAIL`. `ServiceError.from(serverError:)` regexes for `"reason":"<KIND>"` (`Sources/RavonCore/Services/SupabaseService.swift:97`) and therefore returns `nil` here. Any Kotlin port must add a reason (`MERCHANT_NOT_OWNER` is the name used in `.context/plans/migration-20-lock-orders-to-rpc-only-writes-dev-aw.md:151`).

### 2.7 `activate_scheduled_order`

- **Location**: `06_scheduled_orders.sql:21`
- **Args**: `p_order_id uuid`
- **Returns**: `void` · **Lang**: plpgsql · **VOLATILE (implicit)** · **SECURITY DEFINER** · `SET search_path = public`
- **READS**: `orders` (`FOR UPDATE`, `:33`), `restaurants` (`FOR UPDATE`, `:38`), `order_items` (`:51`), `menu_items` (`FOR UPDATE`, `:61`), `restaurant_hours` (via 2.1)
- **WRITES**: `orders` (`:41`, `:55`, `:63`, `:70`, `:81`), `menu_items` (`:77`)
- **RAISE**: none — failures are expressed as `status = 'cancelled_by_system'` with `cancellation_reason` set to the free-text strings `RESTAURANT_NOT_OPEN_AT_SCHEDULED_TIME` (`:42`), `ITEM_DELETED` (`:56`), `ITEM_UNAVAILABLE` (`:64`), `INSUFFICIENT_STOCK` (`:71`)
- **GRANT EXECUTE**: `authenticated` (`:107`)
- **Defect**: SECURITY DEFINER, granted to `authenticated`, and performs **zero** authorization checks. Any logged-in user can force-activate (or force-system-cancel) any other user's scheduled order by UUID.
- Note: it writes the typed codes into the legacy free-text `cancellation_reason` column, not `cancellation_reason_code`, even though `09_cancellation_reason_code_and_courier_cancel_log.sql:31-32` added all four to the `cancellation_reason_code_valid` CHECK whitelist specifically for this path.

### 2.8 `activate_scheduled_orders`

- **Location**: `06_scheduled_orders.sql:86`
- **Args**: none
- **Returns**: `void` · **Lang**: plpgsql · **VOLATILE (implicit)** · **SECURITY DEFINER** · `SET search_path = public`
- **READS**: `orders`, `restaurants` (`:96-100`)
- **WRITES**: everything 2.7 writes, via `PERFORM activate_scheduled_order` (`:102`)
- **RAISE**: none
- **GRANT EXECUTE**: **none** — correctly cron-only
- Note: lead time is `scheduled_for − COALESCE(restaurants.delivery_time_min, 30) minutes` (`:100`).

### 2.9 `generate_verification_code`

- **Location**: `10_dual_verification_codes_and_delivery_mode.sql:34`
- **Args**: none · **Returns**: `trigger` · **Lang**: plpgsql
- **VOLATILE (implicit)** · **SECURITY INVOKER (implicit)** · **no `SET search_path`**
- **READS / WRITES**: none — mutates `NEW.verification_code` (`:38`) and `NEW.delivery_verification_code` (`:41`)
- **RAISE**: none · **GRANT EXECUTE**: none
- **Trigger binding**: none in any migration (see §1.2)
- Note: codes are `lpad(floor(random()*9000+1000), 4, '0')` — i.e. 1000–9999, 9,000 possibilities, non-cryptographic `random()`. Both the pickup and the delivery code come from the same generator.

### 2.10 `sync_order_delivery_mode_from_address`

- **Location**: `10_dual_verification_codes_and_delivery_mode.sql:55`
- **Args**: none · **Returns**: `trigger` · **Lang**: plpgsql
- **VOLATILE (implicit)** · **SECURITY INVOKER (implicit)** · **no `SET search_path`**
- **READS**: `addresses` (`:61`)
- **WRITES**: mutates `NEW.delivery_mode` (`:63`)
- **RAISE**: none · **GRANT EXECUTE**: none
- **Trigger**: `orders_sync_delivery_mode BEFORE INSERT ON orders FOR EACH ROW` (`:71-73`)
- Note: unconditionally overwrites any client-supplied `delivery_mode` with the address default — `delivery_mode` is therefore not settable per-order at INSERT time.

### 2.11 `earnings_tier_for_cancel`

- **Location**: `12_tiered_earnings_columns_and_helpers.sql:35`
- **Args**: `p_status_at_cancel order_status` · **Returns**: `int`
- **Lang**: sql · **IMMUTABLE** · **SECURITY INVOKER (implicit)** · **no `SET search_path`**
- **READS / WRITES**: none (pure `CASE`)
- **RAISE**: none · **GRANT EXECUTE**: `authenticated` (`:103`)
- Mapping: `assigned`→25, `courier_arrived_restaurant`→50, `picked_up`/`delivering`/`courier_arrived_customer`→100, else 0 (`:38-43`)

### 2.12 `earning_type_for_status`

- **Location**: `12_tiered_earnings_columns_and_helpers.sql:47`
- **Args**: `p_status order_status` · **Returns**: `text`
- **Lang**: sql · **IMMUTABLE** · **SECURITY INVOKER (implicit)** · **no `SET search_path`**
- **READS / WRITES**: none · **RAISE**: none · **GRANT EXECUTE**: `authenticated` (`:104`)
- Mapping: `assigned`→`partial_assigned`, `courier_arrived_restaurant`→`partial_at_restaurant`, `picked_up`/`delivering`/`courier_arrived_customer`→`partial_picked_up_lost`, else `manual_adjustment` (`:50-55`)

### 2.13 `insert_courier_earning_for_cancel`

- **Location**: `12_tiered_earnings_columns_and_helpers.sql:61`
- **Args**: `p_order_id uuid, p_courier_id uuid, p_status_at_cancel order_status, p_reason_code text, p_tier_override int DEFAULT NULL, p_earning_type_override text DEFAULT NULL`
- **Returns**: `void` · **Lang**: plpgsql · **VOLATILE (implicit)** · **SECURITY DEFINER** · `SET search_path = public`
- **READS**: `orders` (`:79`)
- **WRITES**: `courier_earnings` — `INSERT ... ON CONFLICT (order_id) DO UPDATE` (`:87-99`)
- **RAISE**: none — silently `RETURN`s when the order has no `delivery_fee` (`:80`)
- **GRANT EXECUTE**: **none** — correct; only reachable from other SECURITY DEFINER functions
- Note: amount = `round(delivery_fee * tier / 100.0, 2)` (`:84`); negative `p_tier_override` (−100) is how clawbacks are expressed. `tip_amount` is hardcoded 0 (`:91`), and the `ON CONFLICT` update deliberately does **not** touch `tip_amount` — this is the seam that makes a post-delivery `add_tip` inconsistent (`.context/resume-evidence-ravon.md:253`).

### 2.14 `compute_eta_minutes`

- **Location**: `13_courier_status_transition_rpcs_v2.sql:19`
- **Args**: `p_order_id uuid` · **Returns**: `int`
- **Lang**: plpgsql · **STABLE** · **SECURITY DEFINER** · `SET search_path = public, extensions`
- **READS**: `orders` (`:35`), `courier_locations` (`:37`), `restaurants` (`:41`), `addresses` (`:45`, `:47`)
- **WRITES**: none
- **RAISE**: none — returns `NULL` on every unresolvable case (`:36`, `:38`, `:50`)
- **GRANT EXECUTE**: `authenticated` — granted **twice**, `:63` and `:739`
- Note: PostGIS `ST_Distance` on geography (`:53`); speed fallback 25 km/h (`:57`); `GREATEST(1, CEIL(...))` (`:59`). Target switches from restaurant to delivery address at `picked_up` (`:40`).

### 2.15 `update_courier_heartbeat`  ← the unassigned function

- **Location**: `13_courier_status_transition_rpcs_v2.sql:72`
- **Args**: `p_latitude double precision, p_longitude double precision, p_accuracy_meters double precision DEFAULT NULL, p_heading double precision DEFAULT NULL, p_speed double precision DEFAULT NULL`
- **Returns**: `void` · **Lang**: plpgsql · **VOLATILE (implicit)** · **SECURITY DEFINER** · `SET search_path = public, extensions`
- **READS**: `profiles` (`:95`), `courier_locations` (`:109`)
- **WRITES**: `courier_locations` UPDATE (`:115`) or INSERT (`:127`); `orders` UPDATE `eta_minutes, updated_at` (`:137`)
- **RAISE** (3, all `ERRCODE='P0001'`):

| Line | Message | DETAIL |
|---|---|---|
| `:91` | `not_authenticated` | `{"reason":"NOT_AUTHENTICATED"}` |
| `:97` | `courier_suspended` | `{"reason":"COURIER_SUSPENDED","until":<timestamptz>}` |
| `:103` | `accuracy_too_low` | `{"reason":"ACCURACY_TOO_LOW","accuracy":<double>}` |

- **GRANT EXECUTE**: `authenticated` — granted **twice**, `:143` and `:740`
- Behaviour: soft rate limit silently `RETURN`s if last heartbeat < 1 s ago (`:112`); `accuracy_meters > 200` is rejected (`:102`); `last_moved_at` advances only on >25 m movement (`:123`) — the anti-stationary-fraud signal.
- **This is the function the inventory's destination grouping omits.** See §5c.

### 2.16 `claim_order`

- **Location**: `13_courier_status_transition_rpcs_v2.sql:148`
- **Args**: `p_order_id uuid` · **Returns**: `uuid`
- **Lang**: plpgsql · **VOLATILE (implicit)** · **SECURITY DEFINER** · `SET search_path = public`
- **READS**: `profiles` (`:163`, `:168`), `courier_locations` (`:174`), `orders` (`:180`; `FOR UPDATE` at `:190-192`)
- **WRITES**: `orders` (`:206`, `:217`), `courier_locations` (`:214`)
- **RAISE** (7, all `ERRCODE='P0001'`):

| Line | Message | DETAIL |
|---|---|---|
| `:164` | `unauthorized` | `{"reason":"UNAUTHORIZED"}` |
| `:170` | `courier_suspended` | `{"reason":"COURIER_SUSPENDED","until":<timestamptz>}` |
| `:176` | `courier_must_be_online` | `{"reason":"COURIER_MUST_BE_ONLINE"}` |
| `:186` | `courier_busy` | `{"reason":"COURIER_ALREADY_HAS_ACTIVE_ORDER","order_id":<uuid>}` |
| `:194` | `order_not_found` | `{"reason":"ORDER_NOT_FOUND"}` |
| `:198` | `order_no_longer_pickupable` | `{"reason":"ORDER_NO_LONGER_PICKUPABLE","status":<order_status>}` |
| `:202` | `courier_excluded` | `{"reason":"COURIER_EXCLUDED_FROM_ORDER"}` |

- **GRANT EXECUTE**: `authenticated` (`:741`)
- Claimable statuses: `accepted`, `preparing`, `ready` (`:197`). SLA stamp `now() + 8 minutes` (`:210`).
- **Defect**: `RETURN v_uid` (`:219`) returns the **caller's own courier id**, not the order id or anything the caller doesn't already know. `Sources/RavonCore/Services/SupabaseService.swift:759-769` decodes it as a `UUID` and returns it from `claimOrder(orderId:) -> UUID`, so the Swift signature promises information the RPC never supplies. The `busy` check at `:180-184` is also not `FOR UPDATE`, so two concurrent claims by the same courier can both pass it.

### 2.17 `courier_arrived_restaurant`

- **Location**: `13_courier_status_transition_rpcs_v2.sql:226`
- **Args**: `p_order_id uuid` · **Returns**: `void`
- **Lang**: plpgsql · **VOLATILE (implicit)** · **SECURITY DEFINER** · `SET search_path = public`
- **READS**: none beyond the UPDATE predicate · **WRITES**: `orders` (`:236`)
- **RAISE**: `:249` `invalid_status_transition`, `ERRCODE='P0001'`, `{"reason":"INVALID_STATUS_TRANSITION"}` — **no `status` payload**, unlike its siblings
- **GRANT EXECUTE**: `authenticated` (`:742`)
- Guard is `courier_id = auth.uid() AND status = 'assigned'` folded into the UPDATE, detected via `GET DIAGNOSTICS ROW_COUNT` (`:247`). Consequence: order-not-found, wrong-courier and wrong-status all collapse into one indistinguishable error. New SLA `now() + 6 minutes` (`:239`).

### 2.18 `courier_pickup_order`

- **Location**: `13_courier_status_transition_rpcs_v2.sql:258`
- **Args**: `p_order_id uuid, p_verification_code text` · **Returns**: `void`
- **Lang**: plpgsql · **VOLATILE (implicit)** · **SECURITY DEFINER** · `SET search_path = public`
- **READS**: `orders` `FOR UPDATE` (`:270-271`) · **WRITES**: `orders` (`:289`)
- **RAISE** (4, all `ERRCODE='P0001'`):

| Line | Message | DETAIL |
|---|---|---|
| `:273` | `order_not_found` | `{"reason":"ORDER_NOT_FOUND"}` |
| `:277` | `unauthorized` | `{"reason":"UNAUTHORIZED"}` |
| `:281` | `order_no_longer_pickupable` | `{"reason":"ORDER_NO_LONGER_PICKUPABLE","status":<order_status>}` |
| `:285` | `invalid_verification_code` | `{"reason":"INVALID_VERIFICATION_CODE"}` |

- **GRANT EXECUTE**: `authenticated` (`:743`)
- **Defect**: `IF v_code IS DISTINCT FROM p_verification_code` (`:284`). When `orders.verification_code IS NULL`, passing `NULL` makes `NULL IS DISTINCT FROM NULL` false and the check **passes with no code**. Migration 10's backfill (`:48-52`) only covered non-terminal orders, so NULL codes are reachable. Same shape in `courier_deliver_order` (2.21). A Kotlin port must use an explicit `code IS NULL OR code <> input` guard. New SLA is `now() + 1 minute` (`:292`).

### 2.19 `courier_start_delivering`

- **Location**: `13_courier_status_transition_rpcs_v2.sql:304`
- **Args**: `p_order_id uuid` · **Returns**: `void`
- **Lang**: plpgsql · **VOLATILE (implicit)** · **SECURITY DEFINER** · `SET search_path = public`
- **READS**: `orders`/`courier_locations`/`restaurants`/`addresses` via `compute_eta_minutes` (`:329`) · **WRITES**: `orders` twice (`:314`, `:330`)
- **RAISE**: `:325` `invalid_status_transition`, `ERRCODE='P0001'`, `{"reason":"INVALID_STATUS_TRANSITION"}` (no status payload)
- **GRANT EXECUTE**: `authenticated` (`:744`)
- Uses `IF NOT FOUND` (`:324`) where the two sibling functions use `GET DIAGNOSTICS ROW_COUNT`; both are correct for an UPDATE but the inconsistency is worth normalising in the port. SLA = `now() + (eta + 3) minutes`, eta defaulting to 15 (`:332`).

### 2.20 `courier_arrived_at_customer`

- **Location**: `13_courier_status_transition_rpcs_v2.sql:340`
- **Args**: `p_order_id uuid` · **Returns**: `void`
- **Lang**: plpgsql · **VOLATILE (implicit)** · **SECURITY DEFINER** · `SET search_path = public`
- **WRITES**: `orders` (`:350`)
- **RAISE**: `:363` `invalid_status_transition`, `ERRCODE='P0001'`, `{"reason":"INVALID_STATUS_TRANSITION"}` (no status payload)
- **GRANT EXECUTE**: `authenticated` (`:745`)
- SLA `now() + 5 minutes` (`:353`); requires `status = 'delivering'` (`:360`).

### 2.21 `courier_deliver_order`

- **Location**: `13_courier_status_transition_rpcs_v2.sql:374`
- **Args**: `p_order_id uuid, p_delivery_code text DEFAULT NULL, p_delivery_proof_url text DEFAULT NULL`
- **Returns**: `void` · **Lang**: plpgsql · **VOLATILE (implicit)** · **SECURITY DEFINER** · `SET search_path = public`
- **READS**: `orders` `FOR UPDATE` (`:390-392`) · **WRITES**: `orders` (`:418`)
- **RAISE** (5, all `ERRCODE='P0001'`):

| Line | Message | DETAIL |
|---|---|---|
| `:394` | `order_not_found` | `{"reason":"ORDER_NOT_FOUND"}` |
| `:398` | `unauthorized` | `{"reason":"UNAUTHORIZED"}` |
| `:402` | `invalid_status_transition` | `{"reason":"INVALID_STATUS_TRANSITION","status":<order_status>}` |
| `:408` | `wrong_delivery_code` | `{"reason":"WRONG_DELIVERY_CODE"}` |
| `:413` | `missing_proof_image` | `{"reason":"MISSING_PROOF_IMAGE"}` |

- **GRANT EXECUTE**: `authenticated` (`:746`)
- Branching on `orders.delivery_mode`: `hand_to_me` requires a matching code (`:406-410`), anything else requires `length(p_delivery_proof_url) >= 4` (`:412`).
- **Defect**: same NULL-vs-NULL hole as 2.18 at `:407` — an order whose `delivery_verification_code` is NULL can be marked delivered with `p_delivery_code = NULL`. Also, the `ELSE` branch (`:411`) is reached for *any* `delivery_mode` that isn't exactly `hand_to_me`, so the mode CHECK constraint (`10_...:29-31`) is the only thing keeping that branch meaningful.

### 2.22 `cancel_order_by_consumer`

- **Location**: `13_courier_status_transition_rpcs_v2.sql:431`
- **Args**: `p_order_id uuid, p_reason text DEFAULT NULL` · **Returns**: `void`
- **Lang**: plpgsql · **VOLATILE (implicit)** · **SECURITY DEFINER** · `SET search_path = public`
- **READS**: `orders` `FOR UPDATE` (`:443-444`), `orders` again via helper
- **WRITES**: `courier_earnings` (via `insert_courier_earning_for_cancel`, `:464`), `orders` (`:469`)
- **RAISE** (4, all `ERRCODE='P0001'`):

| Line | Message | DETAIL |
|---|---|---|
| `:446` | `order_not_found` | `{"reason":"ORDER_NOT_FOUND"}` |
| `:450` | `unauthorized` | `{"reason":"UNAUTHORIZED"}` |
| `:454` | `cancel_after_pickup_not_allowed` | `{"reason":"CANCEL_AFTER_PICKUP_NOT_ALLOWED","status":<order_status>}` |
| `:458` | `order_already_terminal` | `{"reason":"ORDER_ALREADY_TERMINAL","status":<order_status>}` |

- **GRANT EXECUTE**: `authenticated` (`:747`)
- Cancellable statuses: `created, accepted, preparing, ready, assigned, courier_arrived_restaurant, scheduled` (`:457`). Always stamps `cancellation_reason_code = 'CONSUMER_CHANGED_MIND'` (`:473`) regardless of the free-text `p_reason` — the `CONSUMER_DUPLICATE` code in the migration-09 whitelist (`:23`) is therefore unreachable from this RPC.

### 2.23 `cancel_order_by_courier`

- **Location**: `13_courier_status_transition_rpcs_v2.sql:481`
- **Args**: `p_order_id uuid, p_reason_code text` · **Returns**: `void`
- **Lang**: plpgsql · **VOLATILE (implicit)** · **SECURITY DEFINER** · `SET search_path = public`
- **READS**: `courier_cancellation_log` (`:503-505`), `orders` `FOR UPDATE` (`:511-512`)
- **WRITES**: `courier_earnings` (via helper, `:527`), `courier_cancellation_log` INSERT (`:532`), `orders` (`:537` or `:551`), `courier_locations` (`:548`)
- **RAISE** (5, all `ERRCODE='P0001'`):

| Line | Message | DETAIL |
|---|---|---|
| `:498` | `invalid_reason_code` | `{"reason":"INVALID_REASON_CODE","code":<text>}` |
| `:507` | `courier_cancel_cooldown` | `{"reason":"COURIER_CANCEL_COOLDOWN","recent_cancels":<int>}` |
| `:514` | `order_not_found` | `{"reason":"ORDER_NOT_FOUND"}` |
| `:518` | `unauthorized` | `{"reason":"UNAUTHORIZED"}` |
| `:522` | `cannot_cancel_post_pickup` | `{"reason":"CANNOT_CANCEL_POST_PICKUP","status":<order_status>}` |

- **GRANT EXECUTE**: `authenticated` (`:748`)
- Accepted reason codes (`:494-497`): `COURIER_VEHICLE_ISSUE`, `COURIER_SAFETY_ISSUE`, `COURIER_RESTAURANT_CLOSED`, `COURIER_ITEMS_UNAVAILABLE`, `RESTAURANT_TOO_LONG_WAIT`.
- Cooldown: 3 self-cancels in 24 h blocks further cancels (`:505-509`).
- Restaurant-fault codes return the order to the pool at `status='ready'` with the courier appended to `excluded_courier_ids` (`:536-548`); vehicle/safety hard-cancel to `cancelled_by_courier` (`:551`).
- **Contract mismatch**: `09_...:26-28` declares the courier whitelist as `COURIER_VEHICLE_ISSUE, COURIER_SAFETY_ISSUE, COURIER_RESTAURANT_CLOSED, COURIER_ITEMS_UNAVAILABLE, COURIER_NON_RESPONSIVE`. The RPC drops `COURIER_NON_RESPONSIVE` (correct — that one is system-set) and adds `RESTAURANT_TOO_LONG_WAIT` (which migration 09 classifies as restaurant-initiated). The two whitelists must be reconciled explicitly in the proto.

### 2.24 `report_problem_post_pickup`

- **Location**: `13_courier_status_transition_rpcs_v2.sql:564`; **redefined** `17_system_messages_sender_role_fix.sql:155`
- **Args**: `p_order_id uuid, p_reason_code text, p_free_form text DEFAULT NULL` · **Returns**: `void`
- **Lang**: plpgsql · **VOLATILE (implicit)** · **SECURITY DEFINER** · `SET search_path = public`
- **READS**: `orders` (`17:169-170`) · **WRITES**: `orders` (`17:184`), `chat_messages` INSERT (`17:186`)
- **RAISE** (3, all `ERRCODE='P0001'`):

| Line (mig 17) | Message | DETAIL |
|---|---|---|
| `:172` | `order_not_found` | `{"reason":"ORDER_NOT_FOUND"}` |
| `:176` | `unauthorized` | `{"reason":"UNAUTHORIZED"}` |
| `:180` | `invalid_status_transition` | `{"reason":"INVALID_STATUS_TRANSITION","status":<order_status>}` |

- **GRANT EXECUTE**: `authenticated` (`13:749`, `17:286`)
- v17 delta: the `chat_messages` INSERT gains an explicit `sender_role = 'system'` (`17:186-188`).
- **Defect**: `p_reason_code` is validated against **no whitelist** and is string-concatenated straight into a consumer-visible Russian chat body (`17:188`: `'Курьер сообщил о проблеме: ' || p_reason_code || ...`). This is the only reason-code parameter in the surface with no validation — a courier can inject arbitrary text into the consumer's chat. Requires a whitelist in the port.
- Also sets `expected_action_by = NULL` (`17:184`), which permanently disables the escalation ladder for that order with no timer to re-arm it.

### 2.25 `courier_explain_delay`

- **Location**: `13_courier_status_transition_rpcs_v2.sql:606`; **redefined** `17_system_messages_sender_role_fix.sql:112`
- **Args**: `p_order_id uuid, p_reason_code text, p_free_form text DEFAULT NULL` · **Returns**: `void`
- **Lang**: plpgsql · **VOLATILE (implicit)** · **SECURITY DEFINER** · `SET search_path = public`
- **READS**: `orders` (`17:129`) · **WRITES**: `orders` (`17:135`), `chat_messages` INSERT (`17:141`)
- **RAISE** (2, both `ERRCODE='P0001'`):

| Line (mig 17) | Message | DETAIL |
|---|---|---|
| `:126` | `invalid_reason_code` | `{"reason":"INVALID_REASON_CODE","code":<text>}` |
| `:131` | `unauthorized` | `{"reason":"UNAUTHORIZED"}` |

- **GRANT EXECUTE**: `authenticated` (`13:750`, `17:285`)
- Accepted reason codes (`17:125`) are **lowercase**: `traffic`, `restaurant_slow`, `address_unclear`, `customer_unreachable`, `other`. Every other reason-code parameter in the surface is SCREAMING_SNAKE — a real casing inconsistency the proto must pick a side on.
- Extends SLA by 5 min (`17:138`) and stamps `courier_delay_explained_at`, which is the flag that exempts the order from all three escalation passes.

### 2.26 `reassign_ghosted_order`

- **Location**: `13_courier_status_transition_rpcs_v2.sql:651`
- **Args**: `p_order_id uuid` · **Returns**: `void`
- **Lang**: plpgsql · **VOLATILE (implicit)** · **SECURITY DEFINER** · `SET search_path = public`
- **READS**: `orders` `FOR UPDATE` (`:661`) · **WRITES**: `courier_earnings` (via helper, `:670`), `orders` (`:678` or `:687`), `courier_locations` (`:706`)
- **RAISE**: **none** — silent `RETURN` on not-found (`:662`) and on post-pickup statuses (`:663-666`)
- **GRANT EXECUTE**: `authenticated` (`:751`)
- 3 strikes ⇒ `cancelled_by_system` with `cancellation_reason_code='RESTAURANT_TOO_LONG_WAIT'` (`:677-685`).
- **Defect**: SECURITY DEFINER, granted to `authenticated`, **zero authorization checks anywhere in the body**. Any logged-in user can call it with any order UUID to strip the assigned courier, credit that courier a partial earning tagged `COURIER_NON_RESPONSIVE`, and push the order back to the pool — repeat three times and the order is force-cancelled. This is the single worst grant in the surface.

### 2.27 `fetch_available_orders`

- **Location**: `13_courier_status_transition_rpcs_v2.sql:715`
- **Args**: `p_latitude double precision, p_longitude double precision, p_radius_km double precision DEFAULT 50.0`
- **Returns**: `SETOF orders` · **Lang**: sql · **STABLE** · **SECURITY DEFINER** · `SET search_path = public, extensions`
- **READS**: `orders`, `restaurants` (`:725-727`) · **WRITES**: none · **RAISE**: none
- **GRANT EXECUTE**: `authenticated` (`:752`)
- Filters: unclaimed, `status IN ('accepted','preparing','ready')`, caller not in `excluded_courier_ids`, `ST_DWithin` on restaurant coords (`:728-735`), ordered by `created_at`.
- **Defect**: no courier-role check (contrast `claim_order:163`). Being `SECURITY DEFINER` + `SETOF orders` it bypasses RLS and returns **whole order rows** — including `verification_code`, `delivery_verification_code` and `delivery_address_snapshot` — to any authenticated user, consumer accounts included. `.context/resume-evidence-ravon.md:241` independently records this endpoint returning HTTP 200 to anonymous probes.

### 2.28 `run_courier_escalation_ladder`

- **Location**: `14_courier_escalation_ladder_cron.sql:18`; **redefined** `17_system_messages_sender_role_fix.sql:18`
- **Args**: none · **Returns**: `void`
- **Lang**: plpgsql · **VOLATILE (implicit)** · **SECURITY DEFINER** · `SET search_path = public`
- **READS**: `orders` `FOR UPDATE SKIP LOCKED` (three passes, `17:34,47,67`), `courier_locations` (`17:76`)
- **WRITES**: `orders` (`17:42,55,89`), `chat_messages` INSERT (`17:56`), `courier_locations` (`17:80,98,104`), `profiles` (`17:103`), `courier_earnings` (via helper, `17:86`), plus everything `reassign_ghosted_order` writes (`17:84`)
- **RAISE**: none
- **GRANT EXECUTE**: `authenticated` (`14:114`, `17:284`)
- Three passes: T+0 stamp `courier_no_show_warned_at`; T+2 stamp `courier_no_show_escalated_at` + system chat; T+5 reassign (pre-pickup) or cancel + −100 % clawback (post-pickup), then ghost-strike, suspending 24 h at 3 strikes in a rolling 14 days.
- v17 delta: the pass-2 `chat_messages` INSERT gains `sender_role='system'` (`17:56-62`).
- **Defect**: granted to `authenticated`, so any logged-in user can run the platform-wide escalation sweep on demand. Combined with the pass-3 clawback this lets a caller fast-forward every in-flight order's timers.
- Note: pass 2's system message uses `COALESCE(rec.courier_id, '00000000-...')` as `sender_id` (`17:59`) — a synthetic all-zeros UUID that has no `profiles` row.

### 2.29 `set_chat_sender_role`

- **Location**: `15_chat_rls_and_sender_role.sql:23`
- **Args**: none · **Returns**: `trigger` · **Lang**: plpgsql
- **VOLATILE (implicit)** · **SECURITY INVOKER (implicit)** · **no `SET search_path`**
- **READS**: `profiles` (`:27`) · **WRITES**: mutates `NEW.sender_role` (`:27-28`)
- **RAISE**: none · **GRANT EXECUTE**: none
- **Trigger**: `chat_messages_set_sender_role BEFORE INSERT ON chat_messages FOR EACH ROW` (`:35-37`)
- Only fills when `NEW.sender_role IS NULL` (`:26`) — that is precisely the property migration 17 relies on. Falls back to `'system'` when the sender has no profile (`:28`).
- Note: SECURITY INVOKER + a `profiles` SELECT means the lookup is subject to the caller's RLS on `profiles`; if `profiles` RLS hides other users, a courier-sent message could silently be tagged `'system'`. **UNKNOWN — needs live introspection** (no `profiles` RLS policy appears in any of the 19 migrations).

### 2.30 `courier_report_customer_no_show`

- **Location**: `16_no_show_and_restaurant_delay.sql:14`; **redefined** `17_system_messages_sender_role_fix.sql:193`
- **Args**: `p_order_id uuid` · **Returns**: `void`
- **Lang**: plpgsql · **VOLATILE (implicit)** · **SECURITY DEFINER** · `SET search_path = public`
- **READS**: `orders` (`17:204`) · **WRITES**: `orders` (`17:214`), `chat_messages` INSERT (`17:220`)
- **RAISE** (2, both `ERRCODE='P0001'`):

| Line (mig 17) | Message | DETAIL |
|---|---|---|
| `:206` | `unauthorized` | `{"reason":"UNAUTHORIZED"}` |
| `:210` | `invalid_status_transition` | `{"reason":"INVALID_STATUS_TRANSITION","status":<order_status>}` |

- **GRANT EXECUTE**: `authenticated` (`16:137`, `17:287`)
- **Defect**: no `NOT FOUND` check. A nonexistent order leaves `v_courier` NULL, so `v_courier IS DISTINCT FROM v_uid` is true and the caller gets `UNAUTHORIZED` where every sibling returns `ORDER_NOT_FOUND`. Same omission in `courier_report_restaurant_delay`. Two RPCs therefore cannot emit `ORDER_NOT_FOUND` at all.
- Starts a 5-minute timer (`17:216`) and reuses the lowercase delay code `'customer_unreachable'` (`17:217`).

### 2.31 `mark_no_show_deliveries`

- **Location**: `16_no_show_and_restaurant_delay.sql:49`
- **Args**: none · **Returns**: `void`
- **Lang**: plpgsql · **VOLATILE (implicit)** · **SECURITY DEFINER** · `SET search_path = public`
- **READS**: `orders` `FOR UPDATE SKIP LOCKED` (`:58-63`) · **WRITES**: `orders` (`:65`)
- **RAISE**: none
- **GRANT EXECUTE**: `authenticated` (`:138`)
- Marks `status='delivered', no_show=true, cancellation_reason_code='CUSTOMER_NO_SHOW'` after the 5-minute timer, relying on the (dashboard-created) `delivered` trigger to write a full earning (`:72`).
- **Defect**: granted to `authenticated` — any logged-in user can fire the platform-wide no-show sweep.

### 2.32 `courier_report_restaurant_delay`

- **Location**: `16_no_show_and_restaurant_delay.sql:78`; **redefined** `17_system_messages_sender_role_fix.sql:227`
- **Args**: `p_order_id uuid, p_extra_minutes int` · **Returns**: `void`
- **Lang**: plpgsql · **VOLATILE (implicit)** · **SECURITY DEFINER** · `SET search_path = public`
- **READS**: `orders` `FOR UPDATE` (`17:246-247`) · **WRITES**: `courier_earnings` (via helper, `17:260`), `orders` (`17:263` or `17:271`), `chat_messages` INSERT (`17:277`)
- **RAISE** (3, all `ERRCODE='P0001'`):

| Line (mig 17) | Message | DETAIL |
|---|---|---|
| `:242` | `invalid_extra_minutes` | `{"reason":"INVALID_EXTRA_MINUTES"}` |
| `:249` | `unauthorized` | `{"reason":"UNAUTHORIZED"}` |
| `:253` | `invalid_status_transition` | `{"reason":"INVALID_STATUS_TRANSITION","status":<order_status>}` |

- **GRANT EXECUTE**: `authenticated` (`16:139`, `17:288`)
- Per-call bound `1..15` minutes (`17:241`); cumulative `restaurant_delay_min > 30` auto-cancels with `RESTAURANT_TOO_LONG_WAIT` and a 50 % courier earning (`17:259-269`).
- Same missing `NOT FOUND` check as 2.30.

### 2.33 `public.handle_new_user`

- **Location**: `18_handle_new_user_trigger.sql:15`
- **Args**: none · **Returns**: `trigger` · **Lang**: plpgsql
- **VOLATILE (implicit)** · **SECURITY DEFINER** · `SET search_path = public`
- **READS**: the `NEW` `auth.users` row (`raw_user_meta_data`) · **WRITES**: `public.profiles` INSERT `ON CONFLICT (id) DO NOTHING` (`:22-30`)
- **RAISE**: none · **GRANT EXECUTE**: none
- **Trigger**: `on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW` (`:36-38`)
- Defaults: `full_name → ''`, `role → 'consumer'::user_role` (`:25-26`).
- Note: `(NEW.raw_user_meta_data->>'role')::user_role` (`:26`) casts client-supplied signup metadata straight into the role column. Migration 19 blocks *later* self-escalation but not *initial* self-assignment — a client can sign up with `role: "merchant"` and `handle_new_user` will honour it. This is the correct place to re-gate in the port.

### 2.34 `public.profiles_block_role_change`

- **Location**: `19_lock_down_profile_role.sql:18`
- **Args**: none · **Returns**: `trigger` · **Lang**: plpgsql
- **VOLATILE (implicit)** · **SECURITY DEFINER** · `SET search_path = public`
- **READS / WRITES**: none — compares `OLD.role` / `NEW.role`
- **RAISE**: `:26` `role changes are not permitted`, **`ERRCODE = '42501'`**, `DETAIL = {"reason":"ROLE_CHANGE_FORBIDDEN"}`
- **GRANT EXECUTE**: none
- **Trigger**: `profiles_block_role_change BEFORE UPDATE ON public.profiles FOR EACH ROW WHEN (auth.uid() IS NOT NULL AND auth.uid() = OLD.id)` (`:35-39`)
- The only DETAIL-bearing exception in the surface that is **not** `P0001`. `.context/plans/migration-20-...:128-131` independently questions whether the `auth.uid()`-based `WHEN` gate actually exempts SECURITY DEFINER callers — that concern applies verbatim here and is **UNKNOWN — needs live introspection**.

---

## 3. Volatility / security / search_path summary

| Property | Count | Functions |
|---|---|---|
| `SECURITY DEFINER` | **29** | everything except the 5 below |
| `SECURITY INVOKER` (implicit) | **5** | `generate_verification_code`, `sync_order_delivery_mode_from_address`, `earnings_tier_for_cancel`, `earning_type_for_status`, `set_chat_sender_role` |
| Missing `SET search_path` | **5** | the same 5 |
| `IMMUTABLE` | **2** | `earnings_tier_for_cancel`, `earning_type_for_status` |
| `STABLE` | **6** | `restaurant_within_hours`, `restaurant_is_orderable`, `get_restaurant_orderability`, `validate_cart`, `compute_eta_minutes`, `fetch_available_orders` |
| `VOLATILE` (all implicit — no function declares it) | **26** | the rest |
| `LANGUAGE sql` | **4** | `restaurant_is_orderable`, `earnings_tier_for_cancel`, `earning_type_for_status`, `fetch_available_orders` |
| `LANGUAGE plpgsql` | **30** | the rest |
| `search_path = public, extensions` | **3** | `compute_eta_minutes`, `update_courier_heartbeat`, `fetch_available_orders` (the PostGIS callers) |

`.context/migrations/README.md:138-141` claims the 5 `search_path`-less helpers were tightened
post-hoc with `ALTER FUNCTION ... SET search_path = public` to clear the
`function_search_path_mutable` lint. That `ALTER` exists in **no migration file**, so whether
it was ever applied is **UNKNOWN — needs live introspection**. The Kotlin/SQL rebuild should
just write it into the definitions.

### GRANT EXECUTE roll-up

| Grant | Count | Functions |
|---|---|---|
| `authenticated, anon` | 3 | `restaurant_within_hours`, `restaurant_is_orderable`, `get_restaurant_orderability` |
| `authenticated` | 24 | all Swift-called RPCs plus `compute_eta_minutes`, `earnings_tier_for_cancel`, `earning_type_for_status`, `activate_scheduled_order`, `reassign_ghosted_order`, `run_courier_escalation_ladder`, `mark_no_show_deliveries` |
| **no GRANT** | 7 | `activate_scheduled_orders`, `insert_courier_earning_for_cancel`, `generate_verification_code`, `sync_order_delivery_mode_from_address`, `set_chat_sender_role`, `handle_new_user`, `profiles_block_role_change` |

`compute_eta_minutes` and `update_courier_heartbeat` each receive a **duplicate** grant
(`13:63`/`13:739` and `13:143`/`13:740`) — harmless, but it means migration 13's trailing
grant block is not the single authority it looks like.

### Grants that are privilege holes

Four SECURITY DEFINER functions with **no caller authorization of any kind** are granted to
`authenticated`. These are the ones to *not* carry forward:

1. `reassign_ghosted_order(uuid)` — `13:751`. Zero checks. Strip any order's courier, credit a partial earning, force-cancel after 3 calls.
2. `activate_scheduled_order(uuid)` — `06:107`. Zero checks. Activate or system-cancel anyone's scheduled order.
3. `run_courier_escalation_ladder()` — `14:114`, `17:284`. Platform-wide sweep including −100 % clawbacks.
4. `mark_no_show_deliveries()` — `16:138`. Platform-wide sweep that marks orders delivered.

Plus `fetch_available_orders` (2.27) which leaks whole `orders` rows to non-couriers, and the
three `anon`-callable orderability functions which permit anonymous enumeration of any
restaurant's state.

---

## 4. Table read/write matrix

| Table | Read by | Written by |
|---|---|---|
| `restaurants` | `restaurant_is_orderable`, `get_restaurant_orderability`, `validate_cart`, `create_order`, `set_accepting_orders`, `activate_scheduled_order`, `activate_scheduled_orders`, `compute_eta_minutes`, `fetch_available_orders` | `set_accepting_orders` |
| `restaurant_hours` | `restaurant_within_hours` | — |
| `menu_items` | `validate_cart`, `create_order`, `activate_scheduled_order` | `create_order`, `activate_scheduled_order` |
| `menu_categories` | — | — (only the `07` cron body) |
| `orders` | `validate_cart`, `create_order`, `activate_scheduled_order(+s)`, `insert_courier_earning_for_cancel`, `compute_eta_minutes`, `claim_order`, `courier_pickup_order`, `courier_deliver_order`, `cancel_order_by_consumer`, `cancel_order_by_courier`, `report_problem_post_pickup`, `courier_explain_delay`, `reassign_ghosted_order`, `fetch_available_orders`, `run_courier_escalation_ladder`, `courier_report_customer_no_show`, `mark_no_show_deliveries`, `courier_report_restaurant_delay` | `create_order`, `activate_scheduled_order`, `update_courier_heartbeat`, `claim_order`, `courier_arrived_restaurant`, `courier_pickup_order`, `courier_start_delivering`, `courier_arrived_at_customer`, `courier_deliver_order`, `cancel_order_by_consumer`, `cancel_order_by_courier`, `report_problem_post_pickup`, `courier_explain_delay`, `reassign_ghosted_order`, `run_courier_escalation_ladder`, `courier_report_customer_no_show`, `mark_no_show_deliveries`, `courier_report_restaurant_delay` |
| `order_items` | `activate_scheduled_order` | `create_order` |
| `addresses` | `create_order`, `compute_eta_minutes`, `sync_order_delivery_mode_from_address` | — |
| `profiles` | `claim_order`, `update_courier_heartbeat`, `set_chat_sender_role` | `run_courier_escalation_ladder` (suspension), `handle_new_user` (INSERT) |
| `courier_locations` | `compute_eta_minutes`, `update_courier_heartbeat`, `claim_order`, `run_courier_escalation_ladder` | `update_courier_heartbeat`, `claim_order`, `cancel_order_by_courier`, `reassign_ghosted_order`, `run_courier_escalation_ladder` |
| `courier_earnings` | — | `insert_courier_earning_for_cancel` (sole writer; reached from `cancel_order_by_consumer`, `cancel_order_by_courier`, `reassign_ghosted_order`, `run_courier_escalation_ladder`, `courier_report_restaurant_delay`) |
| `courier_cancellation_log` | `cancel_order_by_courier` | `cancel_order_by_courier` |
| `chat_messages` | — | `report_problem_post_pickup`, `courier_explain_delay`, `run_courier_escalation_ladder`, `courier_report_customer_no_show`, `courier_report_restaurant_delay` |
| `auth.users` | `handle_new_user` (as `NEW`) | — |

Four of the 15 Swift-touched tables are never read or written by any migration function:
`menu_categories`, `menu_item_modifier_groups`, `modifier_groups`, `modifier_options`
(the modifier system is PostgREST-only, which is why `create_order:263` hardcodes
`modifiers_snapshot = '[]'`).

---

## 5. Cross-check against the 21 Swift RPCs

### 5a. Functions in migrations that no Swift `rpc(...)` calls — 16 of 34

None of these is *dead* in the graph sense; all 16 have a caller. Broken down:

**Trigger functions (5)** — invoked by Postgres, never by name:
`generate_verification_code` (trigger binding unknown, §1.2), `sync_order_delivery_mode_from_address`,
`set_chat_sender_role`, `handle_new_user`, `profiles_block_role_change`.

**Cron entry points (3)** — `activate_scheduled_orders`, `run_courier_escalation_ladder`, `mark_no_show_deliveries`.

**SQL-internal helpers (8)** — called only from other SQL:

| Helper | Called from |
|---|---|
| `restaurant_within_hours` | `restaurant_is_orderable:67`, `get_restaurant_orderability:134`, `validate_cart:50`, `create_order:172`, `activate_scheduled_order:40` |
| `restaurant_is_orderable` | view `restaurants_orderable:75` only |
| `compute_eta_minutes` | `update_courier_heartbeat:137`, `claim_order:217`, `courier_start_delivering:329` |
| `earnings_tier_for_cancel` | `insert_courier_earning_for_cancel:82` |
| `earning_type_for_status` | `insert_courier_earning_for_cancel:83` |
| `insert_courier_earning_for_cancel` | `cancel_order_by_consumer:464`, `cancel_order_by_courier:527`, `reassign_ghosted_order:670`, `run_courier_escalation_ladder:86`, `courier_report_restaurant_delay:260` |
| `reassign_ghosted_order` | `run_courier_escalation_ladder:84` |
| `activate_scheduled_order` | `activate_scheduled_orders:102` |

18 Swift-called + 16 not-Swift-called = 34. ✔

**The genuinely dead item is not a function**: `restaurant_is_orderable` exists only to feed
the `restaurants_orderable` view, and no Swift code ever queries that view — the sole
references are two comment lines (`Sources/RavonCore/Services/SupabaseService.swift:171-172`)
and an unrelated `is_orderable_now` CodingKey at `:203`. Verified: zero `.from("restaurants_orderable")`
call sites anywhere in `Sources/`.

### 5b. RPCs Swift calls that exist in NO migration — the "exactly 3" claim is CORRECT

| RPC | Swift call site | Params Swift sends | Swift expects back |
|---|---|---|---|
| `find_nearby_couriers` | `Sources/RavonCore/Services/SupabaseService.swift:711` | `p_latitude`, `p_longitude`, `p_radius_km` (all Double) | `[NearbyCourier]` |
| `add_tip` | `Sources/RavonCore/Services/SupabaseService.swift:663` | `p_order_id` (UUID), `p_amount` (Double) | void |
| `get_merchant_stats` | `Sources/RavonCore/Services/SupabaseService.swift:1453` | `p_restaurant_id` (UUID) | `MerchantStats` |

Verified exhaustively: the 21 Swift RPC names minus the 34 migration function names leaves
exactly these 3. Also verified there is **no other SQL anywhere** — `find . -name '*.sql'`
across `ravon-core`, `ravon-consumer`, `ravon-courier` and `ravon-merchant` returns only
`.context/migrations/*` plus vendored `supabase-swift` fixtures under `.build/checkouts/`.
The three app repos contain zero `.sql` files.

**Correction to the inventory's footnote.** `12-BACKEND-INVENTORY.md:64` says these
"must be reconstructed from the Swift call site." That understates what is available —
all three have prior written specs in this repo:

- **`get_merchant_stats`** — a complete, ready-to-apply SQL body at
  `.context/plans/merchant-app-overhaul-doordash-style-onboarding-ma.md:228-243`:
  `RETURNS json`, `SECURITY DEFINER`, `json_build_object` with keys
  `today_order_count`, `today_revenue`, `average_order_value`, `active_order_count`,
  aggregating `orders WHERE restaurant_id = p_restaurant_id`. **It has no owner check** —
  which is exactly the finding recorded at `.context/resume-evidence-ravon.md:235`.
- **`find_nearby_couriers`** — behavioural spec at
  `.context/plans/bunch-2-courier-management.md:18-19`: online available couriers within
  radius via `ST_DWithin`, ordered by distance. Also flagged as unauthenticated at
  `.context/resume-evidence-ravon.md:234`.
- **`add_tip`** — a full design (bounds, window, idempotency, earnings reconciliation) at
  `.context/plans/migration-20-lock-orders-to-rpc-only-writes-dev-aw.md:91-99`, including two
  new reason codes not present in any migration: `INVALID_TIP_AMOUNT` and `TIP_WINDOW_CLOSED`.

So the reconstruction source for these three is *plans + Swift signature*, not Swift signature alone.

### 5c. `update_courier_heartbeat` — CONFIRMED: in the migrations, absent from the boundary map

**It is in the migrations.** `13_courier_status_transition_rpcs_v2.sql:72`, full definition at
2.15 above, granted to `authenticated` at `13:143` and again at `13:740`, and called from
Swift at `Sources/RavonCore/Services/SupabaseService.swift:580`.

**It is assigned to no destination.** Arithmetic on `12-BACKEND-INVENTORY.md:38-64`:

| Group | Label | Names actually listed | Of which absent from migrations |
|---|---|---|---|
| `services/order` (`:40-44`) | 13 | 13 | 0 |
| `services/dispatch` (`:46-47`) | 4 | 4 | 1 (`find_nearby_couriers`) |
| `services/ledger` (`:49-50`) | 4 | 4 | 1 (`add_tip`) |
| scheduled workers (`:52-53`) | 4 | 4 | 0 |
| `services/merchant` (`:55-56`) | 3 | 3 | 1 (`get_merchant_stats`) |
| stays in SQL (`:58-62`) | **6** | **8** | 0 |
| **Total** | 34 | **36** | 3 |

36 listed − 3 non-existent = 33 migration functions assigned. 34 − 33 = **1 unassigned:
`update_courier_heartbeat`**. Confirmed by set difference against the full catalogue above.

**Two errors in that one block, not one:**

1. `update_courier_heartbeat` is unassigned. This matters more than a bookkeeping slip —
   it is the highest-write-frequency function in the entire surface (one call per courier per
   second at the rate limiter's ceiling, `13:112`), it is the only writer of the smart-ghost
   fraud signals `last_moved_at` / `accuracy_meters`, and it transitively writes `orders.eta_minutes`
   for every active delivery (`13:137`). Every plausible home is contentious: it is
   location ingest (its own service), it drives dispatch ETA, and it enforces suspension.
   Leaving it unplaced means the hottest write path in the system has no owner.
2. The "Stays in SQL — correctly (6)" group is labelled 6 but enumerates 8 function names
   (`handle_new_user`, `profiles_block_role_change`, `set_chat_sender_role`,
   `sync_order_delivery_mode_from_address`, `generate_verification_code`,
   `restaurant_within_hours`, `restaurant_is_orderable`, `get_restaurant_orderability`).
   The parenthetical "(pure, set-returning, cheap in SQL)" at `:62` is also wrong on two counts:
   none of those three is set-returning, and `restaurant_within_hours` is `STABLE`, not pure.
   (The only set-returning function in the surface is `fetch_available_orders`, `RETURNS SETOF orders`.)

---

## 6. The complete `reason` string set — the proto error enum

**29 distinct strings, 62 total emissions** across 63 `RAISE EXCEPTION` statements. The one
`RAISE` with no `DETAIL` is `set_accepting_orders:26`.

SQLSTATE distribution: **61 × `P0001`** (all with DETAIL), **2 × `42501`**
(`set_accepting_orders:26` without DETAIL; `profiles_block_role_change:27` with DETAIL).

| # | `reason` | Emissions | Extra DETAIL keys | Emitted by | SQLSTATE | Mapped by Swift `ServiceError.from`? |
|---|---|---|---|---|---|---|
| 1 | `UNAUTHORIZED` | 13 | — | `claim_order`, `courier_pickup_order`, `courier_deliver_order`, `cancel_order_by_consumer`, `cancel_order_by_courier`, `report_problem_post_pickup`, `courier_explain_delay`, `courier_report_customer_no_show`, `courier_report_restaurant_delay` | P0001 | yes |
| 2 | `INVALID_STATUS_TRANSITION` | 10 | `status` (7 of 10) | `courier_arrived_restaurant`, `courier_start_delivering`, `courier_arrived_at_customer`, `courier_deliver_order`, `report_problem_post_pickup`, `courier_report_customer_no_show`, `courier_report_restaurant_delay` | P0001 | yes |
| 3 | `ORDER_NOT_FOUND` | 7 | — | `claim_order`, `courier_pickup_order`, `courier_deliver_order`, `cancel_order_by_consumer`, `cancel_order_by_courier`, `report_problem_post_pickup` | P0001 | yes |
| 4 | `INVALID_REASON_CODE` | 3 | `code` | `cancel_order_by_courier`, `courier_explain_delay` | P0001 | yes |
| 5 | `RESTAURANT_CLOSED` | 2 | — | `create_order` (`:156`, `:164`) | P0001 | **no** |
| 6 | `ORDER_NO_LONGER_PICKUPABLE` | 2 | `status` | `claim_order`, `courier_pickup_order` | P0001 | yes |
| 7 | `INVALID_EXTRA_MINUTES` | 2 | — | `courier_report_restaurant_delay` | P0001 | **no** |
| 8 | `COURIER_SUSPENDED` | 2 | `until` | `update_courier_heartbeat`, `claim_order` | P0001 | yes (drops `until`) |
| 9 | `WRONG_DELIVERY_CODE` | 1 | — | `courier_deliver_order` | P0001 | yes |
| 10 | `SCHEDULED_TIME_INVALID` | 1 | — | `create_order` | P0001 | **no** |
| 11 | `ROLE_CHANGE_FORBIDDEN` | 1 | — | `profiles_block_role_change` | **42501** | **no** |
| 12 | `RESTAURANT_PAUSED` | 1 | — | `create_order` | P0001 | **no** |
| 13 | `RESTAURANT_NOT_ACCEPTING` | 1 | `until` | `create_order` | P0001 | **no** |
| 14 | `OVERLOADED` | 1 | — | `create_order` | P0001 | **no** |
| 15 | `OUT_OF_HOURS` | 1 | — | `create_order` | P0001 | **no** |
| 16 | `ORDER_ALREADY_TERMINAL` | 1 | `status` | `cancel_order_by_consumer` | P0001 | yes (folded into `.invalidStatusTransition`) |
| 17 | `NOT_AUTHENTICATED` | 1 | — | `update_courier_heartbeat` | P0001 | yes |
| 18 | `MISSING_PROOF_IMAGE` | 1 | — | `courier_deliver_order` | P0001 | yes |
| 19 | `MIN_ORDER_NOT_MET` | 1 | `need` | `create_order` | P0001 | **no** |
| 20 | `ITEM_UNAVAILABLE` | 1 | `menu_item_id` | `create_order` | P0001 | **no** |
| 21 | `INVALID_VERIFICATION_CODE` | 1 | — | `courier_pickup_order` | P0001 | yes |
| 22 | `INSUFFICIENT_STOCK` | 1 | `menu_item_id`, `have` | `create_order` | P0001 | **no** |
| 23 | `COURIER_MUST_BE_ONLINE` | 1 | — | `claim_order` | P0001 | yes |
| 24 | `COURIER_EXCLUDED_FROM_ORDER` | 1 | — | `claim_order` | P0001 | yes |
| 25 | `COURIER_CANCEL_COOLDOWN` | 1 | `recent_cancels` | `cancel_order_by_courier` | P0001 | yes (hardcodes 3) |
| 26 | `COURIER_ALREADY_HAS_ACTIVE_ORDER` | 1 | `order_id` | `claim_order` | P0001 | yes |
| 27 | `CANNOT_CANCEL_POST_PICKUP` | 1 | `status` | `cancel_order_by_courier` | P0001 | yes |
| 28 | `CANCEL_AFTER_PICKUP_NOT_ALLOWED` | 1 | `status` | `cancel_order_by_consumer` | P0001 | yes |
| 29 | `ACCURACY_TOO_LOW` | 1 | `accuracy` | `update_courier_heartbeat` | P0001 | yes (drops `accuracy`) |

**Copy-paste set (29):**

```
ACCURACY_TOO_LOW
CANCEL_AFTER_PICKUP_NOT_ALLOWED
CANNOT_CANCEL_POST_PICKUP
COURIER_ALREADY_HAS_ACTIVE_ORDER
COURIER_CANCEL_COOLDOWN
COURIER_EXCLUDED_FROM_ORDER
COURIER_MUST_BE_ONLINE
COURIER_SUSPENDED
INSUFFICIENT_STOCK
INVALID_EXTRA_MINUTES
INVALID_REASON_CODE
INVALID_STATUS_TRANSITION
INVALID_VERIFICATION_CODE
ITEM_UNAVAILABLE
MIN_ORDER_NOT_MET
MISSING_PROOF_IMAGE
NOT_AUTHENTICATED
ORDER_ALREADY_TERMINAL
ORDER_NOT_FOUND
ORDER_NO_LONGER_PICKUPABLE
OUT_OF_HOURS
OVERLOADED
RESTAURANT_CLOSED
RESTAURANT_NOT_ACCEPTING
RESTAURANT_PAUSED
ROLE_CHANGE_FORBIDDEN
SCHEDULED_TIME_INVALID
UNAUTHORIZED
WRONG_DELIVERY_CODE
```

**Full set of DETAIL payload keys** (these are the proto message fields, not just the enum):
`reason`, `status`, `until`, `code`, `menu_item_id`, `have`, `need`, `order_id`,
`recent_cancels`, `accuracy`.

### 6.1 The decoder covers 18 of 29 — and the 11 gaps are not arbitrary

`ServiceError.from(serverError:)` at `Sources/RavonCore/Services/SupabaseService.swift:90-127`
switches on 18 kinds and `default: return nil` (`:126`). The 11 unhandled:

`RESTAURANT_CLOSED`, `RESTAURANT_PAUSED`, `RESTAURANT_NOT_ACCEPTING`, `OUT_OF_HOURS`,
`OVERLOADED`, `MIN_ORDER_NOT_MET`, `ITEM_UNAVAILABLE`, `INSUFFICIENT_STOCK`,
`SCHEDULED_TIME_INVALID`, `INVALID_EXTRA_MINUTES`, `ROLE_CHANGE_FORBIDDEN`.

Nine of those eleven are **every single `create_order` failure mode**. And `ServiceError`
already declares dedicated cases for most of them — `.restaurantClosed` (`:49`),
`.restaurantNotAccepting` (`:50`), `.restaurantOverloaded` (`:51`), `.restaurantOutOfHours`
(`:52`), `.insufficientStock` (`:53`), `.minOrderNotMet` (`:60`), `.scheduledTimeInvalid`
(`:61`) — with Russian display strings written and never reachable. `RESTAURANT_PAUSED` has
no `ServiceError` case at all. So the checkout path's structured errors are emitted by SQL,
have Swift cases waiting, and are dropped in the middle. Combined with the established fact
that `from(serverError:)` has zero production call sites, **no create_order error is typed
today, end to end.** For the Kotlin port this is the single highest-value contract to nail
down, because it is the one the consumer sees at the moment of payment intent.

### 6.2 Secondary enums the proto also needs

These travel in **return payloads**, not exceptions, and are a separate wire contract:

- `validate_cart` / `get_restaurant_orderability` `reason.kind` — **7 values**: `OK`,
  `RESTAURANT_CLOSED`, `RESTAURANT_PAUSED`, `RESTAURANT_NOT_ACCEPTING` (+`until`),
  `OUT_OF_HOURS` (+`opens_at`), `OVERLOADED`, `MIN_ORDER_NOT_MET` (+`need`).
  Mirrored exactly in `Sources/RavonCore/Models/CartValidation.swift:21-27`.
- `validate_cart` per-item `status` — **4 values emitted by SQL**: `OK`, `UNAVAILABLE`,
  `INSUFFICIENT_STOCK` (+`have`), `DELETED` (`04_...:82-93`).
  **But `Sources/RavonCore/Models/CartValidation.swift:106-111` declares 5**, adding
  `PRICE_CHANGED` (+`old_price`, +`new_price`). No SQL anywhere emits `PRICE_CHANGED` —
  the Swift decoder supports a server behaviour that was never implemented. Either the
  port implements price-drift detection in `validate_cart` or the case gets deleted.
- Courier delay codes (lowercase) — `traffic`, `restaurant_slow`, `address_unclear`,
  `customer_unreachable`, `other` (`17:125`).
- `cancellation_reason_code` CHECK whitelist — **17 values** at
  `09_cancellation_reason_code_and_courier_cancel_log.sql:21-35`. Note the `cancel_order_by_courier`
  runtime whitelist disagrees with it (see 2.23).
- `courier_earnings.earning_type` CHECK whitelist — **7 values** at
  `12_tiered_earnings_columns_and_helpers.sql:28-31`.
- `chat_messages.sender_role` CHECK — `consumer`, `courier`, `merchant`, `system` (`15:16`).
- `addresses.default_delivery_mode` / `orders.delivery_mode` CHECK — `hand_to_me`,
  `leave_at_door` (`10:21`, `10:30`).

Both `OrderabilityReason.init(from:)` (`CartValidation.swift:29-41`) and
`CartItemStatus.init(from:)` (`:113-127`) decode into a **closed** Swift `Kind` enum, so an
unrecognised server value throws rather than degrading. Any proto enum for these needs an
explicit `UNKNOWN = 0` and a client that tolerates it, or adding a reason becomes a
breaking change across three pinned app binaries.

---

## 7. Defects found while reading (ranked)

1. **`create_order` has no address-ownership check** — `04:202` + `04:244`. Cross-tenant IDOR
   that also leaks the full address row back via `delivery_address_snapshot`. See 2.5.
2. **Four unauthenticated SECURITY DEFINER functions granted to `authenticated`** —
   `reassign_ghosted_order`, `activate_scheduled_order`, `run_courier_escalation_ladder`,
   `mark_no_show_deliveries`. See §3.
3. **`fetch_available_orders` leaks whole `orders` rows** including both verification codes
   and the address snapshot, to any authenticated user, with no courier-role check. See 2.27.
4. **`NULL IS DISTINCT FROM NULL` verification bypass** in `courier_pickup_order:284` and
   `courier_deliver_order:407` — an order with a NULL code can be picked up / delivered with
   no code supplied.
5. **`report_problem_post_pickup` concatenates an unvalidated `p_reason_code` into a
   consumer-visible chat message** (`17:188`) — the only unwhitelisted reason-code parameter
   in the surface.
6. **`handle_new_user` trusts client-supplied `role` metadata** (`18:26`), so migration 19's
   escalation block can be sidestepped at signup time.
7. **`set_accepting_orders` emits no `DETAIL`** (`05:26`) — the lone RPC whose authorization
   failure cannot be typed by the client.
8. **`courier_report_customer_no_show` and `courier_report_restaurant_delay` cannot emit
   `ORDER_NOT_FOUND`** — a missing order surfaces as `UNAUTHORIZED`. See 2.30.
9. **`claim_order` returns the caller's own uid** (`13:219`) while the Swift signature
   promises a meaningful `UUID`. Its "already busy" check is also un-locked (`13:180`).
10. **`validate_cart` reports `DELETED`/`UNAVAILABLE` items without setting `orderable: false`**
    (`04:82-84`), so the pre-checkout gate can green-light a cart that `create_order` will
    reject. See 2.4.
11. **Three `anon`-callable orderability functions** (`03:152-154`) plus an `anon`-readable
    view (`03:79`) permit anonymous enumeration of every restaurant's live state.
12. **`create_order` hardcodes `modifiers_snapshot = '[]'`** (`04:263`) despite migration 02
    adding the column and backfilling it — orders created through the RPC lose all modifiers.
13. **`activate_scheduled_order` writes typed codes into the free-text column** — uses
    `cancellation_reason` (`06:42,56,64,71`) where migration 09 whitelisted those exact
    four values for `cancellation_reason_code`.
14. **Lowercase/uppercase reason-code split** — `courier_explain_delay` uses lowercase codes
    (`17:125`), everything else SCREAMING_SNAKE.
15. **Error-shape inconsistency across sibling transitions** — `courier_arrived_restaurant:250`,
    `courier_start_delivering:326` and `courier_arrived_at_customer:364` emit
    `INVALID_STATUS_TRANSITION` with no `status` payload and collapse not-found /
    wrong-courier / wrong-status into one error, while `courier_deliver_order:402` and the
    migration-16/17 functions include `status` and distinguish the cases.
16. **Duplicate grants** for `compute_eta_minutes` and `update_courier_heartbeat`
    (`13:63`/`13:739`, `13:143`/`13:740`).
17. **`get_restaurant_orderability` declares an unused variable** (`03:96`) and hardcodes
    `opens_at: null` in every branch, pushing the computation client-side.

---

## 8. UNKNOWN — needs live introspection

The Supabase project is gone (NXDOMAIN), so these cannot be settled from this repo:

1. The trigger name / timing / table for `generate_verification_code` (§1.2).
2. Whether the post-hoc `ALTER FUNCTION ... SET search_path = public` claimed at
   `README.md:138-141` was ever applied to the 5 INVOKER helpers.
3. The bodies of `get_merchant_stats`, `find_nearby_couriers`, `add_tip` **as deployed** —
   only plan-doc designs and Swift signatures survive (§5b).
4. `CREATE TYPE` for all 6 enums (`order_status`, `user_role`, `courier_status`,
   `delivery_mode`, `sender_role`, `restaurant_status`) — migrations only `ALTER TYPE ... ADD VALUE`
   (`06:15`, `09:11`), never create. The full label lists and their ordinal order are lost;
   the Swift enums are the only surviving record.
5. `CREATE TABLE` for 14 of the 15 Swift-touched tables — only `courier_cancellation_log`
   (`09:39`) is created in a migration. All column types, defaults, PKs, FKs, uniques and
   generated columns for the other 14 must come from the Swift models + `scripts/schema_drift.py`.
   Notably `courier_earnings` must have a **unique constraint on `order_id`**, because
   `insert_courier_earning_for_cancel:94` depends on `ON CONFLICT (order_id)`, and
   `courier_locations.geog` must be a generated geography column, because
   `update_courier_heartbeat:115` never writes it yet `compute_eta_minutes:54` reads it.
6. RLS policies on `profiles`, `orders`, `restaurants`, `addresses`, `courier_locations`,
   `courier_earnings` — none appear in migrations 01–19 except for `menu_items`,
   `menu_categories`, `courier_cancellation_log` and `chat_messages`.
7. Whether `profiles_block_role_change`'s `WHEN (auth.uid() = OLD.id)` gate actually exempts
   SECURITY DEFINER callers — questioned at
   `.context/plans/migration-20-lock-orders-to-rpc-only-writes-dev-aw.md:128-131`.
8. The `delivered`-status trigger that writes full `courier_earnings` rows. It is referenced
   by comment three times (`12:10`, `16:72`, `13:556` `cleanup_cancelled_order`) but defined
   in no migration. Two named triggers — `create_courier_earning` and `cleanup_cancelled_order` —
   are load-bearing for the earnings ledger and exist only as comments.
