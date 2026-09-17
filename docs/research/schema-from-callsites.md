# Postgres schema reconstructed from the Swift call sites

**Method.** This document is derived *only* from what the Swift code sends to and decodes
from PostgREST/Realtime. It is an independent third source: it does not read the
migrations to establish facts. Where I did open `db/migrations/*.sql`, it is marked
explicitly as **CROSS-CHECK** and is never load-bearing for a column claim.

Every line reference is `path:line` against the working tree at the time of writing.

Scope read in full:
- `Sources/RavonCore/Services/SupabaseService.swift` (1457 lines)
- `Sources/RavonCore/Services/RealtimeService.swift` (537 lines)
- `Sources/RavonCore/Services/CourierLocationStreamer.swift` (127 lines)
- `Sources/RavonCore/Services/AuthService.swift` (180 lines)
- all 22 files in `Sources/RavonCore/Models/` (the `CodingKeys` are the column list)
- all Swift in the three app repos (grep for `from("`, `.rpc(`, `.channel(`, `supabaseClient`)

---

## 0. Headline findings (read these first)

### 0.1 The Swift call sites are the *primary* schema source, not a secondary one

**CROSS-CHECK:** `db/migrations/` contains exactly **one** `CREATE TABLE` across all
19 files — `courier_cancellation_log` in
`db/migrations/09_cancellation_reason_code_and_courier_cancel_log.sql:39`.
Every other table (orders, order_items, restaurants, menu_items, menu_categories,
addresses, profiles, chat_messages, courier_locations, courier_earnings,
order_status_history, restaurant_hours, modifier_groups, modifier_options,
menu_item_modifier_groups) was created out-of-band through the Supabase dashboard and
appears in the migrations only as `ALTER TABLE ... ADD COLUMN`.

Consequence for the Kotlin extraction: for **15 of 16 tables** the Swift `CodingKeys` +
filter columns are the *only* written record of the base column set. This document is
the schema.

### 0.2 Three RPCs have no definition anywhere in the repo — only a Swift call site

`add_tip`, `find_nearby_couriers`, `get_merchant_stats` return zero hits in
`db/migrations/*.sql`. Their wire contract exists *exclusively* at
`SupabaseService.swift:663`, `:711`, `:1453`. Section 3 is the only surviving spec.

### 0.3 `orders` is written directly by the client in SIX places — the "no client write
policies on orders" rule is blocked, and RavonCore itself is the main offender

`Sources/RavonCore/Models/OrderLifecycle.swift:78-80` asserts:

> "The SECURITY DEFINER function that performs this transition. There is no other legal
> way to move an order: `orders` carries no client UPDATE policy."

That is **false in the shipped code**. Five direct `UPDATE public.orders` statements live
in RavonCore itself, and a sixth in the consumer app. They are listed in Section 5 as
blocking work. Four of the five are reachable from the merchant UI today (verified
call sites in `ravon-merchant`), so they are not dead code.

`OrderLifecycle.swift:113-117` names four merchant RPCs — `merchant_accept_order`,
`merchant_reject_order`, `merchant_start_preparing`, `merchant_mark_order_ready` — that
**no Swift code calls** and that are absent from
`OrderLifecycle.implementedRPCs` (`OrderLifecycle.swift:197-209`). The lifecycle table
describes the intended design; the call sites describe the deployed one. They disagree.

### 0.4 Realtime requires `REPLICA IDENTITY FULL` on `public.orders`

`RealtimeService.swift:129`, `:181`, `:220`, `:410` read `change.oldRecord["status"]`.
Postgres only ships a populated `oldRecord` on UPDATE when the table's replica identity
is `FULL`; the default (`DEFAULT` = primary key only) yields `{"id": ...}` and every
`oldStatus` silently becomes `nil`. This is an infrastructure precondition that must
survive the Kotlin extraction, and it is stated nowhere else in the repo.

---

## 1. Tables, reconstructed

Nullability notation:
- **client-NOT-NULL** — Swift calls `decode(...)`, so a NULL crashes the decode. The
  client *requires* NOT NULL; this is a constraint the schema must satisfy.
- **client-nullable** — Swift calls `decodeIfPresent(...)`.
- **client-defaulted** — `decodeIfPresent(...) ?? x`: Swift tolerates a missing/NULL
  column. These are the columns where a dashboard-era schema could differ silently.

### 1.1 `orders`

Read/written at: `SupabaseService.swift:276, 284, 305, 394, 409, 423, 439, 590, 642, 774, 813`
and `ravon-consumer .../ConfirmOrderViewModel.swift:121`.

Columns proven by `Order` `CodingKeys` (`Models/Order.swift:320-365`):

| column | type | nullability | evidence |
|---|---|---|---|
| `id` | uuid PK | client-NOT-NULL | Order.swift:267 |
| `user_id` | uuid FK→auth.users | client-NOT-NULL | Order.swift:268 |
| `restaurant_id` | uuid FK→restaurants | client-NOT-NULL | Order.swift:269 |
| `address_id` | uuid FK→addresses | client-nullable | Order.swift:270 |
| `courier_id` | uuid FK→auth.users | client-nullable | Order.swift:271 |
| `status` | enum `order_status` | client-NOT-NULL | Order.swift:272 |
| `subtotal` | numeric | client-NOT-NULL | Order.swift:273 |
| `delivery_fee` | numeric | client-NOT-NULL | Order.swift:274 |
| `total` | numeric | client-NOT-NULL | Order.swift:275 |
| `delivery_address_snapshot` | jsonb | client-nullable | Order.swift:276 |
| `notes` | text | client-nullable | Order.swift:277 |
| `created_at` | timestamptz | client-NOT-NULL | Order.swift:278 |
| `updated_at` | timestamptz | client-NOT-NULL | Order.swift:279 |
| `estimated_delivery_time` | timestamptz | client-nullable | Order.swift:282 |
| `estimated_prep_time` | int | client-nullable | Order.swift:283; written at :397 |
| `cancellation_reason` | text (free-form, legacy) | client-nullable | Order.swift:284; written at :426 |
| `cancellation_reason_code` | text (CHECK-constrained) | client-nullable | Order.swift:285 |
| `cancelled_by` | uuid | client-nullable | Order.swift:286; written at :427 |
| `verification_code` | text (**pickup** code) | client-nullable | Order.swift:341 — Swift name is `pickupVerificationCode`, column is `verification_code` |
| `delivery_verification_code` | text | client-nullable | Order.swift:288 |
| `tip_amount` | numeric | client-nullable | Order.swift:289 |
| `picked_up_at` | timestamptz | client-nullable | Order.swift:290 |
| `delivered_at` | timestamptz | client-nullable | Order.swift:291 |
| `accepted_at` | timestamptz | client-nullable | Order.swift:292; written at :398 |
| `rejected_at` | timestamptz | client-nullable | Order.swift:293; written at :428 |
| `scheduled_for` | timestamptz | client-nullable | Order.swift:294 |
| `claimed_at` | timestamptz | client-nullable | Order.swift:295 |
| `arrived_at_restaurant_at` | timestamptz | client-nullable | Order.swift:296 |
| `arrived_at_customer_at` | timestamptz | client-nullable | Order.swift:297 |
| `expected_action_by` | timestamptz | client-nullable | Order.swift:298 |
| `eta_minutes` | int | client-nullable | Order.swift:299 |
| `courier_delay_reason_code` | text | client-nullable | Order.swift:300 |
| `courier_delay_explained_at` | timestamptz | client-nullable | Order.swift:301 |
| `courier_no_show_warned_at` | timestamptz | client-nullable | Order.swift:302 |
| `courier_no_show_escalated_at` | timestamptz | client-nullable | Order.swift:303 |
| `reassign_count` | int | client-defaulted `?? 0` | Order.swift:304 |
| `excluded_courier_ids` | uuid[] | client-defaulted `?? []` | Order.swift:305 — **array type, not jsonb**: decoded as `[UUID]` |
| `delivery_mode` | text CHECK | client-defaulted `?? hand_to_me` | Order.swift:306; written at ConfirmOrderViewModel.swift:122 |
| `delivery_proof_url` | text | client-nullable | Order.swift:307 — stores a storage **path**, not a URL (SupabaseService.swift:625-627) |
| `no_show` | bool | client-defaulted `?? false` | Order.swift:308 |
| `no_show_started_at` | timestamptz | client-nullable | Order.swift:309 |
| `restaurant_delay_min` | int | client-defaulted `?? 0` | Order.swift:310 |

