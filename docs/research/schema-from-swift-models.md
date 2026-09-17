# Postgres schema reconstructed from the RavonCore Swift Codable models

Scope: all 21 files in `Sources/RavonCore/Models/`, cross-referenced against
`.context/migrations/01–19` and `Sources/RavonCore/Services/`.

All paths are repo-relative to `/Users/mmarufov/conductor/workspaces/ravon-core/bucharest`.

## How to read the evidence column

Every column below carries an evidence tier. This matters because the migration record
is **structurally incomplete**: exactly one table is `CREATE`d in any migration
(`courier_cancellation_log`, `09_cancellation_reason_code_and_courier_cancel_log.sql:39`).
Everything else was created in the Supabase dashboard and is only observable through
what later migrations happen to touch.

| Tier | Meaning |
|---|---|
| **SQL** | A migration `ADD COLUMN`s it, or reads/writes it by name. |
| **SWIFT-ONLY** | The Swift model is the *only* artifact in the repo asserting it exists. |
| **SWIFT-ONLY + HARD** | Swift-only **and** decoded with non-optional `try c.decode` / synthesised decode. If the column is absent or NULL, the decode throws and the fetch fails. These are the dangerous ones. |

"Optional" is split two ways, because the distinction is recoverable from the code:

- **nullable** — the column genuinely admits NULL (proven by SQL, or by an
  `IS NULL` / `COALESCE` guard in a migration).
- **tolerance** — the column is `NOT NULL` in SQL but the Swift decoder still uses
  `decodeIfPresent ... ?? default`. This is backwards-compatibility for rows/deploys
  that predate the migration that added the column. The Swift Optional/default here
  encodes *schema history*, not nullability.

---

# 1. Tables

## 1.1 `addresses` — `Address` (Sources/RavonCore/Models/Address.swift:3)

Custom `init(from:)` at :39. `AddressInsert` (:64) is the separate write shape;
`AddressSnapshot` (:101) is a lossy read view of the JSONB snapshot (see §1.5).

| Swift | wire column | Swift type | Opt | kind | evidence |
|---|---|---|---|---|---|
| `id` | `id` | `UUID` | no | — | SQL — `04_...sql:202` (`addresses a WHERE a.id`) |
| `userId` | `user_id` | `UUID` | no | — | SQL — `15_...sql:54` pattern; `addresses` read at `13_...sql:45` |
| `label` | `label` | `String` | no | — | **SWIFT-ONLY + HARD** — the only `label` token in any migration is a prose comment at `03_orderability_function_and_view.sql:136` |
| `street` | `street` | `String` | no | — | **SWIFT-ONLY + HARD** — zero migration hits |
| `apartment` | `apartment` | `String?` | yes | nullable | **SWIFT-ONLY** — zero migration hits; `decodeIfPresent` at :45 |
| `city` | `city` | `String` | no | — | **SWIFT-ONLY + HARD** — zero migration hits |
| `latitude` | `latitude` | `Double?` | yes | nullable | SQL — `13_...sql:45` reads `latitude FROM addresses` |
| `longitude` | `longitude` | `Double?` | yes | nullable | SQL — `13_...sql:47` |
| `isDefault` | `is_default` | `Bool` | no | — | **SWIFT-ONLY + HARD** — zero migration hits; ordered on at `SupabaseService.swift:252` |
| `defaultDeliveryMode` | `default_delivery_mode` | `DeliveryMode` | no | tolerance | SQL — `10_...sql:17` `text NOT NULL DEFAULT 'hand_to_me'` + CHECK at :20 |
| `createdAt` | `created_at` | `Date` | no | — | SQL (generic) |

`defaultDeliveryMode` is the clean worked example of **tolerance**: SQL declares it
`NOT NULL DEFAULT 'hand_to_me'`, and Swift still writes
`decodeIfPresent(...) ?? .handToMe` (Address.swift:50) — that default exists only so a
binary built after migration 10 can still decode a row cached before it.

`AddressInsert` (:64) omits `id` and `created_at` (server-generated) and makes
`defaultDeliveryMode` `DeliveryMode?` (:73) so the DB default applies when nil.

## 1.2 `orders` — `Order` (Sources/RavonCore/Models/Order.swift:119)

44 CodingKeys (:320–365). Custom `init(from:)` at :265. This is the table where the
Swift model is most load-bearing.