Exact projections used:
- `"*, restaurants(*), order_items(*)"` — `:277, :285, :775, :814`
- `"*, order_items(*)"` — `:306` (merchant path; no restaurant embed)
- `"id"` — `:402, :413, :431, :443, :654` (write-then-confirm pattern)
- `"id,eta_minutes,expected_action_by,courier_delay_reason_code,courier_delay_explained_at,courier_no_show_warned_at,courier_no_show_escalated_at,status"` — `:591`

Filters / ordering seen on `orders`:
`eq(id)`, `eq(restaurant_id)`, `eq(courier_id)`, `eq(status)`,
`in(status, [...])`, `is(courier_id, nil)`,
`not(status, .in, "(...)")`, `order(created_at)` asc+desc, `order(updated_at)` desc,
`limit(1)`.

**Indexes the call sites imply:** `(restaurant_id, created_at desc)` for the merchant
dashboard (`:306-308`), `(courier_id, updated_at desc)` for courier state restore
(`:815-818`), and a partial index on `(status) WHERE courier_id IS NULL` for the
available-orders scan (`:776-778`).

### 1.2 `order_items` — reachable ONLY through the embed

`order_items` is **never** the subject of a `.from("order_items")` call. It is read solely
as the PostgREST embedded resource `order_items(*)` on `orders`
(`:277, :285, :306, :775, :814`). It still needs its own SELECT grant + RLS policy, or
every order fetch returns an empty `orderItems` array with no error.

Columns from `OrderItem` `CodingKeys` (`Models/Order.swift:432-443`):

| column | type | nullability | evidence |
|---|---|---|---|
| `id` | uuid PK | client-NOT-NULL | Order.swift:420 |
| `order_id` | uuid FK→orders | client-NOT-NULL | Order.swift:421 |
| `menu_item_id` | uuid FK→menu_items, `ON DELETE SET NULL` | client-nullable | Order.swift:422 + comment :389-391 |
| `quantity` | int | client-NOT-NULL | Order.swift:423 |
| `unit_price` | numeric | client-NOT-NULL | Order.swift:424 |
| `total_price` | numeric | client-NOT-NULL | Order.swift:425 |
| `item_name` | text | client-NOT-NULL | Order.swift:426 |
| `item_description` | text | client-nullable | Order.swift:427 |
| `item_image_url` | text | client-nullable | Order.swift:428 |
| `modifiers_snapshot` | jsonb `[{group_name,option_name,price_adjustment}]` | client-defaulted `?? []` | Order.swift:429; element keys at Order.swift:379-383 |

The embed decodes into `[OrderItem]?`, proving a **to-many** FK `order_items.order_id → orders.id`.

### 1.3 `restaurants`

Read/written at `:176, :187, :1028, :1117, :1130, :1147, :1159, :1171, :1183, :1407`.
Also the target of the `restaurants(*)` embed on `orders`, decoded into a **single**
`Restaurant?` (`Models/Order.swift:280`, CodingKey `restaurants` at `:333`) — proving a
**to-one** FK `orders.restaurant_id → restaurants.id`.

| column | type | nullability | evidence |
|---|---|---|---|
| `id` | uuid PK | client-NOT-NULL | Restaurant.swift:68 |
| `name` | text | client-NOT-NULL | Restaurant.swift:69 |
| `description` | text | client-nullable | Restaurant.swift:70 |
| `image_url` | text | client-nullable | Restaurant.swift:71; written at :1408 |
| `cuisine_type` | text | client-NOT-NULL | Restaurant.swift:72 |
| `rating` | numeric | client-NOT-NULL | Restaurant.swift:73; `order("rating", desc)` at :179 |
| `delivery_time_min` | int | client-NOT-NULL | Restaurant.swift:74 |
| `delivery_fee` | numeric | client-NOT-NULL | Restaurant.swift:75 |
| `min_order_amount` | numeric | client-NOT-NULL | Restaurant.swift:76 |
| `address` | text | client-nullable | Restaurant.swift:77 |
| `latitude` | double precision | client-nullable | Restaurant.swift:78 |
| `longitude` | double precision | client-nullable | Restaurant.swift:79 |
| `opening_time` | **text** ("HH:mm:ss") | client-nullable | Restaurant.swift:80 — decoded as `String`, not `time` |
| `closing_time` | **text** | client-nullable | Restaurant.swift:81 |
| `max_concurrent_orders` | int | client-nullable | Restaurant.swift:82; written at :1026 |
| `is_accepting_orders` | bool | client-defaulted `?? true` | Restaurant.swift:83 |
| `accepting_orders_until` | timestamptz | client-nullable | Restaurant.swift:84 |
| `owner_id` | uuid | client-nullable | Restaurant.swift:85; `eq("owner_id")` at :1132 |
| `restaurant_status` | text/enum `draft\|active\|paused\|closed` | client-defaulted `?? active` | Restaurant.swift:86; filtered at :178 |

INSERT payload keys (`RestaurantInsert`, Restaurant.swift:144-150) — the *only* columns
the client ever inserts: `name, description, address, latitude, longitude, cuisine_type,
delivery_fee, min_order_amount, delivery_time_min`. Everything else must have a DB
default or the insert at `:1118` fails.

`fetchMyRestaurant` uses `eq("owner_id") .limit(1)` (`:1130-1135`), and
`createRestaurant` pre-checks it (`:1114`) with the comment "1 per merchant enforced by
DB unique index" (`:1108`) → implies **UNIQUE(owner_id)** on `restaurants`. That index is
not provable from the repo. **UNKNOWN — needs live introspection.**

### 1.4 `menu_items`

Read/written at `:237, :940, :968, :976, :999, :1201, :1253, :1278, :1291, :1299, :1425`.