| Swift | wire column | Swift type | Opt | kind | evidence |
|---|---|---|---|---|---|
| `id` | `id` | `UUID` | no | — | SQL |
| `userId` | `user_id` | `UUID` | no | — | SQL — `04_...sql:239`, `15_...sql:54` |
| `restaurantId` | `restaurant_id` | `UUID` | no | — | SQL — `04_...sql:239` |
| `addressId` | `address_id` | `UUID?` | yes | nullable | SQL — `10_...sql:60` (`IF NEW.address_id IS NOT NULL`) |
| `courierId` | `courier_id` | `UUID?` | yes | nullable | SQL — `13_...sql:539` sets it NULL |
| `status` | `status` | `OrderStatus` (pg enum) | no | — | SQL — `06_...sql:15`, `09_...sql:11` |
| `subtotal` | `subtotal` | `Double` | no | — | SQL — `04_...sql:240` |
| `deliveryFee` | `delivery_fee` | `Double` | no | — | SQL — `04_...sql:240` |
| `total` | `total` | `Double` | no | — | SQL — `04_...sql:240` |
| `deliveryAddressSnapshot` | `delivery_address_snapshot` | `AddressSnapshot?` (jsonb) | yes | nullable | SQL — `04_...sql:241,202`; `13_...sql:44` |
| `notes` | `notes` | `String?` | yes | nullable | SQL — `04_...sql:241` (`p_notes`) |
| `createdAt` | `created_at` | `Date` | no | — | SQL — `13_...sql:737` |
| `updatedAt` | `updated_at` | `Date` | no | — | SQL — `13_...sql:137` |
| `restaurant` | `restaurants` | `Restaurant?` | yes | **embed** | Not a column — PostgREST FK embed, `SupabaseService.swift:277` |
| `orderItems` | `order_items` | `[OrderItem]?` | yes | **embed** | Not a column — PostgREST FK embed, `SupabaseService.swift:277` |
| `estimatedDeliveryTime` | `estimated_delivery_time` | `Date?` | yes | nullable | **SWIFT-ONLY** — zero migration hits, zero write sites, zero readers in any of the 3 apps. Fully orphaned. |
| `estimatedPrepTime` | `estimated_prep_time` | `Int?` | yes | nullable | **SWIFT-ONLY** — zero migration hits; only written by `SupabaseService.acceptOrder` direct PostgREST UPDATE (`SupabaseService.swift:397`) |
| `cancellationReason` | `cancellation_reason` | `String?` | yes | nullable | SQL (legacy free-text, per `09_...sql:15`) |
| `cancellationReasonCode` | `cancellation_reason_code` | `String?` | yes | nullable | SQL — `09_...sql:17` `text` + CHECK :20–36 |
| `cancelledBy` | `cancelled_by` | `UUID?` | yes | nullable | SQL |
| `pickupVerificationCode` | **`verification_code`** | `String?` | yes | nullable | SQL — `10_...sql:59` trigger. **Name mismatch is deliberate** (Order.swift:340 comment) |
| `deliveryVerificationCode` | `delivery_verification_code` | `String?` | yes | nullable | SQL — `10_...sql:14` |
| `tipAmount` | `tip_amount` | `Double?` | yes | nullable | **SWIFT-ONLY** — the only `tip_amount` in any migration is `courier_earnings.tip_amount` (`12_...sql:88`). Implied by the `add_tip` RPC, which is itself absent from all migrations. |
| `pickedUpAt` | `picked_up_at` | `Date?` | yes | nullable | SQL — `13_...sql:291` |
| `deliveredAt` | `delivered_at` | `Date?` | yes | nullable | SQL — `13_...sql:420`, `15_...sql:57` |
| `acceptedAt` | `accepted_at` | `Date?` | yes | nullable | **SWIFT-ONLY** — zero migration hits; written only by `SupabaseService.swift:398` |
| `rejectedAt` | `rejected_at` | `Date?` | yes | nullable | **SWIFT-ONLY** — zero migration hits; written only by `SupabaseService.swift:428` |
| `scheduledFor` | `scheduled_for` | `Date?` | yes | nullable | SQL — `06_...sql:6` |
| `claimedAt` | `claimed_at` | `Date?` | yes | nullable | SQL — `08_...sql:41` |
| `arrivedAtRestaurantAt` | `arrived_at_restaurant_at` | `Date?` | yes | nullable | SQL — `08_...sql:42` |
| `arrivedAtCustomerAt` | `arrived_at_customer_at` | `Date?` | yes | nullable | SQL — `08_...sql:43` |
| `expectedActionBy` | `expected_action_by` | `Date?` | yes | nullable | SQL — `08_...sql:44` |
| `etaMinutes` | `eta_minutes` | `Int?` | yes | nullable | SQL — `08_...sql:49` `int` |
| `courierDelayReasonCode` | `courier_delay_reason_code` | `String?` | yes | nullable | SQL — `08_...sql:45` `text`, **no CHECK** |
| `courierDelayExplainedAt` | `courier_delay_explained_at` | `Date?` | yes | nullable | SQL — `08_...sql:46` |
| `courierNoShowWarnedAt` | `courier_no_show_warned_at` | `Date?` | yes | nullable | SQL — `08_...sql:47` |
| `courierNoShowEscalatedAt` | `courier_no_show_escalated_at` | `Date?` | yes | nullable | SQL — `08_...sql:48` |
| `reassignCount` | `reassign_count` | `Int` | no | tolerance | SQL — `11_...sql:5` `int NOT NULL DEFAULT 0` |
| `excludedCourierIds` | `excluded_courier_ids` | `[UUID]` | no | tolerance | SQL — `11_...sql:6` `uuid[] NOT NULL DEFAULT ARRAY[]::uuid[]` |
| `deliveryMode` | `delivery_mode` | `DeliveryMode` | no | tolerance | SQL — `10_...sql:25` `text NOT NULL DEFAULT 'hand_to_me'` + CHECK :29 |
| `deliveryProofUrl` | `delivery_proof_url` | `String?` | yes | nullable | SQL — `10_...sql:26` |
| `noShow` | `no_show` | `Bool` | no | tolerance | SQL — `16_...sql:7` `boolean NOT NULL DEFAULT false` |
| `noShowStartedAt` | `no_show_started_at` | `Date?` | yes | nullable | SQL — `16_...sql:8` |
| `restaurantDelayMin` | `restaurant_delay_min` | `Int` | no | tolerance | SQL — `16_...sql:9` `int NOT NULL DEFAULT 0` |

Deprecated alias `verificationCode` at :182–183 is a computed passthrough, not a column.

`Order` has **no Insert struct** — writes go through `create_order` (RPC) or direct
`.update()` dictionaries in `SupabaseService`.

## 1.3 `order_items` — `OrderItem` (Sources/RavonCore/Models/Order.swift:386)

Custom `init(from:)` at :418.

| Swift | wire column | Swift type | Opt | kind | evidence |
|---|---|---|---|---|---|
| `id` | `id` | `UUID` | no | — | SQL |
| `orderId` | `order_id` | `UUID` | no | — | SQL — `04_...sql:258` |
| `menuItemId` | `menu_item_id` | `UUID?` | yes | nullable | SQL — `02_...sql:9` `DROP NOT NULL` + `:15` `ON DELETE SET NULL`. Swift comment at :389–390 states this correctly. |
| `quantity` | `quantity` | `Int` | no | — | SQL — `04_...sql:258` |
| `unitPrice` | `unit_price` | `Double` | no | — | SQL — `04_...sql:258` |
| `totalPrice` | `total_price` | `Double` | no | — | SQL — `04_...sql:258` |
| `itemName` | `item_name` | `String` | no | — | SQL — `04_...sql:259` |
| `itemDescription` | `item_description` | `String?` | yes | nullable | SQL — `02_...sql:4` `text NULL` |
| `itemImageUrl` | `item_image_url` | `String?` | yes | nullable | SQL — `02_...sql:5` `text NULL` |
| `modifiersSnapshot` | `modifiers_snapshot` | `[OrderItemModifierSnapshot]` (jsonb) | no | tolerance | SQL — `02_...sql:6` `jsonb NOT NULL DEFAULT '[]'::jsonb` |

`OrderItemModifierSnapshot` (Order.swift:368) — JSONB element shape, **not** a table.
Keys `group_name`, `option_name`, `price_adjustment` are proven by the backfill
`jsonb_build_object` at `02_extend_order_items_snapshot.sql:29–31`. This is the one
place where the JSONB payload shape is SQL-proven.

## 1.4 `order_status_history` — `OrderStatusHistory` (Sources/RavonCore/Models/Order.swift:446)

**The entire table is SWIFT-ONLY.** `order_status_history` appears in zero migrations.
Read at `SupabaseService.swift:293`. No trigger or RPC in migrations 01–19 inserts into
it, so the audit trail it promises is unverifiable from the repo.

| Swift | wire column | Swift type | Opt | kind | evidence |
|---|---|---|---|---|---|
| `id` | `id` | `UUID` | no | — | SWIFT-ONLY + HARD |
| `orderId` | `order_id` | `UUID` | no | — | SWIFT-ONLY + HARD |
| `status` | `status` | `OrderStatus` | no | — | SWIFT-ONLY + HARD |
| `changedBy` | `changed_by` | `UUID?` | yes | nullable | SWIFT-ONLY |
| `notes` | `notes` | `String?` | yes | nullable | SWIFT-ONLY |
| `createdAt` | `created_at` | `Date` | no | — | SWIFT-ONLY + HARD |