| column | type | nullability | evidence |
|---|---|---|---|
| `id` | uuid PK | client-NOT-NULL | MenuItem.swift:33 |
| `category_id` | uuid FK→menu_categories | client-NOT-NULL | MenuItem.swift:34; `eq("category_id")` at :1255 |
| `restaurant_id` | uuid FK→restaurants | client-NOT-NULL | MenuItem.swift:35 |
| `name` | text | client-NOT-NULL | MenuItem.swift:36 |
| `description` | text | client-nullable | MenuItem.swift:36 |
| `price` | numeric | client-NOT-NULL | MenuItem.swift:36; `gt("price", 0)` at :1205 |
| `image_url` | text | client-nullable | MenuItem.swift:37; written at :1426 |
| `is_available` | bool | client-NOT-NULL | MenuItem.swift:38 |
| `sort_order` | int | client-NOT-NULL | MenuItem.swift:39 |
| `stock_count` | int | client-nullable | MenuItem.swift:40; written null-able at :975-977 |
| `deleted_at` | timestamptz (soft delete) | client-nullable | MenuItem.swift:41 |

INSERT keys (`MenuItemInsert`, MenuItem.swift:72-79): `name, description, price,
restaurant_id, category_id, image_url, is_available, sort_order`.

UPDATE key sets: `{is_available}` `:969`; `{stock_count}` `:977`;
`{name,description,price,is_available,sort_order,stock_count}` `:992-997`;
`{deleted_at}` `:1292` / `:1300`; `{image_url}` `:1426`.

Consumer-visibility predicate (must be reproduced exactly in Kotlin), `:239-242`:
`restaurant_id = ? AND is_available = true AND deleted_at IS NULL ORDER BY sort_order`.

### 1.5 `menu_categories`

Read/written at `:225, :950, :961, :1231, :1244, :1261, :1269`.

| column | type | nullability | evidence |
|---|---|---|---|
| `id` | uuid PK | client-NOT-NULL | MenuCategory.swift:24 |
| `restaurant_id` | uuid FK | client-NOT-NULL | MenuCategory.swift:25 |
| `name` | text | client-NOT-NULL | MenuCategory.swift:26 |
| `sort_order` | int | client-NOT-NULL | MenuCategory.swift:27 |
| `is_available` | bool | client-defaulted `?? true` | MenuCategory.swift:28 |
| `deleted_at` | timestamptz | client-nullable | MenuCategory.swift:29 |

INSERT keys: `name, restaurant_id, sort_order` (MenuCategory.swift:55-59).
UPDATEs: `{is_available}` `:962`; `{name,sort_order}` `:1241-1242`; `{deleted_at}` `:1262`/`:1270`.

### 1.6 `addresses`

Read/written at `:250, :258, :267`.

| column | type | nullability | evidence |
|---|---|---|---|
| `id` | uuid PK | client-NOT-NULL | Address.swift:41 |
| `user_id` | uuid FK→auth.users | client-NOT-NULL | Address.swift:42 |
| `label` | text | client-NOT-NULL | Address.swift:43 |
| `street` | text | client-NOT-NULL | Address.swift:44 |
| `apartment` | text | client-nullable | Address.swift:45 |
| `city` | text | client-NOT-NULL | Address.swift:46 |
| `latitude` | double precision | client-nullable | Address.swift:47 |
| `longitude` | double precision | client-nullable | Address.swift:48 |
| `is_default` | bool | client-NOT-NULL | Address.swift:49; `order("is_default", desc)` at :252 |
| `default_delivery_mode` | text CHECK | client-defaulted `?? hand_to_me` | Address.swift:50 |
| `created_at` | timestamptz | client-NOT-NULL | Address.swift:51 |

**`fetchAddresses()` (`:250-254`) has NO `user_id` filter.** The entire tenancy boundary
for addresses is RLS. Same for `fetchOrders()` (`:276-280`). If the Kotlin service reads
these tables with a service-role connection, it must re-add the `user_id = ?` predicate
in code — nothing in the query carries it.

`AddressSnapshot` (Address.swift:101-116) has **no `CodingKeys`**, so the jsonb shape in
`orders.delivery_address_snapshot` is camelCase-free plain keys:
`label, street, apartment, city, latitude, longitude` — all optional.

### 1.7 `profiles`

Read at `AuthService.swift:44-49` (`select("*")`) and `SupabaseService.swift:147-152`
(`select()`); written at `:163-166`.

| column | type | nullability | evidence |
|---|---|---|---|
| `id` | uuid PK = auth.users.id | client-NOT-NULL | Profile.swift:33 |
| `full_name` | text | client-NOT-NULL | Profile.swift:34; written at :160 |
| `phone` | text | client-nullable | Profile.swift:35; written (incl. explicit `.null`) at :162 |
| `role` | enum `user_role` | client-NOT-NULL | Profile.swift:36 |
| `avatar_url` | text | client-nullable | Profile.swift:37 |
| `is_suspended_until` | timestamptz | client-nullable | Profile.swift:38 |
| `created_at` | timestamptz | client-NOT-NULL | Profile.swift:39 |
| `updated_at` | timestamptz | client-NOT-NULL | Profile.swift:40 |

### 1.8 `chat_messages`

Read/written at `:1060, :1072, :1084, :1096`; subscribed at `RealtimeService.swift:432`.

| column | type | nullability | evidence |
|---|---|---|---|
| `id` | uuid PK | client-NOT-NULL | ChatMessage.swift:43 |
| `order_id` | uuid FK→orders | client-NOT-NULL | ChatMessage.swift:44 |
| `sender_id` | uuid FK→auth.users | client-NOT-NULL | ChatMessage.swift:45 |
| `sender_role` | text CHECK, trigger-set | client-nullable | ChatMessage.swift:46 |
| `body` | text | client-NOT-NULL | ChatMessage.swift:47 |
| `read_at` | timestamptz | client-nullable | ChatMessage.swift:48; written at :1085 |
| `created_at` | timestamptz | client-NOT-NULL | ChatMessage.swift:49 |

INSERT keys are only `order_id, sender_id, body` (ChatMessage.swift:74-78) — `sender_role`
is deliberately **not** client-writable; the server trigger sets it.

Mark-read predicate (`:1084-1089`), which the Kotlin service must honour exactly:
`order_id = ? AND sender_id <> <me> AND read_at IS NULL` → `SET read_at = now()`.
Unread count uses the identical predicate with `select("id")` (`:1096-1102`) and counts
rows **client-side** — no `count=exact` header, so it materialises every unread row.

### 1.9 `courier_locations`

Read/written at `:687, :693, :730, :739, :749, :829`; subscribed at `RealtimeService.swift:342`.

| column | type | nullability | evidence |
|---|---|---|---|
| `courier_id` | uuid PK (conflict target) | client-NOT-NULL | CourierLocation.swift:53; `onConflict: "courier_id"` at :688, :731 |
| `latitude` | double precision | client-NOT-NULL | CourierLocation.swift:54 |
| `longitude` | double precision | client-NOT-NULL | CourierLocation.swift:55 |
| `heading` | double precision | client-nullable | CourierLocation.swift:56 |
| `speed` | double precision | client-nullable | CourierLocation.swift:57 |
| `is_online` | bool | client-NOT-NULL | CourierLocation.swift:58; written at :740 |
| `current_order_id` | uuid FK→orders | client-nullable | CourierLocation.swift:59; nulled at :830 |
| `last_updated` | timestamptz | client-NOT-NULL | CourierLocation.swift:60 |
| `last_heartbeat_at` | timestamptz | client-defaulted `?? last_updated` | CourierLocation.swift:61 |
| `last_moved_at` | timestamptz | client-defaulted `?? last_updated` | CourierLocation.swift:62 |
| `accuracy_meters` | double precision | client-nullable | CourierLocation.swift:63 |
| `ghost_strikes` | int | client-defaulted `?? 0` | CourierLocation.swift:64 |
| `strikes_reset_at` | timestamptz | client-defaulted `?? last_updated` | CourierLocation.swift:65 |

`onConflict: "courier_id"` proves **PRIMARY KEY or UNIQUE(courier_id)**.

Upsert payload (`CourierLocationUpsert`, CourierLocation.swift:105-110):
`courier_id, latitude, longitude, heading, speed, is_online, current_order_id`.
Swift's synthesised `Encodable` uses `encodeIfPresent` for optionals, so `heading`,
`speed` and `current_order_id` are **omitted** when nil — meaning
`goOnline()` (`:724-732`) does *not* clobber an existing `current_order_id`. The Kotlin
equivalent must reproduce that partial-update semantic or it will orphan active orders.

### 1.10 `courier_earnings`

Read at `:848-870` only. Never written from the client.

| column | type | nullability | evidence |
|---|---|---|---|
| `id` | uuid PK | client-NOT-NULL | CourierEarning.swift:64 |
| `courier_id` | uuid | client-NOT-NULL | CourierEarning.swift:65; `eq` at :850 |
| `order_id` | uuid | client-NOT-NULL | CourierEarning.swift:66 |
| `delivery_fee` | numeric | client-NOT-NULL | CourierEarning.swift:67 |
| `tip_amount` | numeric | client-NOT-NULL | CourierEarning.swift:68 |
| `total_earned` | numeric | client-NOT-NULL | CourierEarning.swift:69 |
| `earning_type` | text CHECK | client-defaulted `?? full` | CourierEarning.swift:70 |
| `tier_pct` | int | client-defaulted `?? 100` | CourierEarning.swift:71 |
| `cancellation_reason_code` | text | client-nullable | CourierEarning.swift:72 |
| `status_at_event` | enum `order_status` | client-nullable | CourierEarning.swift:73 |
| `created_at` | timestamptz | client-NOT-NULL | CourierEarning.swift:74; `gte` + `order` at :856-868 |

Note: `fetchEarningsSummary` (`:873-881`) builds `EarningsSummary` **without**
`totalClawbacks`, so it silently defaults to 0 (CourierEarning.swift:103) even though
`isClawback` exists (CourierEarning.swift:77). Negative `tier_pct` rows are therefore
summed into `totalEarned` rather than surfaced. Product bug, not a schema bug — but the
Kotlin aggregation endpoint should not copy it.

### 1.11 `courier_cancellation_log`

Read at `:603-609` only. **Only two columns are provable from Swift:**

| column | type | nullability | evidence |
|---|---|---|---|
| `courier_id` | uuid | — | `eq("courier_id")` at :605 |
| `created_at` | timestamptz | client-NOT-NULL | anonymous `struct Row { let created_at: Date }` at :602; `gte`+`order` at :606-607 |

Note the local `Row` type uses a **snake_case Swift property with no CodingKeys**
(`:602`) — it decodes `created_at` by exact property-name match. Any other column on this
table is invisible to the client. The cooldown rule is computed client-side at
`:610-612`: `count >= 3` within 24h → cooldown lifts at `oldest + 24h`.

### 1.12 `restaurant_hours`

Read at `:886-891`, upserted at `:895-897`.

| column | type | nullability | evidence |
|---|---|---|---|
| `id` | uuid PK | client-NOT-NULL | RestaurantHours.swift:27 |
| `restaurant_id` | uuid FK | client-NOT-NULL | RestaurantHours.swift:28 |
| `day_of_week` | int, **0=Sun..6=Sat** | client-NOT-NULL | RestaurantHours.swift:29 + dayName map :36-44 |
| `opening_time` | **text** "HH:mm:ss" | client-NOT-NULL | RestaurantHours.swift:30; parsed as string at :96-102 |
| `closing_time` | **text** | client-NOT-NULL | RestaurantHours.swift:31 |
| `is_closed` | bool | client-NOT-NULL | RestaurantHours.swift:32 |

`onConflict: "restaurant_id,day_of_week"` (`:896`) proves
**UNIQUE(restaurant_id, day_of_week)**.
Times are interpreted in **Asia/Dushanbe (UTC+5)** — RestaurantHours.swift:3, :57.
The upsert payload omits `id` (RestaurantHoursUpsert, RestaurantHours.swift:124-130), so
`id` must have a DB default.

### 1.13 `modifier_groups`

Read/written at `:917, :927, :1308, :1327, :1334`.

| column | type | nullability | evidence |
|---|---|---|---|
| `id` | uuid PK | — | Modifier.swift:29; `in("id", [...])` at :919 |
| `restaurant_id` | uuid FK | — | Modifier.swift:30 |
| `name` | text | — | Modifier.swift:31 |
| `is_required` | bool | — | Modifier.swift:32 |
| `min_selections` | int | — | Modifier.swift:33 |
| `max_selections` | int | — | Modifier.swift:34 |
| `sort_order` | int | — | Modifier.swift:35 |

`ModifierGroup` uses the **compiler-synthesised** decoder (no custom `init(from:)`), so
every one of those seven columns is client-NOT-NULL — a NULL in any of them crashes the
merchant menu screen.

Projection `"*, modifier_options(*)"` at `:918, :928, :1310`. The embed decodes into
`[ModifierOption]?` under CodingKey `modifier_options` (Modifier.swift:36) → to-many FK
`modifier_options.group_id → modifier_groups.id`.

### 1.14 `modifier_options`

Read via embed; written at `:1343, :1361, :1367`.

| column | type | nullability | evidence |
|---|---|---|---|
| `id` | uuid PK | client-NOT-NULL | Modifier.swift:61 |
| `group_id` | uuid FK→modifier_groups | client-NOT-NULL | Modifier.swift:62 |
| `name` | text | client-NOT-NULL | Modifier.swift:63 |
| `price_adjustment` | numeric | client-NOT-NULL | Modifier.swift:64 |
| `is_available` | bool | client-NOT-NULL | Modifier.swift:65 |
| `sort_order` | int | client-NOT-NULL | Modifier.swift:66 |

INSERT keys (`ModifierOptionInsert`, Modifier.swift:135-140): `name, group_id,
price_adjustment, sort_order` — **`is_available` is never inserted**, so it needs a DB
default or every new option decodes as a crash.

### 1.15 `menu_item_modifier_groups` (junction)

Read at `:910-914`, inserted `:1378-1380`, deleted `:1384-1388`.

| column | type | evidence |
|---|---|---|
| `menu_item_id` | uuid FK→menu_items | Modifier.swift:80; `eq` at :912, :1386 |
| `modifier_group_id` | uuid FK→modifier_groups | Modifier.swift:81; `eq` at :1387 |

`select()` decodes into `[MenuItemModifierGroup]` which has **exactly** these two
properties and a synthesised decoder → a bare `select()` returning any additional NOT-NULL
column is fine (extra keys are ignored), but both of these must be present. This is a
composite-key junction; the delete-by-both-eq pattern implies
**PRIMARY KEY (menu_item_id, modifier_group_id)**.