Uses synthesised `init(from:)` (no custom decoder), so every non-optional field is a
hard decode.

## 1.5 `orders.delivery_address_snapshot` (jsonb) — `AddressSnapshot` (Address.swift:101)

All six fields `String?`/`Double?`, all with default-nil init. **Not a table.**

Critical correction to any "the snapshot has 6 keys" reading: the snapshot is produced by
`SELECT to_jsonb(a.*) FROM addresses a` at
`04_create_order_v3_and_validate_cart.sql:202` — i.e. it is the **entire `addresses`
row**, including `id`, `user_id`, `is_default`, `default_delivery_mode`, `created_at`.
`AddressSnapshot` decodes a 6-key subset and silently drops the rest (Codable ignores
unknown keys). So the JSONB column is strictly wider than the Swift type, and
`user_id` is being snapshotted into `orders` as a side effect.

## 1.6 `profiles` — `Profile` (Sources/RavonCore/Models/Profile.swift:3)

Custom `init(from:)` at :31.

| Swift | wire column | Swift type | Opt | kind | evidence |
|---|---|---|---|---|---|
| `id` | `id` | `UUID` | no | — | SQL — `18_...sql:22` |
| `fullName` | `full_name` | `String` | no | — | SQL — `18_...sql:22,25` (trigger writes `COALESCE(..., '')`, so never NULL post-18) |
| `phone` | `phone` | `String?` | yes | nullable | **SWIFT-ONLY** — zero migration hits |
| `role` | `role` | `UserRole` (pg enum) | no | — | SQL — `18_...sql:26` `::user_role`, `19_...sql:25` |
| `avatarUrl` | `avatar_url` | `String?` | yes | nullable | **SWIFT-ONLY** — zero migration hits |
| `isSuspendedUntil` | `is_suspended_until` | `Date?` | yes | nullable | SQL — `08_...sql:38` `timestamptz NULL` |
| `createdAt` | `created_at` | `Date` | no | — | SQL — `18_...sql:22` |
| `updatedAt` | `updated_at` | `Date` | no | — | SQL — `18_...sql:22` |

Note `role` is protected by a BEFORE UPDATE trigger (`19_lock_down_profile_role.sql:34`)
and `profiles` rows are created server-side by `handle_new_user`
(`18_...sql:15`, trigger at :36), so the client never inserts a profile. There is no
`ProfileInsert` struct — consistent.

## 1.7 `restaurants` — `Restaurant` (Sources/RavonCore/Models/Restaurant.swift:14)

Custom `init(from:)` at :66. `RestaurantInsert` at :117.

| Swift | wire column | Swift type | Opt | kind | evidence |
|---|---|---|---|---|---|
| `id` | `id` | `UUID` | no | — | SQL |
| `name` | `name` | `String` | no | — | SQL — `04_...sql:263` (`mi.name` is menu_items, but restaurants.name written at `SupabaseService.swift:1166`); weak SQL |
| `description` | `description` | `String?` | yes | nullable | SQL — `02_...sql:19` (menu_items); restaurants weak |
| `imageUrl` | `image_url` | `String?` | yes | nullable | SQL — `02_...sql:20` (menu_items); restaurants weak |
| `cuisineType` | `cuisine_type` | `String` | no | — | **SWIFT-ONLY + HARD** — zero migration hits |
| `rating` | `rating` | `Double` | no | — | **SWIFT-ONLY + HARD** — zero migration hits. Ordered on at `SupabaseService.swift:179`. |
| `deliveryTimeMin` | `delivery_time_min` | `Int` | no | — | SQL — but `06_scheduled_orders.sql:100` reads `COALESCE(r.delivery_time_min, 30)`, which **proves the column is NULLABLE** while Swift decodes it non-optional (`Restaurant.swift:74`). |
| `deliveryFee` | `delivery_fee` | `Double` | no | — | SQL — `04_...sql:245` |
| `minOrderAmount` | `min_order_amount` | `Double` | no | — | SQL — `04_...sql:100,112` |
| `address` | `address` | `String?` | yes | nullable | SQL — `SupabaseService.swift:1168`; weak |
| `latitude` | `latitude` | `Double?` | yes | nullable | SQL — `13_...sql:41,732` |
| `longitude` | `longitude` | `Double?` | yes | nullable | SQL — `13_...sql:41,732` |
| `openingTime` | `opening_time` | `String?` | yes | nullable | **SWIFT-ONLY** — every `opening_time` hit in migrations is `restaurant_hours` (via `restaurant_hours%ROWTYPE` at `03_...sql:20,41,45,46,49`), never `restaurants`. Legacy column superseded by `restaurant_hours`. |
| `closingTime` | `closing_time` | `String?` | yes | nullable | **SWIFT-ONLY** — same reasoning |
| `maxConcurrentOrders` | `max_concurrent_orders` | `Int?` | yes | nullable | SQL — `04_...sql:56` (`IS NOT NULL` guard proves nullable) |
| `isAcceptingOrders` | `is_accepting_orders` | `Bool` | no | tolerance | SQL — `03_...sql:66`, `05_...sql:32` |
| `acceptingOrdersUntil` | `accepting_orders_until` | `Date?` | yes | nullable | SQL — `05_...sql:4` `timestamptz NULL` |
| `ownerId` | `owner_id` | `UUID?` | yes | nullable | SQL — `01_...sql:43`, `05_...sql:22` |
| `restaurantStatus` | `restaurant_status` | `RestaurantStatus` | no | tolerance | SQL — `03_...sql:65,77`; `04_...sql:154,158,162` |

`RestaurantInsert` (:117) writes 9 columns; it omits `rating`, `owner_id`,
`restaurant_status`, `image_url`, `max_concurrent_orders`, `is_accepting_orders`,
`opening_time`, `closing_time` — so all of those must have DB defaults (or `owner_id`
is set by an unseen trigger/policy; `SupabaseService.swift:1117` inserts without it,
then filters by `owner_id = auth.uid()` at :1132, which only works if something
populates it). **UNKNOWN — needs live introspection: how `restaurants.owner_id` gets
set on insert.**

## 1.8 `menu_items` — `MenuItem` (Sources/RavonCore/Models/MenuItem.swift:3)

**Synthesised decoder** (no custom `init(from:)`) — every non-optional field is a hard decode.

| Swift | wire column | Swift type | Opt | kind | evidence |
|---|---|---|---|---|---|
| `id` | `id` | `UUID` | no | — | SQL — `04_...sql:212` |
| `categoryId` | `category_id` | `UUID` | no | — | **SWIFT-ONLY + HARD** — zero migration hits. `create_order` reads `mi.name/description/image_url/price/stock_count/deleted_at/is_available` but never `category_id`. |
| `restaurantId` | `restaurant_id` | `UUID` | no | — | SQL — `01_...sql` / `07_...sql` |
| `name` | `name` | `String` | no | — | SQL — `04_...sql:263` |
| `description` | `description` | `String?` | yes | nullable | SQL — `02_...sql:19` |
| `price` | `price` | `Double` | no | — | SQL — `04_...sql:262` |
| `imageUrl` | `image_url` | `String?` | yes | nullable | SQL — `02_...sql:20` |
| `isAvailable` | `is_available` | `Bool` | no | — | SQL — `04_...sql:213` |
| `sortOrder` | `sort_order` | `Int` | no | — | SQL (referenced broadly) |
| `stockCount` | `stock_count` | `Int?` | yes | nullable | SQL — `04_...sql:266` (`IS NOT NULL` guard proves nullable) |
| `deletedAt` | `deleted_at` | `Date?` | yes | nullable | SQL — `01_...sql:5` `timestamptz NULL` |