Note: `fetchModifierGroups` does an **N+1-ish two-hop** (`:910` then `:917`) instead of
a single embed through the junction. The Kotlin service should expose one endpoint.

### 1.16 `order_status_history`

Read at `:293-298` only. Never written from the client (trigger/RPC-populated).

| column | type | nullability | evidence |
|---|---|---|---|
| `id` | uuid PK | client-NOT-NULL | Order.swift:463 |
| `order_id` | uuid FK→orders | client-NOT-NULL | Order.swift:465; `eq` at :295 |
| `status` | enum `order_status` | client-NOT-NULL | Order.swift:466 |
| `changed_by` | uuid | client-nullable | Order.swift:467 |
| `notes` | text | client-nullable | Order.swift:468 |
| `created_at` | timestamptz | client-NOT-NULL | Order.swift:469; `order("created_at")` at :296 |

`OrderStatusHistory` uses the synthesised decoder, so `changed_by`/`notes` are nullable
only because the Swift properties are `Optional`.

---

## 2. Views / DB functions referenced in comments but never called

- `restaurants_orderable` view with `is_orderable_now` — described at
  `SupabaseService.swift:171-173` but **no call site queries it**. `fetchRestaurants`
  (`:176`) hits the base `restaurants` table.
- `restaurant_is_orderable()` / `restaurant_within_hours()` — named at `:901-903` and
  `RealtimeService.swift:74` as "source of truth", but only reachable indirectly via the
  `get_restaurant_orderability` RPC.
- `orders_sync_delivery_mode` BEFORE INSERT trigger — named at `Models/Address.swift:14`.
- `handle_new_user` trigger — named at `AuthService.swift:62`.
- `pg_cron` jobs: auto-resume of `is_accepting_orders` (`:1038-1041`), 30-day soft-delete
  purge (`:1250, :1288`).

---

## 3. RPC wire contracts — the Kotlin service must honour these byte-for-byte

All 21 calls, in file order. "Void" = `.execute()` with the result discarded, so the
function's return type is unconstrained by the client.

| # | RPC | params (Swift type) | decoded return | call site |
|---|---|---|---|---|
| 1 | `get_restaurant_orderability` | `p_restaurant_id: UUID`, `p_at: Date?` | `RestaurantOrderability` = `{is_orderable_now: Bool, reason: <OrderabilityReason jsonb>, opens_at: Date?}` | SupabaseService.swift:216 |
| 2 | `create_order` | `p_restaurant_id: UUID`, `p_address_id: UUID`, `p_items: [{menu_item_id: UUID, quantity: Int}]`, `p_notes: String?`, `p_scheduled_for: Date?` | **`String`** parsed via `UUID(uuidString:)` → SQL `RETURNS uuid` | :360-364 |
| 3 | `validate_cart` | `p_restaurant_id: UUID`, `p_items: [{menu_item_id, quantity}]`, `p_scheduled_for: Date?` | `CartValidationResult` jsonb (see 3.1) | :388 |
| 4 | `courier_arrived_restaurant` | `p_order_id: UUID` | Void | :453 |
| 5 | `courier_pickup_order` | `p_order_id: UUID`, `p_verification_code: String` | Void | :458 |
| 6 | `courier_start_delivering` | `p_order_id: UUID` | Void | :465 |
| 7 | `courier_arrived_at_customer` | `p_order_id: UUID` | Void | :470 |
| 8 | `courier_deliver_order` | `p_order_id: UUID`, `p_delivery_code: String?`, `p_delivery_proof_url: String?` | Void | :488 |
| 9 | `cancel_order_by_courier` | `p_order_id: UUID`, `p_reason_code: String` | Void | :503 |
| 10 | `report_problem_post_pickup` | `p_order_id: UUID`, `p_reason_code: String`, `p_free_form: String?` | Void | :521 |
| 11 | `courier_explain_delay` | `p_order_id: UUID`, `p_reason_code: String`, `p_free_form: String?` | Void | :538 |
| 12 | `courier_report_customer_no_show` | `p_order_id: UUID` | Void | :547 |
| 13 | `courier_report_restaurant_delay` | `p_order_id: UUID`, `p_extra_minutes: Int` | Void | :558 |
| 14 | `update_courier_heartbeat` | `p_latitude: Double`, `p_longitude: Double`, `p_accuracy_meters: Double?`, `p_heading: Double?`, `p_speed: Double?` | Void | :580 |
| 15 | `cancel_order_by_consumer` | `p_order_id: UUID`, `p_reason: String?` | Void | :634 |
| 16 | `add_tip` | `p_order_id: UUID`, `p_amount: Double` | Void | :663 |
| 17 | `find_nearby_couriers` | `p_latitude: Double`, `p_longitude: Double`, `p_radius_km: Double` | `[NearbyCourier]` = `[{courier_id, latitude, longitude, heading?, speed?, distance_km, last_updated}]` | :711 |
| 18 | `claim_order` | `p_order_id: UUID` | **`String`** → uuid | :763 |
| 19 | `fetch_available_orders` | `p_latitude: Double`, `p_longitude: Double`, `p_radius_km: Double` | `[Order]` | :794 |
| 20 | `set_accepting_orders` | `p_restaurant_id: UUID`, `p_accepting: Bool`, `p_until: Date?` | Void | :1048 |
| 21 | `get_merchant_stats` | `p_restaurant_id: UUID` | `MerchantStats` = `{today_order_count: Int, today_revenue: Double, average_order_value: Double, active_order_count: Int}` | :1453 |

Swift defaults applied client-side before the wire (Kotlin must decide whether to keep
them as client or server defaults):
- `find_nearby_couriers`: `radiusKm = 5.0` (`:704`)
- `fetch_available_orders`: `radiusKm = 10.0` (`:787`) — **CROSS-CHECK:** the SQL default
  is `50.0` (`db/migrations/13_...sql:718`). Swift always passes explicitly, so the
  divergence is latent, not live.

### 3.1 `validate_cart` return jsonb — exact shape

From `Models/CartValidation.swift`:

```
{
  "orderable":        bool,                       // :204
  "reason":           { "kind": <KIND>, ... },    // :13-28
  "items":            [ { "menu_item_id": uuid, "status": <STATUS>, ... } ],  // :99-112, :171
  "subtotal":         number,                     // :204
  "min_order_amount": number,                     // :205
  "min_order_met":    bool                        // :206
}
```

`reason.kind` ∈ `OK | RESTAURANT_CLOSED | RESTAURANT_PAUSED | RESTAURANT_NOT_ACCEPTING |
OUT_OF_HOURS | OVERLOADED | MIN_ORDER_NOT_MET` (CartValidation.swift:21-28), with
sibling keys `until` (RESTAURANT_NOT_ACCEPTING), `opens_at` (OUT_OF_HOURS), `need`
(MIN_ORDER_NOT_MET, **required** — `decode` not `decodeIfPresent`, :40).

`items[].status` ∈ `OK | UNAVAILABLE | INSUFFICIENT_STOCK | DELETED | PRICE_CHANGED`
(CartValidation.swift:106-112), with sibling keys `have` (INSUFFICIENT_STOCK, required
:120) and `old_price` + `new_price` (PRICE_CHANGED, both required :124-125).

Note `CartItemValidation.init(from:)` (`:158-162`) decodes the status from the **same
flat object** as `menu_item_id` — the status is NOT nested. The element is
`{"menu_item_id": "...", "status": "PRICE_CHANGED", "old_price": 100, "new_price": 120}`.

### 3.2 `get_restaurant_orderability` return

`{"is_orderable_now": bool, "reason": <same OrderabilityReason object>, "opens_at": timestamptz?}`
— `SupabaseService.swift:197-207`. Note `reason` reuses the nested `{kind:...}` object,
so this RPC returns a jsonb/composite, not a flat record.

### 3.3 Date encoding — two different formats on the wire

- RPC `Date?` params (`p_at`, `p_scheduled_for`, `p_until`) are encoded by the Supabase
  Swift SDK's own `JSONEncoder`.
- Timestamps the service stamps *itself* use `ISO8601DateFormatter()` with **default
  options** (`SupabaseService.swift:139`) — no fractional seconds. Affected writes:
  `accepted_at` (`:398`), `rejected_at` (`:428`), `read_at` (`:1085`),
  `deleted_at` (`:1262`, `:1292`), and the `gte` bounds at `:606`, `:856-862`.

All of those are computed from the **client clock** (`Date()`), not `now()`. Clock skew
on a courier's phone writes skewed audit timestamps. The Kotlin service should move every
one of these to `now()` server-side.

### 3.4 Typed-error contract: `ServiceError.from(serverError:)`

`SupabaseService.swift:90-127` parses `"reason":"<KIND>"` out of the PostgREST error
`DETAIL` with the regex `"reason"\s*:\s*"([A-Z_]+)"` (`:98`). The recognised kinds are
the 17 listed at `:107-124`. Any RPC the Kotlin service reimplements must keep emitting
`DETAIL = jsonb_build_object('reason', '<KIND>')` with those exact strings.

**Two defects here:**
1. The function has **zero production call sites** — its only three callers are
   `Tests/RavonCoreTests/CourierCancellationTests.swift:55,65,74`. Every RPC call in
   `SupabaseService.swift` lets the raw `PostgrestError` propagate, so the entire typed
   taxonomy at `ServiceError:26-38` is unreachable in the shipped apps.
2. `ROLE_CHANGE_FORBIDDEN` is **not** in the switch (`:106-125`), despite
   `db/migrations/19_lock_down_profile_role.sql:14` claiming it was added
   "so the Swift `ServiceError.from(serverError:)` decoder can surface a typed
   `.unauthorized`". It returns `nil`.

---

## 4. Realtime — what must keep flowing through Supabase Realtime

Eight channels, all `schema: "public"`. `RealtimeService.swift`:

| channel name | action type | table | filter | line |
|---|---|---|---|---|
| `order-<orderId>` | `UpdateAction` | `orders` | `eq("id", orderId)` | 113-119 |
| `restaurant-orders-<restaurantId>` | `AnyAction` (I/U/D) | `orders` | `eq("restaurant_id", restaurantId)` | 149-155 |
| `courier-orders-<courierId>` | `UpdateAction` | `orders` | `eq("courier_id", courierId)` | 204-210 |
| `menu-<restaurantId>` | `UpdateAction` | `menu_items` | `eq("restaurant_id", restaurantId)` | 245-251 |
| `restaurant-status-<restaurantId>` | `UpdateAction` | `restaurants` | `eq("id", restaurantId)` | 301-307 |
| `courier-location-<courierId>` | `UpdateAction` | `courier_locations` | `eq("courier_id", courierId)` | 342-348 |
| `available-orders` | `AnyAction` | `orders` | **NONE** | 383-388 |
| `chat-<orderId>` | `InsertAction` | `chat_messages` | `eq("order_id", orderId)` | 432-438 |

**Publication requirement:** `supabase_realtime` must include exactly five tables —
`orders`, `menu_items`, `restaurants`, `courier_locations`, `chat_messages`.

**Replica identity requirement:** `orders` needs `REPLICA IDENTITY FULL` (see 0.4).
`menu_items`, `restaurants`, `courier_locations`, `chat_messages` never read `oldRecord`,
so `DEFAULT` suffices for them.

Fields read off each payload (these columns must be in the replicated row):
- `orders`: `status` (`:126`, `:164`, `:178`, `:407`), `id` (`:167`, `:184`, `:223`, `:413`),
  plus the **entire** `record` dict is forwarded to consumers as
  `OrderChangeEvent.record` (`RealtimeService.swift:8`) — so downstream UI can read any
  column. Do not trim the payload.
- `menu_items`: `id`, `is_available`, `stock_count`, `deleted_at` (`:258-271`)
- `restaurants`: `restaurant_status`, `is_accepting_orders`, `accepting_orders_until` (`:314-322`)
- `courier_locations`: `latitude`, `longitude`, `heading`, `speed` (`:355-362`)
- `chat_messages`: `id`, `sender_id`, `sender_role`, `body`, `read_at`, `created_at` (`:445-459`)

### 4.1 Two realtime decode hazards worth fixing during the extraction

**(a) `courier_locations` lat/lng are matched against `.double` only.**
`RealtimeService.swift:355-362` uses `if case .double(let d) = $0` for all four numeric
fields. If those columns are `numeric` rather than `double precision`, `AnyJSON` yields
`.integer`/`.string` and **every location event is silently dropped** — no error, just a
frozen courier pin. Contrast `:263-267`, which correctly handles both `.integer` and
`.double` for `stock_count`. Whether the columns are `double precision` is
**UNKNOWN — needs live introspection**; the `update_courier_heartbeat` grant signature
(CROSS-CHECK, `13_...sql:740`) uses `double precision` params, which is suggestive but
not proof about the column type.

**(b) Realtime timestamps are parsed with bare `ISO8601DateFormatter()`.**
`:269`, `:320`, `:463`, `:465`. That formatter rejects fractional seconds and requires a
`T` separator. The exact wire format Supabase Realtime emits for `timestamptz` is
**UNKNOWN — needs live introspection**, but if it carries microseconds then:
`menu_items.deleted_at` → `nil` → `isSoftDeleted` wrongly `false` (a soft-deleted item
stays in the cart); `restaurants.accepting_orders_until` → `nil` → the "not accepting
until HH:mm" chip never renders; `chat_messages.created_at` → falls back to `Date()`
(`:463`), so messages get the receive time, not the send time.

### 4.2 Channel-lifecycle bug (pre-existing, affects migration testing)

All three order subscriptions (`subscribeToOrder`, `subscribeToRestaurantOrders`,
`subscribeToCourierOrders`) share the single `orderChannel` slot (`:121`, `:157`, `:212`)
and each calls `unsubscribeFromOrders()` first (`:112`, `:148`, `:203`). A screen that
wants both its own order *and* the available-orders feed is fine (separate slots), but a
courier screen cannot watch its assigned order and a specific order at once — the second
subscribe silently kills the first. Also `unsubscribeAll()` (`:530-536`) omits
`unsubscribeFromRestaurantStatus()`, leaking that channel on sign-out.

---

## 5. BLOCKING WORK: direct client writes to orders / order_items / order_status_history