`MenuItemInsert` (:47) omits `id`, `stock_count`, `deleted_at`.

## 1.9 `menu_categories` — `MenuCategory` (Sources/RavonCore/Models/MenuCategory.swift:3)

Custom `init(from:)` at :22.

| Swift | wire column | Swift type | Opt | kind | evidence |
|---|---|---|---|---|---|
| `id` | `id` | `UUID` | no | — | SQL |
| `restaurantId` | `restaurant_id` | `UUID` | no | — | SQL — `01_...sql` |
| `name` | `name` | `String` | no | — | SQL (weak) |
| `sortOrder` | `sort_order` | `Int` | no | — | SQL (weak) |
| `isAvailable` | `is_available` | `Bool` | no | tolerance | SQL — `01_...sql:7` `boolean NOT NULL DEFAULT true` |
| `deletedAt` | `deleted_at` | `Date?` | yes | nullable | SQL — `01_...sql:6` `timestamptz NULL` |

`isAvailable` is the second clean **tolerance** example: SQL is `NOT NULL DEFAULT true`,
Swift is `decodeIfPresent ?? true` (:28), added by migration 01.

`MenuCategoryInsert` (:44) writes 3 columns.

## 1.10 `restaurant_hours` — `RestaurantHours` (Sources/RavonCore/Models/RestaurantHours.swift:6)

Synthesised decoder. `RestaurantHoursUpsert` at :106 (identical minus `id`;
upsert conflict target `restaurant_id,day_of_week` at `SupabaseService.swift:896`
implies a composite UNIQUE constraint — **SWIFT-ONLY evidence for that constraint**).

| Swift | wire column | Swift type | Opt | kind | evidence |
|---|---|---|---|---|---|
| `id` | `id` | `UUID` | no | — | SQL (`%ROWTYPE` read) |
| `restaurantId` | `restaurant_id` | `UUID` | no | — | SQL — `03_...sql:29` |
| `dayOfWeek` | `day_of_week` | `Int` | no | — | SQL — `03_...sql:30`; convention 0=Sun..6=Sat, proven at `03_...sql:23–24` and mirrored in Swift at :36–45 and :66 |
| `openingTime` | `opening_time` | `String` (pg `time`) | no | — | SQL — `03_...sql:41,45,46,49`. Postgres type is `time` (compared to `tjk_time time` at :25); PostgREST serialises to `"HH:MM:SS"`, which is why Swift uses `String`. Documented at :3–5. |
| `closingTime` | `closing_time` | `String` (pg `time`) | no | — | SQL — same |
| `isClosed` | `is_closed` | `Bool` | no | — | SQL — `03_...sql:37` |

`opening_time == closing_time` is an intentional "fully closed" marker
(`03_...sql:41–43`) — the Swift helper `nextOpenAt` at :55 does **not** implement that
rule (it only checks `isClosed`), so client and server disagree on that edge case.

## 1.11 `courier_locations` — `CourierLocation` (Sources/RavonCore/Models/CourierLocation.swift:3)

Custom `init(from:)` at :51. `CourierLocationUpsert` at :82 (conflict target
`courier_id` at `SupabaseService.swift:688` ⇒ `courier_id` is the PK/unique key;
`CourierLocation.id` is computed from it at :4).

| Swift | wire column | Swift type | Opt | kind | evidence |
|---|---|---|---|---|---|
| `courierId` | `courier_id` | `UUID` | no | — | SQL — `13_...sql:128` |
| `latitude` | `latitude` | `Double` | no | — | SQL — `13_...sql:116,128` |
| `longitude` | `longitude` | `Double` | no | — | SQL — `13_...sql:117,128` |
| `heading` | `heading` | `Double?` | yes | nullable | SQL — `13_...sql:118,128` |
| `speed` | `speed` | `Double?` | yes | nullable | SQL — `13_...sql:119,128` |
| `isOnline` | `is_online` | `Bool` | no | — | SQL — `08_...sql:53`, `13_...sql:124` |
| `currentOrderId` | `current_order_id` | `UUID?` | yes | nullable | SQL — `13_...sql:706` sets NULL |
| `lastUpdated` | `last_updated` | `Date` | no | — | SQL — **but `08_...sql:26` reads `COALESCE(last_updated, now())`, which proves the column is NULLABLE**, while Swift decodes it non-optional at :60. Decode-crash risk on legacy rows. |
| `lastHeartbeatAt` | `last_heartbeat_at` | `Date` | no | tolerance | SQL — `08_...sql:20` then `SET NOT NULL` at :32 |
| `lastMovedAt` | `last_moved_at` | `Date` | no | tolerance | SQL — `08_...sql:21` then `SET NOT NULL` at :34 |
| `accuracyMeters` | `accuracy_meters` | `Double?` | yes | nullable | SQL — `08_...sql:22` `double precision` |
| `ghostStrikes` | `ghost_strikes` | `Int` | no | tolerance | SQL — `08_...sql:23` `int NOT NULL DEFAULT 0` |
| `strikesResetAt` | `strikes_reset_at` | `Date` | no | tolerance | SQL — `08_...sql:24` `timestamptz NOT NULL DEFAULT now()` |

The three `?? self.lastUpdated` fallbacks (:61, :62, :65) are the clearest
backwards-compat artifacts in the codebase: all three columns are `NOT NULL` post-08,
so the fallbacks only exist for rows that predate migration 08.

**Column the Swift model does not know about:** `courier_locations.geog`
(PostGIS `extensions.geography`), proven by `13_...sql:54` (`cl.geog`) and
`13_...sql:113` (`ST_Distance(v_existing.geog, v_new_geog)` where `v_existing` is a
`courier_locations` row). Swift does `.select()` (all columns) at
`SupabaseService.swift:694` and :750, so `geog` arrives on the wire and is silently
dropped. The heartbeat UPDATE at `13_...sql:115–125` never assigns `geog`, so it is
either a GENERATED column or maintained by an unseen trigger — **UNKNOWN, needs live
introspection.**

## 1.12 `courier_earnings` — `CourierEarning` (Sources/RavonCore/Models/CourierEarning.swift:26)

Custom `init(from:)` at :62.