The plan's rule is "no client write policies on `orders`". Here is every write that
breaks it. `order_items` and `order_status_history` have **zero** client writes — they are
already clean.

### 5.1 In RavonCore (shared library) — 5 direct `UPDATE public.orders`

| # | function | payload keys | guard predicate | file:line |
|---|---|---|---|---|
| 1 | `acceptOrder(orderId:estimatedPrepMinutes:)` | `status='accepted'`, `estimated_prep_time`, `accepted_at` | `id = ? AND status = 'created'` | `Sources/RavonCore/Services/SupabaseService.swift:394-404` |
| 2 | `startPreparing(orderId:)` | `status='preparing'` | `id = ? AND status = 'accepted'` | `SupabaseService.swift:409-415` |
| 3 | `rejectOrder(orderId:reason:)` | `status='rejected'`, `cancellation_reason`, `cancelled_by`, `rejected_at` | `id = ? AND status = 'created'` | `SupabaseService.swift:423-434` |
| 4 | `markOrderReady(orderId:)` | `status='ready'` | `id = ? AND status IN ('accepted','preparing')` | `SupabaseService.swift:439-445` |
| 5 | `assignCourier(orderId:courierId:)` | `status='assigned'`, `courier_id` | `id = ? AND status IN ('accepted','preparing','ready') AND courier_id IS NULL` | `SupabaseService.swift:642-656` |

All five use the same optimistic-concurrency idiom: `.select("id")` after the update and
`guard !results.isEmpty else { throw ... }` — the empty-result set is the "someone else
got there first" signal. That idiom must be preserved (or replaced by an RPC that raises)
in Kotlin, or races become silent no-ops.

**Reachability (verified):**
- #1 → `ravon-merchant/milan/RavonMerchant/RavonMerchant/ViewModels/OrdersViewModel.swift:124`
- #3 → `.../OrdersViewModel.swift:133`
- #2 → `.../OrdersViewModel.swift:144`
- #4 → `.../OrdersViewModel.swift:146`
- #5 `assignCourier` → **zero app call sites** across all three repos. Dead code, but it
  is still a `public` API on the shared library and still writes `orders`.

**The four live ones are exactly the four transitions `OrderLifecycle.swift:113-117`
claims go through `merchant_accept_order` / `merchant_reject_order` /
`merchant_start_preparing` / `merchant_mark_order_ready`.** Those four RPCs do not exist
(they are absent from `OrderLifecycle.implementedRPCs` at `:197-209`, and grep finds no
Swift call site). Writing those four RPCs is the prerequisite for revoking client UPDATE
on `orders`.

### 5.2 In the consumer app — 1 direct `UPDATE public.orders`

```
/Users/mmarufov/conductor/workspaces/ravon-consumer/kolkata/DuDash/ViewModels/ConfirmOrderViewModel.swift:121
    try? await AuthService.shared.supabaseClient.from("orders")
        .update(["delivery_mode": AnyJSON.string(override.rawValue)])
        .eq("id", value: id.uuidString)
        .execute()
```

Column written: `orders.delivery_mode`. Fired immediately after `create_order` returns,
only when the user overrode the address default (`:120`). Note it is `try?` — the failure
is swallowed by design (`:117-119`). This is the **only** place in any of the three apps
that touches a table outside RavonCore.

**Fix shape:** fold `p_delivery_mode` into `create_order`'s parameter list, or add a
narrow `set_order_delivery_mode(p_order_id, p_mode)` RPC. Either removes the last app-level
`orders` write.

### 5.3 Merchant calls the *consumer's* cancel RPC

`ravon-merchant/.../OrdersViewModel.swift:158` calls
`SupabaseService.shared.cancelOrder(orderId:reason:)`, which is
`cancel_order_by_consumer` (`SupabaseService.swift:634`). `OrderLifecycle.swift:170-174`
documents this as a known gap needing `merchant_cancel_order`. Not a policy violation
(it's an RPC), but it is a wrong-actor call the Kotlin service must not inherit.

### 5.4 Not violations, for the record

- `ravon-consumer/.../Views/Orders/OrderDetailView.swift:786-788` —
  `storage.from("delivery-proofs").createSignedURL(path:expiresIn: 3600)`. Storage, not a
  table.
- `ravon-merchant`: **0** occurrences of `from("`, `.rpc(`, `.channel(`, `supabaseClient`,
  `import Supabase` in any Swift file.
- `ravon-courier`: **0** occurrences of the same. Entirely RavonCore-gated.
- `ravon-consumer/kolkata/backend/` (FastAPI): `get_supabase_admin()` /
  `get_supabase_user()` exist at `backend/app/supabase_client.py:9,22` but have
  **zero call sites** (grep across the whole backend). No table access. The only routes
  are `/health`, `/api/v1/hello`, `/api/v1/auth/me`.

---

## 6. Storage buckets implied by the call sites

| bucket | path template | options | visibility | line |
|---|---|---|---|---|
| `delivery-proofs` | `<order_id>/<courier_id>-<unix_ts>.jpg` | `image/jpeg`, `upsert: true` | **private** — consumer signs for 3600 s | write `SupabaseService.swift:622-624`; read `ravon-consumer .../OrderDetailView.swift:786-788` |
| `restaurant-images` | `<uid>/<restaurant_id>.<ext>` | `image/<ext>`, `upsert: true` | **public** (`getPublicURL`) | :1402-1405 |
| `menu-item-images` | `<uid>/<menu_item_id>.<ext>` | `image/<ext>`, `upsert: true` | **public** (`getPublicURL`) | :1420-1423 |

Client-side gates: delivery proof ≤ 500 KB (`:620`); restaurant/menu images ≤ 5 MB and
extension ∈ `{jpg,jpeg,png,webp}` (`:1393-1394`, `:1437-1444`). All three are
**client-side only** — the comment at `:617` admits "server-side check is added in v2".
The Kotlin service must add them server-side.

Two path-safety notes for the extraction:
- `uploadDeliveryProof` returns the **path**, not a URL (`:627`), and that path is what
  gets stamped on `orders.delivery_proof_url`. The doc comment at `:475-477` incorrectly
  calls it a "Supabase Storage URL". The consumer read path
  (`OrderDetailView.swift:784`) correctly treats it as a path.
- `contentType: "image/\(fileExtension)"` (`:1404`, `:1422`) yields the non-standard
  `image/jpg` for `.jpg` uploads. Harmless today; will bite a strict CDN.

---

## 7. Auth surface (for the Kotlin/JWT side)

`AuthService.swift`:
- `client.auth.signUp(email:password:data: ["full_name", "role"])` (`:65-72`) — the role
  is **client-supplied** and lands in `auth.users.raw_user_meta_data`.
  **CROSS-CHECK:** `db/migrations/18_handle_new_user_trigger.sql:26` copies it
  verbatim into `public.profiles.role`, and `19_lock_down_profile_role.sql` blocks only
  subsequent *UPDATEs*. A client can therefore self-assign `role='merchant'` at signup.
  That is a live privilege-escalation path the extraction must close (role should be
  assigned server-side, not read from user metadata).
- OTP verify types used: `.signup` (`:106`) and `.recovery` (`:145`). No phone, no OAuth,
  no magic-link.
- `resetPasswordForEmail` (`:135`); `update(user: UserAttributes(password:))` (`:159`).
- `changePassword` re-authenticates by calling `signIn` with the current password
  (`:173`) — this **rotates the session** as a side effect.
- `accessToken` is exposed publicly (`:16`) but has **zero** consumers in any of the three
  apps or in RavonCore (grep). Nothing currently forwards a Supabase JWT to a custom
  backend, so the Kotlin service is free to define that contract from scratch.
- `AuthService.init` hard-`precondition`s on `RavonCore.isConfigured` (`:22`) — the client
  is constructed eagerly in the initialiser, so there is no lazy/offline mode.

---

## 8. Enums and CHECK domains the Kotlin layer must mirror

`order_status` — Postgres **ENUM** (CROSS-CHECK: `06_...sql:15` and `09_...sql:11` use
`ALTER TYPE order_status ADD VALUE`; the base `CREATE TYPE` is absent, i.e. created
out-of-band). 17 Swift cases at `Models/Order.swift:3-20`:
`scheduled, created, accepted, preparing, ready, assigned, courier_arrived_restaurant,
picked_up, delivering, courier_arrived_customer, delivered, cancelled, rejected,
cancelled_by_customer, cancelled_by_restaurant, cancelled_by_system, cancelled_by_courier`.

`user_role` — Postgres **ENUM** (`18_...sql:26` casts `::user_role`):
`consumer, courier, merchant` (`Models/UserRole.swift:3-6`).

`restaurant_status` — 4 values, `draft, active, paused, closed`
(`Models/Restaurant.swift:5-10`). Whether it is an enum type or text+CHECK is
**UNKNOWN — needs live introspection**; the Swift decoder tolerates either.

`delivery_mode` — **text + CHECK**, `hand_to_me | leave_at_door`
(`Models/DeliveryMode.swift:6-8`; CROSS-CHECK `10_...sql:22,31` on both `addresses` and
`orders`).

`orders.cancellation_reason_code` — **text + CHECK**, 18 values
(`Models/CancellationReason.swift:8-37`). CROSS-CHECK against
`09_...sql:20-35`: the Swift set and the SQL CHECK list match **exactly**, 18 for 18.

`courier_earnings.earning_type` — **text + CHECK**, 7 values
(`Models/CourierEarning.swift:4-11`; CROSS-CHECK `12_...sql:29-33`): `full,
partial_assigned, partial_at_restaurant, partial_picked_up_lost, no_show_compensation,
manual_adjustment, clawback`.

`chat_messages.sender_role` — **nullable text + CHECK**, `consumer|courier|merchant|system`
(`Models/ChatMessage.swift:7-12`).

`courier_delay_reason_code` (on `orders.courier_delay_reason_code`, sent as
`p_reason_code` to `courier_explain_delay`) — **lowercase**, unlike every other reason
code in the system: `traffic, restaurant_slow, address_unclear, customer_unreachable,
other` (`Models/CancellationReason.swift:81-86`). Whether a CHECK enforces this is
**UNKNOWN — needs live introspection**.

`CourierStatus` (`online|offline|delivering`, `Models/CourierStatus.swift`) is **derived
client-side** from `is_online` + `current_order_id` (`Models/CourierLocation.swift:21-24`).
It is **not** a column. Do not create one.

---

## 9. Defects found while reconstructing (call-site evidence, not speculation)

1. **`fetchActiveOrder` terminal-status list omits `cancelled_by_courier`.**
   `SupabaseService.swift:805-812` hardcodes six terminal statuses
   (`delivered, cancelled, cancelled_by_customer, cancelled_by_restaurant,
   cancelled_by_system, rejected`) but `OrderStatus.isTerminal`
   (`Models/Order.swift:46-55`) lists **seven**, including `cancelledByCourier`.
   Failure: a courier who self-cancels with a non-reassignable reason (e.g.
   `COURIER_VEHICLE_ISSUE`, which terminates the order per
   `OrderLifecycle.swift:155-158`) then relaunches the app → `fetchActiveOrder` returns
   the cancelled order as their active delivery, and the UI restores a dead job. The
   hardcoded list is exactly the drift `OrderLifecycle` was written to eliminate.

2. **`ServiceError.from(serverError:)` is unit-tested but never wired in.** Zero
   production call sites; only `Tests/RavonCoreTests/CourierCancellationTests.swift:55,65,74`.
   All 12 courier-hardening error cases (`ServiceError:26-38`) are unreachable in the
   shipped apps.

3. **`ROLE_CHANGE_FORBIDDEN` missing from the error switch** (`SupabaseService.swift:106-125`)
   despite migration 19 being written against it.

4. **`fetch_available_orders` and `fetchAvailableOrders()` return different shapes.**
   The table path (`:774-780`) projects `"*, restaurants(*), order_items(*)"`; the RPC path
   (`:794-798`) — CROSS-CHECK `13_...sql:719` `RETURNS SETOF orders` — returns bare order
   rows. `Order.restaurant` and `Order.orderItems` are both `decodeIfPresent`
   (`Models/Order.swift:280-281`), so the RPC path decodes fine but yields `nil` for both.
   Any courier UI that renders the restaurant name or item list from the geo-filtered feed
   shows blanks, while the unfiltered "testing / fallback" path (`:772`) works. The Kotlin
   endpoint must return one consistent shape.

5. **Unread-count reads whole rows to count them** (`:1096-1102`) — `select("id")` then
   `rows.count`. Should be a `count=exact` HEAD request.

6. **`unsubscribeAll()` leaks the restaurant-status channel** (`RealtimeService.swift:530-536`
   omits `unsubscribeFromRestaurantStatus`, which exists at `:287`).

7. **Currency symbol is still the rouble sign** at `Models/CartValidation.swift:79` and
   `Services/SupabaseService.swift:60` — for a Tajikistan product (somoni, TJS).

---

## 10. What remains unknowable from the repo

- RLS policies and grants on `orders`, `order_items`, `addresses`, `profiles`,
  `restaurants`, `menu_items`, `menu_categories`, `courier_locations`,
  `courier_earnings`, `order_status_history`, `restaurant_hours`, `modifier_groups`,
  `modifier_options`, `menu_item_modifier_groups`. The migration record contains policies
  for only `menu_items`, `menu_categories`, `chat_messages`, and
  `courier_cancellation_log` (grep for `CREATE POLICY` over all 19 files). In particular
  **there is no `orders` policy anywhere in the repo**, yet the five writes in §5.1 must
  be permitted by *some* policy for the merchant app to work at all.
  **UNKNOWN — needs live introspection.**
- Actual column SQL types (`numeric` vs `double precision` vs `real`), precision, and
  defaults. Swift `Double`/`Int` decoding is tolerant of several.
- Index definitions. §1.1 lists the ones the query shapes imply; none are provable.
- `UNIQUE(restaurants.owner_id)`, `PRIMARY KEY(menu_item_id, modifier_group_id)`,
  `REPLICA IDENTITY` settings, and the `supabase_realtime` publication membership.
- Base `CREATE TYPE order_status` value list and ordering.
- Whether `courier_cancellation_log` has any column beyond `courier_id` and `created_at`.

None of the above blocks writing the Kotlin service against §1 and §3; all of it blocks
*proving* the Kotlin service is equivalent.