| Swift | wire column | Swift type | Opt | kind | evidence |
|---|---|---|---|---|---|
| `id` | `id` | `UUID` | no | — | SQL |
| `courierId` | `courier_id` | `UUID` | no | — | SQL — `12_...sql:88` |
| `orderId` | `order_id` | `UUID` | no | — | SQL — `12_...sql:88`. An `ON CONFLICT` upsert at `12_...sql:96–99` implies a unique key on (courier_id, order_id) or similar — **UNKNOWN exact target.** |
| `deliveryFee` | `delivery_fee` | `Double` | no | — | SQL — `12_...sql:88` |
| `tipAmount` | `tip_amount` | `Double` | no | — | SQL — `12_...sql:88,91` (inserted as literal `0`) |
| `totalEarned` | `total_earned` | `Double` | no | — | SQL — `12_...sql:88,97` |
| `earningType` | `earning_type` | `CourierEarningType` | no | tolerance | SQL — `12_...sql:18` `text NOT NULL DEFAULT 'full'` + CHECK :27 |
| `tierPct` | `tier_pct` | `Int` | no | tolerance | SQL — `12_...sql:19` `int NOT NULL DEFAULT 100` |
| `cancellationReasonCode` | `cancellation_reason_code` | `String?` | yes | nullable | SQL — `12_...sql:20` `text`. **No CHECK constraint** — unlike `orders.cancellation_reason_code`, the whitelist is NOT enforced here. |
| `statusAtEvent` | `status_at_event` | `OrderStatus?` | yes | nullable | SQL — `12_...sql:21` `order_status` (pg enum column) |
| `createdAt` | `created_at` | `Date` | no | — | SQL — `SupabaseService.swift:868` orders on it |

`isClawback` at :77 reads `tierPct < 0`, matching the `-100` clawback tier documented
at `12_...sql:6`. Note the CHECK at `12_...sql:27` constrains `earning_type` but
there is **no CHECK on `tier_pct`**, so the documented `0/25/50/100/-100` domain is
unenforced.

## 1.13 `courier_cancellation_log` — no Swift model

The only table `CREATE`d in a migration (`09_...sql:39–46`): `id`, `courier_id`,
`order_id`, `reason_code` (text, no CHECK), `status_at_cancel` (`order_status`),
`created_at`. Swift reads only `created_at` via an anonymous local `Row` struct at
`SupabaseService.swift:603–605`. **There is no `CourierCancellationLog` model** — a
gap, given it is the one table whose shape is fully proven.

## 1.14 `chat_messages` — `ChatMessage` (Sources/RavonCore/Models/ChatMessage.swift:14)

Custom `init(from:)` at :41. `ChatMessageInsert` at :63 (3 columns only).

| Swift | wire column | Swift type | Opt | kind | evidence |
|---|---|---|---|---|---|
| `id` | `id` | `UUID` | no | — | SQL |
| `orderId` | `order_id` | `UUID` | no | — | SQL — `13_...sql:597`, `15_...sql:53` |
| `senderId` | `sender_id` | `UUID` | no | — | SQL — `15_...sql:27,49` |
| `senderRole` | `sender_role` | `ChatRole?` | yes | **tolerance, not nullable in practice** | SQL — `15_...sql:12` `text` (nullable) + CHECK :15–16 *allows* NULL. **But** the BEFORE INSERT trigger `chat_messages_set_sender_role` (`15_...sql:34–37`, fn at :23–32) backfills it on every insert and falls back to `'system'`, so post-migration-15 rows are always non-NULL. The Swift Optional is tolerance for pre-15 rows. |
| `body` | `body` | `String` | no | — | SQL — `13_...sql:597` |
| `readAt` | `read_at` | `Date?` | yes | nullable | SQL — `SupabaseService.swift:1085` |
| `createdAt` | `created_at` | `Date` | no | — | SQL — `15_...sql` RLS window logic |

`ChatMessageInsert` deliberately omits `sender_role` — correct, because the trigger owns it.

## 1.15 `modifier_groups` / `modifier_options` / `menu_item_modifier_groups` — Modifier.swift

**All three tables appear in ZERO migrations.** Entirely SWIFT-ONLY. All three models
use synthesised decoders, so every non-optional field is a hard decode.

`ModifierGroup` (Modifier.swift:3) → `modifier_groups`:

| Swift | wire column | Swift type | Opt | evidence |
|---|---|---|---|---|
| `id` | `id` | `UUID` | no | SWIFT-ONLY + HARD |
| `restaurantId` | `restaurant_id` | `UUID` | no | SWIFT-ONLY + HARD |
| `name` | `name` | `String` | no | SWIFT-ONLY + HARD |
| `isRequired` | `is_required` | `Bool` | no | SWIFT-ONLY + HARD |
| `minSelections` | `min_selections` | `Int` | no | SWIFT-ONLY + HARD |
| `maxSelections` | `max_selections` | `Int` | no | SWIFT-ONLY + HARD |
| `sortOrder` | `sort_order` | `Int` | no | SWIFT-ONLY + HARD |
| `options` | `modifier_options` | `[ModifierOption]?` | yes | **PostgREST FK embed**, not a column — `SupabaseService.swift:918,928` |

`ModifierOption` (Modifier.swift:40) → `modifier_options`: `id`, `group_id` (UUID,
non-opt), `name`, `price_adjustment` (Double), `is_available` (Bool), `sort_order` (Int).
All SWIFT-ONLY + HARD. Note the FK column is `group_id`, **not** `modifier_group_id` —
that asymmetry with `MenuItemModifierGroup.modifier_group_id` is a Swift-only assertion
and a prime candidate for being wrong.

`MenuItemModifierGroup` (Modifier.swift:70) → `menu_item_modifier_groups` junction:
`menu_item_id`, `modifier_group_id`. Read at `SupabaseService.swift:910`, written at
:1377. Both SWIFT-ONLY + HARD.

`ModifierGroupInsert` (:87) and `ModifierOptionInsert` (:119) are the write shapes;
`ModifierOptionInsert` omits `is_available`, so that column must have a DB default.

## 1.16 `order_item_modifiers` — `OrderItemModifier` (Modifier.swift:145) — DEAD MODEL

The table *is* SQL-proven: `02_extend_order_items_snapshot.sql:33` reads
`FROM order_item_modifiers oim` using `oim.modifier_group_name`,
`oim.modifier_option_name`, `oim.price_adjustment`, `oim.order_item_id` (:29–34).
`modifier_option_id` is SWIFT-ONLY.

But the Swift struct has **zero call sites**: grep for `OrderItemModifier\b` across
`Sources/`, `Tests/`, and all three app repos returns only the declaration itself.
Migration 02 *migrated away* from this table into `order_items.modifiers_snapshot`
(jsonb). `order_item_modifiers` is also absent from the 15-table list of tables Swift
touches. **This model is dead code describing a deprecated table.**

---

# 2. RPC result shapes (NOT tables)

These Codable types have CodingKeys but map to function return values, not columns.
Reconstructing them as tables would be a mistake.

| Type | Source | RPC | Notes |
|---|---|---|---|
| `CartValidationResult` (CartValidation.swift:176) | `validate_cart` | proven at `04_...sql:106–114` | keys `orderable`, `reason`, `items`, `subtotal`, `min_order_amount`, `min_order_met` all SQL-proven |
| `CartItemValidation` (CartValidation.swift:149) | `validate_cart` items[] | `menu_item_id` SQL-proven | Flattened decode: reads `menu_item_id` from the *same* container it hands to `CartItemStatus` (:158–162) — the status keys are siblings, not nested |
| `CartItemStatus` (CartValidation.swift:92) | `validate_cart` | `status`, `have` proven; `old_price`/`new_price` **SWIFT-ONLY** — no migration emits `PRICE_CHANGED` | Externally-tagged-by-sibling-key enum |
| `OrderabilityReason` (CartValidation.swift:4) | `get_restaurant_orderability`, `validate_cart` | `kind`, `until`, `opens_at`, `need` — `03_...sql:128`, `04_...sql:49,102` | Same tagging pattern, tag key is `kind` |
| `MerchantStats` (MerchantStats.swift:3) | `get_merchant_stats` | **ALL 4 KEYS SWIFT-ONLY**: `today_order_count`, `today_revenue`, `average_order_value`, `active_order_count`. The RPC itself exists in no migration. | Synthesised decoder ⇒ all 4 are hard decodes |
| `NearbyCourier` (CourierLocation.swift:113) | `find_nearby_couriers` | `distance_km` **SWIFT-ONLY**; the RPC exists in no migration | |
| `OrderEta` (OrderEta.swift:9) | `.select(...)` on `orders` | All 8 keys SQL-proven via `08_...sql`. Note `orderId` maps to wire key **`id`** (:52) | Column-subset projection of `orders`, matching the explicit select list at `SupabaseService.swift:591` |

`fetch_available_orders` `RETURNS SETOF orders` (`13_...sql:720`) — a bare `orders` row
with **no** `restaurants(*)` / `order_items(*)` embed. So `Order.restaurant` and
`Order.orderItems` are always nil on that path (`SupabaseService.swift:794`), while
they are populated on the `.select("*, restaurants(*), order_items(*)")` paths
(:277, :285, :306, :775, :814). Same Swift type, two different wire shapes.

Non-Codable / pure-client types with no wire form: `EarningsSummary`
(CourierEarning.swift:94), `OnboardingProgress` (OnboardingProgress.swift:3),
`MenuCategoryTemplate` (MenuCategoryTemplate.swift:3), and everything in
`OrderLifecycle.swift` (`OrderActor`, `TransitionGuard`, `OrderObligation`,
`OrderTransition`, `OrderLifecycle`) — that whole file is a declarative graph, not a
schema artifact.

---

# 3. Swift enums vs. Postgres

The critical distinction the repo's own docs get wrong: **only two of these are real
Postgres `ENUM` types.** The rest are `text` columns with `CHECK` constraints, or have
no column at all.

## 3.1 Proven Postgres ENUM types (2)

### `order_status` — `OrderStatus` (Order.swift:3), 17 values

```
scheduled, created, accepted, preparing, ready, assigned,
courier_arrived_restaurant, picked_up, delivering, courier_arrived_customer,
delivered, cancelled, rejected, cancelled_by_customer,
cancelled_by_restaurant, cancelled_by_system, cancelled_by_courier
```

Proof it is an enum type: `ALTER TYPE order_status ADD VALUE 'scheduled' BEFORE 'created'`
(`06_...sql:15`), `ALTER TYPE order_status ADD VALUE 'cancelled_by_courier'`
(`09_...sql:11`), and used as a column type at `09_...sql:44` (`status_at_cancel
order_status`) and `12_...sql:21` (`status_at_event order_status`).

Only 2 of 17 values are SQL-proven (`scheduled`, `cancelled_by_courier`). There is **no
`CREATE TYPE order_status`** in any migration, so the base 15 values are asserted only
by Swift. `scripts/schema_drift.py` reports 9 of them as UNVERIFIED (it under-reports;
`assigned`, `created`, `preparing`, `cancelled`, `cancelled_by_customer`,
`courier_arrived_customer` are matched incidentally as substrings elsewhere in the SQL).

`OrderStatus.cancelled` (bare) has **no producer** — documented at
`OrderLifecycle.swift:186–194` and verified: it appears in migrations only inside
`status NOT IN (...)` terminal lists, never as an assignment.

### `user_role` — `UserRole` (UserRole.swift:3), 3 values

```
consumer, courier, merchant
```

Proof: `(NEW.raw_user_meta_data->>'role')::user_role` and `'consumer'::user_role` at
`18_...sql:26`; `role::text` cast at `15_...sql:27`. No `CREATE TYPE`, so only
`consumer` is value-proven; `courier` and `merchant` are Swift-only assertions.

## 3.2 `text` + `CHECK` constraint — NOT Postgres enums (4)

### `orders.delivery_mode` and `addresses.default_delivery_mode` — `DeliveryMode` (DeliveryMode.swift:6)

```
hand_to_me, leave_at_door
```

**Fully SQL-proven, and proven to be text-not-enum**: `10_...sql:25`
(`delivery_mode text NOT NULL DEFAULT 'hand_to_me'`) + CHECK at :29–32, and
`10_...sql:17` + CHECK at :20–23. Both values appear verbatim in the CHECK lists.

### `chat_messages.sender_role` — `ChatRole` (ChatMessage.swift:7)

```
consumer, courier, merchant, system
```

**Fully SQL-proven, text-not-enum**: `15_...sql:12` (`sender_role text`) +
`CHECK (sender_role IS NULL OR sender_role IN ('consumer','courier','merchant','system'))`
at :15–16. All 4 values verbatim.

### `courier_earnings.earning_type` — `CourierEarningType` (CourierEarning.swift:4)

```
full, partial_assigned, partial_at_restaurant, partial_picked_up_lost,
no_show_compensation, manual_adjustment, clawback
```

**Fully SQL-proven, text-not-enum**: `12_...sql:18` (`earning_type text NOT NULL
DEFAULT 'full'`) + CHECK at :27–32. All 7 values verbatim.

### `orders.cancellation_reason_code` — `CancellationReason` (CancellationReason.swift:8)

```
CONSUMER_CHANGED_MIND, CONSUMER_DUPLICATE, RESTAURANT_CLOSED,
RESTAURANT_OUT_OF_ITEMS, RESTAURANT_REJECTED, RESTAURANT_TOO_LONG_WAIT,
COURIER_VEHICLE_ISSUE, COURIER_SAFETY_ISSUE, COURIER_RESTAURANT_CLOSED,
COURIER_ITEMS_UNAVAILABLE, COURIER_NON_RESPONSIVE, SYSTEM_TIMEOUT,
SYSTEM_FRAUD_SUSPECTED, RESTAURANT_NOT_OPEN_AT_SCHEDULED_TIME,
ITEM_UNAVAILABLE, INSUFFICIENT_STOCK, ITEM_DELETED, CUSTOMER_NO_SHOW
```

**All 18 values verbatim SQL-proven** at `09_...sql:20–36`. The Swift doc comment at
:3–7 correctly identifies this as a CHECK mirror. This is the best-verified enum in the
codebase — and the Swift column type is `String?`, not the enum, in both `Order`
(:138) and `CourierEarning` (:35), so the typed enum is used only for *writes*.

Reassignable subset `('COURIER_RESTAURANT_CLOSED','COURIER_ITEMS_UNAVAILABLE',
'RESTAURANT_TOO_LONG_WAIT')` proven at `13_...sql:536`, matching
`CancellationReason.courierAllowed` (:47–53) minus `courierSafetyIssue`/
`courierVehicleIssue` — consistent with `OrderLifecycle`'s
`.reassignableReason` / `.nonReassignableReason` branch split.

## 3.3 Domain unknown — `restaurant_status` (RestaurantStatus, Restaurant.swift:5)

```
draft, active, paused, closed
```

Migrations only ever compare it to bare string literals (`03_...sql:65,77`;
`04_...sql:154,158,162`; `01_...sql:30`; `06_...sql:39`). There is **no `::restaurant_status`
cast, no `ALTER TYPE`, no CHECK constraint** anywhere. So whether this is a Postgres
enum, a text+CHECK column, or plain unconstrained text is **UNKNOWN — needs live
introspection.** `active`, `paused`, `closed` are value-proven by comparison;
`draft` is SWIFT-ONLY (only written, at `SupabaseService.swift:1150`).

## 3.4 No column at all — `courier_status` (CourierStatus.swift:3)

```
online, offline, delivering
```

**There is no `courier_status` column or type.** `CourierStatus` is produced purely
client-side by a computed property at `CourierLocation.swift:21–24`
(`!isOnline → .offline`, else `currentOrderId != nil ? .delivering : .online`).
Grep for `CourierStatus` across `Sources/`, `Tests/`, and all three app repos yields
exactly 3 hits: the declaration, that computed property, and the *method name*
`fetchCourierStatus()` (`SupabaseService.swift:745`, which returns
`CourierLocation`, not `CourierStatus`). Zero hits in any app.

## 3.5 Client-only enums with no Postgres counterpart

- `CourierDelayReason` (CancellationReason.swift:81) — `traffic`, `restaurant_slow`,
  `address_unclear`, `customer_unreachable`, `other`. Sent to
  `courier_explain_delay(p_reason_code text)`. All 4 non-`other` values appear as
  `CASE` branches at `13_...sql:638–641`, but `other` does **not**, and
  `orders.courier_delay_reason_code` is `text` with **no CHECK** (`08_...sql:45`) —
  so the domain is entirely unenforced server-side.
- `OrderActor`, `TransitionGuard`, `OrderObligation` (OrderLifecycle.swift:16, 35, 60)
  — pure client model.
- The `private enum Kind` helpers in CartValidation.swift (:20, :106) — JSON tag
  vocabularies for RPC responses, not columns.

---

# 4. Columns for which the Swift model is the ONLY evidence

Ranked by blast radius. Tier 1 = non-optional decode, so absence/NULL fails the whole
fetch.

## Tier 1 — SWIFT-ONLY and hard-decoded (fetch fails if wrong)

| Column | Model | Fetch that breaks |
|---|---|---|
| `restaurants.rating` | Restaurant.swift:73 | consumer restaurant feed (`SupabaseService.swift:176`) — also `.order("rating")` at :179 |
| `restaurants.cuisine_type` | Restaurant.swift:72 | same feed |
| `addresses.label` | Address.swift:43 | address list (`SupabaseService.swift:250`) |
| `addresses.street` | Address.swift:44 | same |
| `addresses.city` | Address.swift:46 | same |
| `addresses.is_default` | Address.swift:49 | same — also `.order("is_default")` at :252 |
| `menu_items.category_id` | MenuItem.swift:5 (synthesised) | every menu fetch |
| `modifier_groups.{is_required,min_selections,max_selections}` | Modifier.swift:7–9 | modifier fetch (:918, :928) |
| `modifier_options.group_id` | Modifier.swift:42 | same |
| `menu_item_modifier_groups.modifier_group_id` | Modifier.swift:72 | :910 |
| `order_status_history.{id,order_id,status,created_at}` | Order.swift:447–452 | order history (:293) |
| all of `modifier_groups`, `modifier_options`, `menu_item_modifier_groups` | Modifier.swift | three tables, zero SQL evidence |
| all of `order_status_history` | Order.swift:446 | one table, zero SQL evidence |
| `get_merchant_stats` → all 4 keys | MerchantStats.swift | merchant dashboard (:1449) |

## Tier 2 — SWIFT-ONLY but optional (degrades silently)

| Column | Model | Note |
|---|---|---|
| `orders.estimated_delivery_time` | Order.swift:135 | **fully orphaned** — no SQL, no write site, no reader in any app |
| `orders.estimated_prep_time` | Order.swift:136 | written only by direct PostgREST UPDATE at :397 |
| `orders.accepted_at` | Order.swift:152 | written only at :398 |
| `orders.rejected_at` | Order.swift:153 | written only at :428 |
| `orders.tip_amount` | Order.swift:149 | implied by `add_tip`, which is itself in no migration |
| `restaurants.opening_time` / `closing_time` | Restaurant.swift:27–28 | legacy; superseded by `restaurant_hours` |
| `profiles.phone` | Profile.swift:6 | |
| `profiles.avatar_url` | Profile.swift:8 | |
| `find_nearby_couriers` → `distance_km` | CourierLocation.swift:120 | RPC also absent from migrations |
| `validate_cart` → `old_price` / `new_price` | CartValidation.swift:102–103 | no SQL path emits `PRICE_CHANGED` |
| `order_item_modifiers.modifier_option_id` | Modifier.swift:147 | dead model anyway |

## Tier 3 — structural constraints asserted only by Swift

- `restaurant_hours` composite UNIQUE on `(restaurant_id, day_of_week)` — inferred
  solely from `onConflict: "restaurant_id,day_of_week"` at `SupabaseService.swift:896`.
- `courier_locations` unique/PK on `courier_id` — inferred from
  `onConflict: "courier_id"` at :688 and :731, plus `CourierLocation.id` being computed
  from `courierId` (CourierLocation.swift:4).
- `courier_earnings` unique key backing the `ON CONFLICT` upsert at `12_...sql:96` —
  the conflict target is not written out in the migration. **UNKNOWN.**
- `restaurants.owner_id` population on insert — `RestaurantInsert` omits it but
  `fetchMyRestaurant` filters on it (:1132). **UNKNOWN.**

---

# 5. Corrections to claims in the surrounding docs

1. **`.context/architecture/12-BACKEND-INVENTORY.md` claims "6 Postgres enums are
   dashboard-created (`order_status`, `user_role`, `courier_status`, `delivery_mode`,
   `sender_role`, `restaurant_status`)". Four of the six are wrong.**
   - `delivery_mode` is a **`text` column with a CHECK constraint**, not an enum —
     `10_dual_verification_codes_and_delivery_mode.sql:25` and :29–32.
   - `sender_role` is a **`text` column with a CHECK constraint**, not an enum —
     `15_chat_rls_and_sender_role.sql:12` and :15–16.
   - `courier_status` **does not exist as a column or a type**. `CourierStatus` is a
     client-side computed property (`CourierLocation.swift:21–24`) with zero wire
     mapping and zero references in any of the three apps.
   - `restaurant_status`'s kind is **UNKNOWN** — no cast, no `ALTER TYPE`, no CHECK.
   Only `order_status` and `user_role` are proven Postgres enum types.
   A fifth enum the doc omits: `courier_earnings.earning_type`, also text+CHECK
   (`12_...sql:18,27`).

2. **"AddressSnapshot describes the snapshot column" is wrong in the lossy direction.**
   `orders.delivery_address_snapshot` is `to_jsonb(a.*)` over the whole `addresses` row
   (`04_...sql:202`), so it carries `id`, `user_id`, `is_default`,
   `default_delivery_mode` and `created_at` in addition to the 6 keys
   `AddressSnapshot` declares. Any rebuild that types the column as the 6-field shape
   loses data that is already being written.

3. **`OrderLifecycle.swift:79–80` asserts "`orders` carries no client UPDATE policy" and
   "there is no other legal way to move an order" than a SECURITY DEFINER RPC. The
   service layer contradicts this.** Five `SupabaseService` functions move `orders.status`
   by direct PostgREST `.update()`: `acceptOrder` (:395), `startPreparing` (:410),
   `rejectOrder` (:424), `markOrderReady` (:440), `assignCourier` (:643). Those calls
   only work if a client UPDATE policy on `orders` *does* exist. Either the comment is
   wrong or all five merchant operations are silently failing. **UNKNOWN — needs live
   policy introspection**, but the two claims cannot both be true.

4. **`scripts/schema_drift.py` cannot report a missing single-word column.** Line 103:
   `absent = sorted({wire for _, wire in keys if wire not in identifiers and "_" in wire})`.
   The `"_" in wire` filter is required because `sql_identifiers` (:91 in the same file)
   only matches identifiers containing an underscore — so `street`, `city`, `apartment`,
   `label`, `phone`, `rating` are structurally invisible to the tool. Four of those are
   Tier-1 hard-decoded Swift-only columns. The tool's "15 unverified" is therefore a
   **floor**, not a count; the true set is 15 + at least 6.

5. **Two columns are nullable in SQL but non-optional in Swift** — a latent decode crash
   independent of any missing column:
   - `courier_locations.last_updated`: `08_courier_heartbeat_and_sla_columns.sql:26`
     reads `COALESCE(last_updated, now())`, proving NULL is possible;
     `CourierLocation.swift:60` does `try c.decode(Date.self, forKey: .lastUpdated)`.
   - `restaurants.delivery_time_min`: `06_scheduled_orders.sql:100` reads
     `COALESCE(r.delivery_time_min, 30)`, proving NULL is possible;
     `Restaurant.swift:74` does `try c.decode(Int.self, forKey: .deliveryTimeMin)`.

6. **`OrderItemModifier` (Modifier.swift:145) is dead code for a deprecated table.**
   Migration 02 migrated `order_item_modifiers` into `order_items.modifiers_snapshot`
   (`02_...sql:25–35`). The struct has zero call sites in `Sources/`, `Tests/`, or any
   of the three app repos, and `order_item_modifiers` is not among the 15 tables Swift
   touches. Do not carry it into a rebuild.

7. **`courier_cancellation_log` is the one fully-proven table and has no Swift model.**
   `09_...sql:39–46` gives its complete DDL. Swift reads it through an anonymous local
   `Row { created_at }` struct at `SupabaseService.swift:603–605`.

8. **Unenforced domains** (Swift types are stricter than the DB):
   - `orders.courier_delay_reason_code` — `text`, **no CHECK** (`08_...sql:45`), while
     `CourierDelayReason` declares 5 values.
   - `courier_earnings.cancellation_reason_code` — `text`, **no CHECK**
     (`12_...sql:20`), unlike its `orders` counterpart which has an 18-value CHECK.
   - `courier_earnings.tier_pct` — `int`, **no CHECK** (`12_...sql:19`), while the
     migration's own header comment (:5) documents the domain as `0/25/50/100/-100`.
   - `courier_cancellation_log.reason_code` — `text`, **no CHECK** (`09_...sql:43`).

9. **`restaurant_hours` "fully closed" marker is not implemented client-side.**
   `03_...sql:41–43` treats `opening_time = closing_time` as intentionally closed. The
   Swift `nextOpenAt` helper (`RestaurantHours.swift:55–93`) only checks `row.isClosed`
   and will report such a day as open. The doc comment at :4–5 correctly says the
   helpers are "UI rendering only", so this is contained — but it is a real divergence.

---

# 6. Table inventory summary

| Table | Swift model | SQL evidence | Insert/Upsert struct |
|---|---|---|---|
| `addresses` | `Address` | partial (10, 13) | `AddressInsert` |
| `orders` | `Order` | strong (02,04,06,08–17) | none (RPC + raw `.update()`) |
| `order_items` | `OrderItem` | strong (02, 04) | none (created by `create_order`) |
| `order_status_history` | `OrderStatusHistory` | **NONE** | none |
| `profiles` | `Profile` | partial (08, 18, 19) | none (server trigger) |
| `restaurants` | `Restaurant` | partial (03–06, 13) | `RestaurantInsert` |
| `menu_items` | `MenuItem` | partial (01, 02, 04, 07) | `MenuItemInsert` |
| `menu_categories` | `MenuCategory` | partial (01, 07) | `MenuCategoryInsert` |
| `restaurant_hours` | `RestaurantHours` | partial (03) | `RestaurantHoursUpsert` |
| `courier_locations` | `CourierLocation` | partial (08, 13, 14, 16, 17) | `CourierLocationUpsert` |
| `courier_earnings` | `CourierEarning` | partial (12) | none |
| `chat_messages` | `ChatMessage` | partial (13–17) | `ChatMessageInsert` |
| `modifier_groups` | `ModifierGroup` | **NONE** | `ModifierGroupInsert` |
| `modifier_options` | `ModifierOption` | **NONE** | `ModifierOptionInsert` |
| `menu_item_modifier_groups` | `MenuItemModifierGroup` | **NONE** | (reuses the model) |
| `courier_cancellation_log` | **none** | **complete DDL (09)** | none |
| `order_item_modifiers` | `OrderItemModifier` (dead) | partial (02, deprecating) | none |

15 tables touched by Swift + `courier_cancellation_log` (read via an anonymous struct)
+ `order_item_modifiers` (dead model, not touched) = 17 tables named in the repo.
