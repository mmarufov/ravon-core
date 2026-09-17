# Postgres schema reconstructed from `db/migrations/01..19`

Source of truth for this document: the 19 `.sql` files plus `README.md` in
`/Users/mmarufov/conductor/workspaces/ravon-core/bucharest/db/migrations/`.
Every claim below cites `file:line`. Citations use the short form `NN:L`
(e.g. `08:41` = `08_courier_heartbeat_and_sla_columns.sql` line 41).

**Method.** Only one table is `CREATE TABLE`'d in the whole set
(`courier_cancellation_log`, `09:39`). Everything else is reconstructed from
what the migrations `ALTER`, `INSERT`, `UPDATE`, `SELECT`, cast, compare, index,
or bind into a `%ROWTYPE` variable. Confidence is graded per table:

| grade | meaning |
|---|---|
| **proven** | `CREATE TABLE` exists in 01..19 |
| **inferred** | `ALTER TABLE ADD COLUMN` exists, or the reference is unambiguous (typed local variable, cast, FK, index) |
| **guessed** | the column is implied by convention or by a comment only |

Per-column grades are given in the `evidence` column of each table. A column is
marked `NOT NULL (proven)` only when an `ADD COLUMN ... NOT NULL` /
`ALTER COLUMN ... SET NOT NULL` exists; `nullable (proven)` only when a
`DROP NOT NULL`, an `IS NULL` / `IS NOT NULL` test, or a `COALESCE` on that
column exists.

## 0. Global counts

| thing | count | note |
|---|---|---|
| `CREATE TABLE` | 1 | `courier_cancellation_log` (`09:39`) |
| `CREATE TYPE` | **0** | both enums (`order_status`, `user_role`) pre-exist; only `ALTER TYPE ADD VALUE` appears |
| `ALTER TYPE ADD VALUE` | 2 | `06:15`, `09:11` |
| `CREATE OR REPLACE VIEW` | 1 | `restaurants_orderable` (`03:73`) |
| `CREATE INDEX` | 6 | all `IF NOT EXISTS` |
| `CREATE TRIGGER` | 4 | `10:71`, `15:35`, `18:36`, `19:35` |
| `CREATE POLICY` | 8 | 4 in `01`, 1 in `09`, 3 in `15` |
| `DROP POLICY` | 8 | 5 re-created under the same name, 3 retired |
| `ENABLE ROW LEVEL SECURITY` | **1** | only `courier_cancellation_log` (`09:51`) |
| `GRANT` | 36 statements | 1 `GRANT SELECT`, 35 `GRANT EXECUTE` |
| `REVOKE` | **0** | no statement anywhere in 01..19 |
| `cron.schedule` | 5 | see §5 |
| tables touched | 13 in `public` + `auth.users` + `cron.job` | see §1 |
| functions created/replaced | 31 `CREATE OR REPLACE FUNCTION` statements over 26 distinct functions | 5 replaced twice (`14`→`17`, `16`→`17`, `13`→`17`) |

---

## 1. Tables

### 1.1 `courier_cancellation_log` — **proven**

The only `CREATE TABLE` in the set (`09:39-46`). Full definition is literal, not inferred.

| column | type | nullability | evidence |
|---|---|---|---|
| `id` | `uuid` | NOT NULL, PK, `DEFAULT gen_random_uuid()` | `09:40` |
| `courier_id` | `uuid` | NOT NULL, FK → `profiles(id) ON DELETE CASCADE` | `09:41` |
| `order_id` | `uuid` | NOT NULL, FK → `orders(id) ON DELETE CASCADE` | `09:42` |
| `reason_code` | `text` | NOT NULL | `09:43` |
| `status_at_cancel` | `order_status` | NOT NULL | `09:44` |
| `created_at` | `timestamptz` | NOT NULL, `DEFAULT now()` | `09:45` |

RLS: enabled `09:51`. One policy (SELECT self, `09:54-56`). Writes happen only via
`cancel_order_by_courier` (`13:532`), a `SECURITY DEFINER` function, so there is
deliberately no INSERT policy (`09:58`).

---

### 1.2 `orders` — **inferred** (largest surface; 21 columns added by migrations, 20 more referenced)

#### Columns added by 01..19 (all `ADD COLUMN`, so **inferred** at minimum)

| column | type | nullability | evidence |
|---|---|---|---|
| `scheduled_for` | `timestamptz` | NULL (explicit) | `06:6` |
| `claimed_at` | `timestamptz` | nullable (no NOT NULL) | `08:41` |
| `arrived_at_restaurant_at` | `timestamptz` | nullable | `08:42` |
| `arrived_at_customer_at` | `timestamptz` | nullable | `08:43` |
| `expected_action_by` | `timestamptz` | nullable (proven: `IS NOT NULL` `14:36`, set `NULL` `13:422`) | `08:44` |
| `courier_delay_reason_code` | `text` | nullable (proven: set `NULL` `13:240`) | `08:45` |
| `courier_delay_explained_at` | `timestamptz` | nullable (proven: `IS NULL` `14:39`) | `08:46` |
| `courier_no_show_warned_at` | `timestamptz` | nullable (proven: `IS NULL` `14:38`) | `08:47` |
| `courier_no_show_escalated_at` | `timestamptz` | nullable (proven: `IS NULL` `14:51`) | `08:48` |
| `eta_minutes` | `int` | nullable (proven: set `NULL` `13:211`) | `08:49` |
| `cancellation_reason_code` | `text` | nullable (proven: `IS NULL` in CHECK `09:21`) | `09:17`; CHECK `09:20-36` |
| `delivery_verification_code` | `text` | nullable (proven: `IS NULL` `10:40`, `10:50`) | `10:14` |
| `delivery_mode` | `text` | **NOT NULL (proven)**, `DEFAULT 'hand_to_me'` | `10:25`; CHECK `10:29-31` |
| `delivery_proof_url` | `text` | nullable (proven: `IS NULL` `13:412`) | `10:26` |
| `reassign_count` | `int` | **NOT NULL (proven)**, `DEFAULT 0` | `11:5` |
| `excluded_courier_ids` | `uuid[]` | **NOT NULL (proven)**, `DEFAULT ARRAY[]::uuid[]` | `11:6` |
| `no_show` | `boolean` | **NOT NULL (proven)**, `DEFAULT false` | `16:7` |
| `no_show_started_at` | `timestamptz` | nullable (proven: `IS NOT NULL` `16:61`) | `16:8` |
| `restaurant_delay_min` | `int` | **NOT NULL (proven)**, `DEFAULT 0` | `16:9` |

#### Columns referenced but never created by 01..19 (pre-existing; type from cast/variable binding)

| column | type | type evidence | nullability | nullability evidence |
|---|---|---|---|---|
| `id` | `uuid` | FK target `09:42`; `%ROWTYPE` PK usage `06:33` | NOT NULL (PK assumed) | guessed |
| `user_id` | `uuid` | inserted `auth.uid()` `04:239,244`; `o.user_id = auth.uid()` `15:54` | NOT NULL | guessed |
| `restaurant_id` | `uuid` | inserted `p_restaurant_id uuid` `04:239,245`; `JOIN restaurants r ON r.id = o.restaurant_id` `06:98` | NOT NULL | guessed |
| `address_id` | `uuid` | inserted `p_address_id uuid` `04:239,245`; `WHERE id = NEW.address_id` on `addresses` `10:61` | **nullable (proven)** | `NEW.address_id IS NOT NULL` `10:60` |
| `status` | **`order_status`** (proven) | `SELECT status ... INTO v_status` where `v_status order_status` `13:160,190-191`; `14:26,66,73` | NOT NULL | inferred (no NULL branch anywhere) |
| `subtotal` | `numeric` | inserted `subtotal numeric` `04:144,239,245` | NOT NULL | guessed |
| `delivery_fee` | **`numeric`** (proven) | `SELECT delivery_fee INTO v_delivery_fee` where `v_delivery_fee numeric` `12:74,79` | **nullable (proven)** | `IF v_delivery_fee IS NULL THEN RETURN` `12:80` |
| `total` | `numeric` | inserted `v_total numeric` `04:145,240,246` | NOT NULL | guessed |
| `delivery_address_snapshot` | **`jsonb`** (proven) | inserted `to_jsonb(a.*)` `04:202,241`; `->>` operator `13:44,46` | nullable | inferred (`COALESCE` around the `->>` at `13:44`) |
| `notes` | `text` | inserted `p_notes text` `04:131,241,246` | nullable | inferred (`p_notes DEFAULT NULL` `04:131`) |
| `created_at` | `timestamptz` | `ORDER BY o.created_at` `13:736` | NOT NULL | guessed |
| `updated_at` | `timestamptz` | `updated_at = now()` `06:43`; `COALESCE(o.delivered_at, o.updated_at) > now() - interval '30 days'` `15:74` | nullable | inferred (2nd arg of COALESCE) |
| `cancellation_reason` | `text` | `= 'RESTAURANT_NOT_OPEN_AT_SCHEDULED_TIME'` `06:42`; `= p_reason` (`text`) `13:472` | nullable | inferred (`p_reason DEFAULT NULL` `13:431`) |
| `cancelled_by` | `uuid` | `cancelled_by = v_uid` where `v_uid uuid := auth.uid()` `13:438,471` | nullable | guessed |
| `courier_id` | `uuid` | `SELECT ... courier_id INTO v_courier` (`v_courier uuid`) `13:441,443`; set `NULL` `13:539` | **nullable (proven)** | `o.courier_id IS NULL` `13:36`, `13:728` |
| `verification_code` | **`text`** (proven) | `NEW.verification_code := lpad(...)::text` `10:38`; `INTO v_code` where `v_code text` `13:267,270` | **nullable (proven)** | `NEW.verification_code IS NULL` `10:37` |
| `picked_up_at` | `timestamptz` | `picked_up_at = now()` `13:291` | nullable | guessed |
| `delivered_at` | `timestamptz` | `delivered_at = now()` `13:420`; `o.delivered_at > now() - interval '5 minutes'` `15:57` | **nullable (proven)** | `COALESCE(o.delivered_at, o.updated_at)` `15:74` |

#### `orders` CHECK constraints

| constraint | definition | evidence |
|---|---|---|
| `cancellation_reason_code_valid` | `cancellation_reason_code IS NULL OR IN (17 literals)` — see §4.3 | `09:19-36` (dropped-then-added, so idempotent) |
| `orders_delivery_mode_valid` | `delivery_mode IN ('hand_to_me','leave_at_door')` | `10:28-31` |

#### `orders` internal inconsistency (real, worth flagging)

`11:5-6` and `16:9` declare `reassign_count`, `excluded_courier_ids`,
`restaurant_delay_min` as `NOT NULL DEFAULT ...`, yet migration 13/16 defensively
`COALESCE` all three: `COALESCE(reassign_count,0)` `13:544`,
`COALESCE(o.reassign_count, 0)` `13:675`,
`COALESCE(v_excluded, ARRAY[]::uuid[])` `13:543`,
`COALESCE(excluded_courier_ids, ARRAY[]::uuid[])` `13:700`,
`COALESCE(o.excluded_courier_ids, ARRAY[]::uuid[])` `13:730`,
`COALESCE(v_total, 0)` `16:108`. Harmless, but it means the author was not
confident the `NOT NULL` had actually been applied — a signal that the live DB
state may diverge from what 01..19 declare. **UNKNOWN — needs live introspection.**

---

### 1.3 `order_items` — **inferred**

| column | type | nullability | evidence |
|---|---|---|---|
| `id` | `uuid` (guessed) | NOT NULL (guessed) | `oim.order_item_id = oi.id` `02:34`; `SELECT id AS oi_id` `06:50` |
| `order_id` | `uuid` | NOT NULL (guessed) | inserted `new_order_id uuid` `04:142,258,262`; `WHERE order_id = o.id` `06:52` |
| `menu_item_id` | `uuid` | **nullable (proven)** — `ALTER COLUMN menu_item_id DROP NOT NULL` | `02:9`; `IF rec.menu_item_id IS NULL` `06:54` |
| `quantity` | `int` | NOT NULL (guessed) | inserted `(it->>'quantity')::int` `04:209,258` |
| `unit_price` | `numeric` | NOT NULL (guessed) | inserted `mi.price` `04:258,262` |
| `total_price` | `numeric` | NOT NULL (guessed) | inserted `mi.price * rec.quantity` `04:258,262` |
| `item_name` | `text` | NOT NULL (guessed) | inserted `mi.name` `04:259,263` |
| `item_description` | `text` | NULL (explicit) | `02:4`; backfilled from `menu_items.description` `02:19` |
| `item_image_url` | `text` | NULL (explicit) | `02:5`; backfilled from `menu_items.image_url` `02:20` |
| `modifiers_snapshot` | `jsonb` | **NOT NULL (proven)**, `DEFAULT '[]'::jsonb` | `02:6`; `jsonb_array_length(oi.modifiers_snapshot)` `02:36` |

FK: `order_items_menu_item_id_fkey` rebuilt as
`FOREIGN KEY (menu_item_id) REFERENCES menu_items(id) ON DELETE SET NULL` (`02:12-15`).
The pre-existing constraint name is confirmed by the `DROP CONSTRAINT IF EXISTS` at `02:12`.

---

### 1.4 `order_item_modifiers` — **inferred** (migration-only table; never touched from Swift)

Referenced exactly once, in the migration-02 backfill (`02:26-36`).

| column | type | nullability | evidence |
|---|---|---|---|
| `order_item_id` | `uuid` | NOT NULL (guessed) | `WHERE oim.order_item_id = oi.id` `02:34` |
| `modifier_group_name` | `text` (guessed) | unknown | `02:29` |
| `modifier_option_name` | `text` (guessed) | unknown | `02:30` |
| `price_adjustment` | `numeric` (guessed) | unknown | `02:31` |

**Note:** this table is not in the 15-table Swift surface the orchestrator
verified. It exists only as a legacy source for the one-time `modifiers_snapshot`
backfill; after migration 02 nothing reads it. Candidate for deletion.

---

### 1.5 `restaurants` — **inferred**

| column | type | nullability | evidence |
|---|---|---|---|
| `id` | `uuid` | NOT NULL, PK (guessed) | `WHERE id = p_restaurant_id` with `p_restaurant_id uuid` `03:84,98`; `r.id = menu_items.restaurant_id` `01:29` |
| `restaurant_status` | `text` **or** enum — **UNKNOWN**, no cast anywhere | inferred NOT NULL | `= 'active'` `01:30`, `03:65`, `03:77`; `= 'closed'` `03:107`; `= 'paused'` `03:115`; `<> 'active'` `04:162`; `<> 'active'` `06:39`. Reachable values: `active`, `closed`, `paused` |
| `owner_id` | `uuid` (proven by comparison to `auth.uid()`) | inferred NOT NULL | `r.owner_id = auth.uid()` `01:43`, `01:64`, `05:22`, `15:54`, `15:70` |
| `is_accepting_orders` | `boolean` | inferred NOT NULL | `= true` `03:66`; `= false` `03:123`, `04:47`, `05:53`; `SET ... = true/false` `05:32,36` |
| `accepting_orders_until` | `timestamptz` | NULL (explicit) | **`05:4` (ADD COLUMN)**; `IS NOT NULL` `05:53` |
| `max_concurrent_orders` | `int` (inferred: compared to `active_count int`) | **nullable (proven)** | `IS NOT NULL` `04:56`, `04:187`; `active_count >= r.max_concurrent_orders` `04:64` with `active_count int` `04:23` |
| `min_order_amount` | `numeric` (inferred: compared to `subtotal numeric`) | unknown | `subtotal < r.min_order_amount` `04:100`, `04:230` |
| `delivery_fee` | `numeric` | inferred NOT NULL | `v_total := subtotal + r.delivery_fee` `04:236` with `v_total numeric` `04:145` |
| `delivery_time_min` | `int` (inferred: `\|\| ' minutes'` interval cast) | **nullable (proven)** | `COALESCE(r.delivery_time_min, 30)` `06:100` |
| `latitude` | `double precision` (proven) | nullable (proven) | `SELECT latitude ... INTO v_target_lat` with `v_target_lat double precision` `13:30,41`; `IF v_target_lat IS NULL` `13:50` |
| `longitude` | `double precision` (proven) | nullable (proven) | `13:31,41`, `13:50`; `ST_MakePoint(r.longitude, r.latitude)` `13:732` |

`restaurants` also has an unknown tail of columns exposed wholesale by the
`restaurants_orderable` view (`SELECT r.*`, `03:74`) — **UNKNOWN — needs live introspection.**

---

### 1.6 `restaurant_hours` — **inferred**

Bound as `restaurant_hours%ROWTYPE` at `03:20` and `03:96`.

| column | type | nullability | evidence |
|---|---|---|---|
| `restaurant_id` | `uuid` | NOT NULL (guessed) | `WHERE restaurant_id = p_restaurant` with `p_restaurant uuid` `03:7,29` |
| `day_of_week` | `int` (proven by comparison) | NOT NULL (guessed) | `AND day_of_week = tjk_dow` with `tjk_dow int` `03:18,30`; convention `0=Sun..6=Sat` `03:23` |
| `is_closed` | `boolean` (proven) | nullable (unknown) | `IF row.is_closed THEN` `03:37` |
| `opening_time` | `time` (proven by comparison) | NOT NULL (guessed) | compared to `tjk_time time` `03:19,46,49`; `row.opening_time = row.closing_time` `03:41` |
| `closing_time` | `time` (proven by comparison) | NOT NULL (guessed) | `03:41,45,46,49` |

Semantics encoded in `restaurant_within_hours` (`03:6-52`): missing row ⇒ always
open (`03:33-35`); `is_closed` ⇒ closed; `opening_time = closing_time` ⇒ closed
marker (`03:41-43`); `closing_time < opening_time` ⇒ past-midnight window
(`03:47-50`). Row uniqueness per `(restaurant_id, day_of_week)` is *not*
guaranteed — the lookup uses `LIMIT 1` (`03:31`), implying no unique constraint.

---

### 1.7 `menu_items` — **inferred**

| column | type | nullability | evidence |
|---|---|---|---|
| `id` | `uuid` | NOT NULL, PK | FK target `REFERENCES menu_items(id)` `02:15`; `WHERE id = rec.menu_item_id` where `rec.menu_item_id = (it->>'menu_item_id')::uuid` `04:72,80` |
| `restaurant_id` | `uuid` | NOT NULL (guessed) | index `menu_items(restaurant_id, sort_order)` `01:11`; `r.id = menu_items.restaurant_id` `01:29`, `01:42` |
| `sort_order` | `int` (corroborated by `Sources/RavonCore/Models/MenuItem.swift:12` `public let sortOrder: Int`) | NOT NULL (inferred from non-optional Swift decode) | index `01:11` |
| `deleted_at` | `timestamptz` | NULL (explicit) | **`01:5` (ADD COLUMN)**; `IS NULL` `01:12,25`; `IS NOT NULL` `04:81`, `07:10` |
| `is_available` | `boolean` | inferred NOT NULL | `is_available = true` `01:26`; `mi.is_available = false` `04:83`, `04:213`, `06:62` |
| `stock_count` | `int` (inferred: compared to `(it->>'quantity')::int`) | **nullable (proven)** | `mi.stock_count IS NOT NULL` `04:85,218,266`, `06:69,76`; `stock_count = stock_count - rec.quantity` `04:268`, `06:77` |
| `price` | `numeric` (inferred: added to `subtotal numeric`) | NOT NULL (guessed) | `subtotal + (mi.price * rec.quantity)` `04:94,227`; inserted into `unit_price`/`total_price` `04:262` |
| `name` | `text` | NOT NULL (guessed) | `mi.name` → `order_items.item_name` `04:263` |
| `description` | `text` | nullable (inferred — target column is `NULL`) | `mi.description` → `item_description` `02:19`, `04:263` |
| `image_url` | `text` | nullable (inferred) | `mi.image_url` → `item_image_url` `02:20`, `04:263` |

Bound as `menu_items%ROWTYPE` at `04:77`, `04:148`, `06:31`.

---

### 1.8 `menu_categories` — **inferred**

| column | type | nullability | evidence |
|---|---|---|---|
| `id` | `uuid` (guessed) | NOT NULL (guessed) | **never referenced in 01..19** |
| `restaurant_id` | `uuid` | NOT NULL (guessed) | index `01:15`; `r.id = menu_categories.restaurant_id` `01:63` |
| `sort_order` | `int` (corroborated `Sources/RavonCore/Models/MenuCategory.swift:7`) | NOT NULL (inferred) | index `01:15` |
| `deleted_at` | `timestamptz` | NULL (explicit) | **`01:6`**; `IS NULL` `01:16,52`; `IS NOT NULL` `07:14` |
| `is_available` | `boolean` | **NOT NULL (proven)**, `DEFAULT true` | **`01:7`**; `is_available = true` `01:53` |

---

### 1.9 `addresses` — **inferred**

| column | type | nullability | evidence |
|---|---|---|---|
| `id` | `uuid` | NOT NULL, PK | `WHERE a.id = p_address_id` with `p_address_id uuid` `04:129,202`; `WHERE id = NEW.address_id` `10:61` |
| `default_delivery_mode` | `text` | **NOT NULL (proven)**, `DEFAULT 'hand_to_me'` | **`10:17`**; CHECK `10:19-22` |
| `latitude` | `double precision` (proven) | nullable (inferred — 2nd arg of COALESCE) | `COALESCE(..., (SELECT latitude FROM addresses WHERE id = o.address_id))` `13:44-45` |
| `longitude` | `double precision` (proven) | nullable (inferred) | `13:46-47` |
| *(remaining columns)* | **UNKNOWN** | | the whole row is snapshotted via `to_jsonb(a.*)` `04:202`, which hides the column list. **UNKNOWN — needs live introspection.** |

CHECK: `addresses_delivery_mode_valid` → `default_delivery_mode IN ('hand_to_me','leave_at_door')` (`10:20-22`).

The `delivery_address_snapshot` jsonb on `orders` is proven to contain keys
`latitude` and `longitude` (read at `13:44,46`) because it is `to_jsonb` of an
`addresses` row.

---

### 1.10 `profiles` — **inferred**

| column | type | nullability | evidence |
|---|---|---|---|
| `id` | `uuid` | NOT NULL, **PK/unique (proven)** | `ON CONFLICT (id) DO NOTHING` `18:30` requires a unique index on `id`; FK target `REFERENCES profiles(id) ON DELETE CASCADE` `09:41`; `NEW.id` from `auth.users` `18:24` |
| `full_name` | `text` | NOT NULL (inferred — `COALESCE(..., '')` at insert suggests NOT NULL) | `18:22,25` |
| `role` | **`user_role`** (proven) | NOT NULL (inferred — `COALESCE(..., 'consumer'::user_role)`) | `(NEW.raw_user_meta_data->>'role')::user_role` `18:26`; `role::text` `15:19,27`; `role = 'courier'` `13:163`; `NEW.role IS DISTINCT FROM OLD.role` `19:25` |
| `created_at` | `timestamptz` | NOT NULL (guessed) | inserted `now()` `18:22,27` |
| `updated_at` | `timestamptz` | NOT NULL (guessed) | inserted `now()` `18:22,28` |
| `is_suspended_until` | `timestamptz` | NULL (explicit) | **`08:38`**; `IS NOT NULL AND v_susp > now()` `13:96`, `13:169`; set `now() + interval '24 hours'` `14:106`, `17:103` |

---

### 1.11 `courier_locations` — **inferred**

Bound as `courier_locations%ROWTYPE` at `13:28` and `13:85`.

| column | type | nullability | evidence |
|---|---|---|---|
| `courier_id` | `uuid` | NOT NULL, likely PK/unique | every access is `WHERE courier_id = <uuid>` with no `LIMIT` and `SELECT * INTO` a scalar rowtype `13:37,109,174`; `UPDATE ... WHERE courier_id = v_uid` `13:125`. Uniqueness **inferred, not proven** |
| `latitude` | `double precision` | NOT NULL (guessed) | assigned `p_latitude double precision` `13:73,116,128` |
| `longitude` | `double precision` | NOT NULL (guessed) | `13:74,117,128` |
| `heading` | `double precision` | nullable (inferred — param `DEFAULT NULL`) | `13:76,118,128` |
| `speed` | `double precision` | **nullable (proven)** | `COALESCE(NULLIF(cl.speed, 0), 25.0/3.6)` `13:57`; `13:77,119,128` |
| `geog` | `extensions.geography` (inferred from `v_new_geog extensions.geography` `13:87` being passed to the same `ST_Distance`) | nullable (see defect below) | `ST_Distance(cl.geog, ...)` `13:53-54`; `ST_Distance(v_existing.geog, v_new_geog)` `13:113` |
| `is_online` | **`boolean`** (proven) | nullable (proven) | `SELECT is_online INTO v_is_online` with `v_is_online boolean` `13:157,174`; `IS DISTINCT FROM true` `13:175`; index predicate `is_online = true` `08:53`; set `false` `14:107` |
| `last_updated` | `timestamptz` | **nullable (proven)** | `COALESCE(last_updated, now())` `08:26,28`; `last_updated = now()` `13:121` |
| `current_order_id` | `uuid` | **nullable (proven)** | set to `p_order_id` `13:214`, set to `NULL` `13:548`, `13:706` |
| `accuracy_meters` | `double precision` | nullable (no NOT NULL) | **`08:22`**; `p_accuracy_meters ... > 200` `13:102` |
| `last_heartbeat_at` | `timestamptz` | **NOT NULL (proven)**, `DEFAULT now()` | added nullable `08:20`, backfilled `08:26-27`, then `SET NOT NULL` + `SET DEFAULT now()` `08:32-33` |
| `last_moved_at` | `timestamptz` | **NOT NULL (proven)**, `DEFAULT now()` | added `08:21`, backfilled `08:28-29`, `SET NOT NULL` + `SET DEFAULT` `08:34-35` |
| `ghost_strikes` | `int` | **NOT NULL (proven)**, `DEFAULT 0` | **`08:23`**; `COALESCE(ghost_strikes,0) + 1` `14:101` |
| `strikes_reset_at` | `timestamptz` | **NOT NULL (proven)**, `DEFAULT now()` | **`08:24`**; `v_reset_at IS NOT NULL` `14:78` |

**Defect — `geog` is read but never written.** `update_courier_heartbeat`
updates `latitude, longitude, heading, speed, accuracy_meters, last_updated,
last_heartbeat_at, last_moved_at, is_online` (`13:115-125`) and inserts
`courier_id, latitude, longitude, heading, speed, accuracy_meters, is_online,
last_updated, last_heartbeat_at, last_moved_at` (`13:127-133`) — `geog` is in
neither list, yet `13:113` and `13:54` read it. So `geog` must be a
`GENERATED ALWAYS AS (...) STORED` column or maintained by a pre-existing
trigger. Neither exists in 01..19. If it is a plain nullable column, then for a
first-ever heartbeat the INSERT leaves `geog` NULL, `ST_Distance` returns NULL,
`CASE WHEN v_distance_moved > 25` (`13:123`) evaluates NULL → false → the
courier's `last_moved_at` freezes, and `compute_eta_minutes` returns NULL
forever. **UNKNOWN — needs live introspection** to determine whether `geog` is
generated. `geog` appears nowhere in the Swift package (only in a doc comment,
`Sources/RavonCore/Services/CourierLocationStreamer.swift:22`).

---

### 1.12 `courier_earnings` — **inferred**

| column | type | nullability | evidence |
|---|---|---|---|
| `courier_id` | `uuid` | NOT NULL (guessed) | inserted `p_courier_id uuid` `12:62,88,91` |
| `order_id` | `uuid`, **UNIQUE (proven)** | NOT NULL (guessed) | `ON CONFLICT (order_id) DO UPDATE` `12:94` proves a unique index/constraint on `order_id` alone |
| `delivery_fee` | `numeric` | NOT NULL (guessed) | inserted `v_delivery_fee numeric` `12:74,88,91` |
| `tip_amount` | `numeric` (guessed) | NOT NULL (guessed) | inserted literal `0` `12:88,91` |
| `total_earned` | `numeric` | NOT NULL (guessed) | inserted `round((...)::numeric, 2)` `12:84,88` |
| `earning_type` | `text` | **NOT NULL (proven)**, `DEFAULT 'full'` | **`12:18`**; CHECK `12:27-32` |
| `tier_pct` | `int` | **NOT NULL (proven)**, `DEFAULT 100` | **`12:19`** |
| `cancellation_reason_code` | `text` | nullable | **`12:20`** |
| `status_at_event` | `order_status` | nullable | **`12:21`** |

CHECK `courier_earnings_type_valid`: `earning_type IN ('full','partial_assigned','partial_at_restaurant','partial_picked_up_lost','no_show_compensation','manual_adjustment','clawback')` (`12:26-32`).

**Dead backfill.** `12:24` is
`UPDATE courier_earnings SET earning_type='full', tier_pct=100 WHERE earning_type IS NULL OR earning_type = ''`.
Because `12:18` just added the column as `NOT NULL DEFAULT 'full'`, the
`IS NULL` branch can never match and `= ''` can only match if the column
pre-existed as empty text. Harmless no-op in the common case.

**Unreachable CHECK value.** `no_show_compensation` is in the CHECK list
(`12:30`) but no code path ever writes it: `earning_type_for_status` (`12:47-57`)
can only return `partial_assigned`, `partial_at_restaurant`,
`partial_picked_up_lost`, `manual_adjustment`; the only override passed anywhere
is `'clawback'` (`14:89`, `17:87`); and the no-show path (`16:65-71`) relies on
the pre-existing `create_courier_earning` delivered-trigger, which writes
`'full'`. So the tag never appears.

---

### 1.13 `chat_messages` — **inferred**

| column | type | nullability | evidence |
|---|---|---|---|
| `id` | `uuid` (guessed) | NOT NULL (guessed) | **never referenced in 01..19** |
| `order_id` | `uuid` | NOT NULL (guessed) | inserted `p_order_id uuid` `13:597-598`; `o.id = chat_messages.order_id` `15:52-53,69,86,94`; index `15:100` |
| `sender_id` | `uuid` | NOT NULL (guessed) | inserted `v_uid`/`rec.courier_id` `13:598`, `14:59`; `sender_id = auth.uid()` `15:49`; `cm.sender_id = p.id` `15:20` |
| `body` | `text` | NOT NULL (guessed) | inserted string concatenations `13:599`, `14:60`, `16:43,132`, `17:61,188,222,279` |
| `created_at` | `timestamptz` (guessed) | NOT NULL (guessed) | index `(order_id, created_at DESC)` `15:99-100` |
| `read_at` | `timestamptz` (guessed) | nullable | **comment-only in migrations** (`15:79` "set read_at"). Corroborated outside migrations: `Sources/RavonCore/Models/ChatMessage.swift:20,58` (`readAt: Date?` ↔ `"read_at"`) and `Sources/RavonCore/Services/SupabaseService.swift:1085,1088` |
| `sender_role` | `text` | nullable | **`15:12`**; CHECK `15:14-16`; `IS NULL` `15:26` |

CHECK `chat_messages_sender_role_valid`:
`sender_role IS NULL OR sender_role IN ('consumer','courier','merchant','system')` (`15:15-16`).

---

### 1.14 `auth.users` — **inferred** (Supabase-managed, out of our control)

| column | type | evidence |
|---|---|---|
| `id` | `uuid` | `NEW.id` inserted into `profiles.id` `18:24` |
| `raw_user_meta_data` | `jsonb` | `->>` operator with keys `full_name`, `role` `18:25-26` |
| `email` | `text` | comment only, `18:48` |
| `created_at` | `timestamptz` | comment only, `18:43` |

---

### 1.15 `cron.job` — **inferred** (pg_cron-managed)

| column | evidence |
|---|---|
| `jobname` | `WHERE jobname = 'courier_escalation_ladder'` `14:119`; `WHERE jobname = 'mark_no_show_deliveries'` `16:144` |
| `schedule` | implied by `README.md:135-136` verification query |

---

### 1.16 Tables with ZERO references in migrations 01..19

Confirmed by exhaustive grep. All four are touched from Swift (per the
orchestrator's verified 15-table list) but are invisible to this migration set,
so their schema is **UNKNOWN — needs live introspection**:

| table | Swift evidence |
|---|---|
| `order_status_history` | `Sources/RavonCore/Services/SupabaseService.swift:293` |
| `menu_item_modifier_groups` | in verified Swift table list |
| `modifier_groups` | in verified Swift table list |
| `modifier_options` | in verified Swift table list |

This is a material gap: `order_status_history` is described in `CLAUDE.md` as
the "audit trail of status changes", yet the migration set performs ~25
`UPDATE orders SET status = ...` statements and never once writes a history row.
Either a pre-existing trigger populates it (not defined in 01..19) or the audit
trail is silently incomplete for every RPC-driven transition. **UNKNOWN.**

---

## 2. Views

| view | definition | grants |
|---|---|---|
| `restaurants_orderable` | `SELECT r.*, restaurant_is_orderable(r.id) AS is_orderable_now FROM restaurants r WHERE r.restaurant_status = 'active'` (`03:73-77`) | `GRANT SELECT ... TO authenticated, anon` (`03:79`) |

**Security note.** The view is created without `WITH (security_invoker = true)`.
On Postgres 15+ that means it executes with the *view owner's* privileges and
therefore **bypasses RLS on `restaurants`**. Combined with the `anon` grant at
`03:79`, every column of every `restaurant_status='active'` row — including
`owner_id` and any unknown tail columns — is readable by an unauthenticated
caller hitting `/rest/v1/restaurants_orderable`. This is exactly the class of
issue `CLAUDE.md` warns about ("Any policy or RPC reachable with anon must be
safe against direct API access outside the app").

---

## 3. Enums

### 3.1 `order_status` — **no `CREATE TYPE` anywhere in 01..19**

The type pre-exists. Only two values are added:

| value | how added | evidence |
|---|---|---|
| `scheduled` | `ALTER TYPE order_status ADD VALUE 'scheduled' BEFORE 'created'`, guarded by a `pg_enum` existence check | `06:9-17` |
| `cancelled_by_courier` | `ALTER TYPE order_status ADD VALUE 'cancelled_by_courier'` (appended at the end), same guard | `09:6-13` |

Full value set provable from literals compared against, or assigned to, a value
of type `order_status` (17 values):

| # | value | evidence (representative) |
|---|---|---|
| 1 | `scheduled` | `06:15` (`ADD VALUE ... BEFORE 'created'`), `04:63`, `04:194`, `06:34`, `06:99`, `13:457` |
| 2 | `created` | `06:15` (named as the anchor ⇒ was the first value), `04:204`, `06:81`, `13:457` |
| 3 | `accepted` | `13:197`, `13:457`, `13:729` |
| 4 | `preparing` | `13:197`, `13:457`, `13:729` |
| 5 | `ready` | `13:197`, `13:457`, `13:538`, `13:688`, `13:729`; tier `0` per `12:43` + `README.md:104` |
| 6 | `assigned` | `08:57`, `12:38`, `12:50`, `13:208`, `13:246`, `13:521`, `14:35` |
| 7 | `courier_arrived_restaurant` | `08:57`, `12:39`, `12:51`, `13:237`, `13:280`, `16:103` |
| 8 | `picked_up` | `08:57`, `12:40`, `12:52`, `13:290`, `13:322`, `13:453` |
| 9 | `delivering` | `08:57`, `12:41`, `12:53`, `13:315`, `13:360`, `13:401` |
| 10 | `courier_arrived_customer` | `08:57`, `12:42`, `12:54`, `13:351`, `16:30`, `16:60` |
| 11 | `delivered` | `04:60`, `10:51`, `13:182`, `13:419`, `15:57`, `16:66` |
| 12 | `cancelled` | `04:60`, `10:51`, `13:182`, `15:72` |
| 13 | `rejected` | `04:60`, `10:51`, `13:182`, `15:73` |
| 14 | `cancelled_by_customer` | `04:61`, `10:52`, `13:183`, `13:470`, `15:72` |
| 15 | `cancelled_by_restaurant` | `04:61`, `10:52`, `13:183`, `15:72` |
| 16 | `cancelled_by_system` | `04:61`, `06:41`, `13:184`, `13:679`, `14:92`, `16:116` |
| 17 | `cancelled_by_courier` | `09:11` (`ADD VALUE`), `13:184`, `13:552`, `15:73` |

**Ordinal ordering (partially provable):** `scheduled` sorts before `created`
(`06:15`) and `cancelled_by_courier` sorts last (`09:11`, plain append). The
relative order of values 2–16 is **UNKNOWN — needs live introspection** (no
`CREATE TYPE` to read it from). This matters: `orders_action_sla_idx` (`08:55-57`)
and several `status IN (...)` predicates are order-insensitive, but any future
`status > 'picked_up'` style comparison would depend on it. The comment at
`13:15-17` ("When status <= picked_up") describes ordinal thinking, though the
implementation (`13:40`) correctly uses `IN` on `status::text` instead.

### 3.2 `user_role` — **no `CREATE TYPE` anywhere in 01..19**

| value | evidence | strength |
|---|---|---|
| `consumer` | `COALESCE((NEW.raw_user_meta_data->>'role')::user_role, 'consumer'::user_role)` `18:26` | **proven** (cast literal) |
| `courier` | `WHERE id = v_uid AND role = 'courier'` `13:163` | **proven** (compared to `profiles.role`, typed `user_role`) |
| `merchant` | `UPDATE profiles SET role = 'merchant'` — **comment only**, `19:45`, `19:55` | **guessed** from migrations; corroborated by `CLAUDE.md` ("UserRole (consumer/courier/merchant)") |

Note: `chat_messages.sender_role` also uses the strings
`consumer/courier/merchant/system` (`15:16`) but it is a `text` column with a
CHECK, **not** the `user_role` enum — and `system` is not a `user_role` value.
`15:19` and `15:27` bridge the two with an explicit `role::text` cast.

### 3.3 Pseudo-enums: `text` + CHECK (not Postgres enums)

| pseudo-enum | column | values | evidence |
|---|---|---|---|
| cancellation reason code | `orders.cancellation_reason_code` | 17 values, see §4.3 | CHECK `09:20-36` |
| delivery mode | `addresses.default_delivery_mode`, `orders.delivery_mode` | `hand_to_me`, `leave_at_door` | CHECK `10:20-22`, `10:29-31` |
| earning type | `courier_earnings.earning_type` | `full`, `partial_assigned`, `partial_at_restaurant`, `partial_picked_up_lost`, `no_show_compensation`, `manual_adjustment`, `clawback` | CHECK `12:27-32` |
| sender role | `chat_messages.sender_role` | `consumer`, `courier`, `merchant`, `system` | CHECK `15:15-16` |
| courier delay reason | `orders.courier_delay_reason_code` | `traffic`, `restaurant_slow`, `address_unclear`, `customer_unreachable`, `other` | **NO CHECK constraint.** Enforced only inside `courier_explain_delay` (`13:619`, `17:125`). Also written server-side as `customer_unreachable` (`16:38`, `17:217`) and `restaurant_slow` (`16:127`, `17:274`) |
| courier cancel whitelist | argument to `cancel_order_by_courier` | `COURIER_VEHICLE_ISSUE`, `COURIER_SAFETY_ISSUE`, `COURIER_RESTAURANT_CLOSED`, `COURIER_ITEMS_UNAVAILABLE`, `RESTAURANT_TOO_LONG_WAIT` | `13:494-497` |

---

## 4. Constraints

### 4.1 Foreign keys declared in 01..19

| constraint | definition | evidence |
|---|---|---|
| `order_items_menu_item_id_fkey` | `order_items(menu_item_id) → menu_items(id) ON DELETE SET NULL` (replaces a pre-existing FK dropped at `02:12`) | `02:13-15` |
| *(unnamed)* | `courier_cancellation_log.courier_id → profiles(id) ON DELETE CASCADE` | `09:41` |
| *(unnamed)* | `courier_cancellation_log.order_id → orders(id) ON DELETE CASCADE` | `09:42` |

### 4.2 Unique / PK constraints provable indirectly

| table | key | proof |
|---|---|---|
| `courier_earnings` | unique on `(order_id)` | `ON CONFLICT (order_id) DO UPDATE` `12:94` |
| `profiles` | unique on `(id)` | `ON CONFLICT (id) DO NOTHING` `18:30` |
| `courier_cancellation_log` | PK `(id)` | literal `09:40` |

### 4.3 `orders.cancellation_reason_code` CHECK — all 17 accepted values (`09:20-36`)

| group | values |
|---|---|
| Consumer (`09:23`) | `CONSUMER_CHANGED_MIND`, `CONSUMER_DUPLICATE` |
| Restaurant (`09:25`) | `RESTAURANT_CLOSED`, `RESTAURANT_OUT_OF_ITEMS`, `RESTAURANT_REJECTED`, `RESTAURANT_TOO_LONG_WAIT` |
| Courier (`09:27-28`) | `COURIER_VEHICLE_ISSUE`, `COURIER_SAFETY_ISSUE`, `COURIER_RESTAURANT_CLOSED`, `COURIER_ITEMS_UNAVAILABLE`, `COURIER_NON_RESPONSIVE` |
| System (`09:30`) | `SYSTEM_TIMEOUT`, `SYSTEM_FRAUD_SUSPECTED` |
| Scheduled-order (`09:32`) | `RESTAURANT_NOT_OPEN_AT_SCHEDULED_TIME`, `ITEM_UNAVAILABLE`, `INSUFFICIENT_STOCK`, `ITEM_DELETED` |
| No-show (`09:34`) | `CUSTOMER_NO_SHOW` |

**Comment/code mismatch.** `09:27` labels the courier block as the
"whitelist for `cancel_order_by_courier`", but the actual whitelist at
`13:494-497` differs in both directions: it **excludes** `COURIER_NON_RESPONSIVE`
(system-only, written at `13:671`, `14:89`, `17:87`) and **includes**
`RESTAURANT_TOO_LONG_WAIT`, which `09:25` files under "Restaurant-initiated".

**Unreachable CHECK values.** `CONSUMER_DUPLICATE`, `RESTAURANT_OUT_OF_ITEMS`,
`RESTAURANT_REJECTED`, `SYSTEM_TIMEOUT`, `SYSTEM_FRAUD_SUSPECTED` and plain
`RESTAURANT_CLOSED` are never written by any RPC in 01..19. `cancel_order_by_consumer`
hardcodes `'CONSUMER_CHANGED_MIND'` (`13:473`) and ignores its own `p_reason`
for the typed field, so `CONSUMER_DUPLICATE` is unreachable from the consumer app.

---

## 5. pg_cron schedules

| # | jobname | cadence | cron expr | command | evidence | idempotency guard |
|---|---|---|---|---|---|---|
| 1 | `auto_resume_accepting_orders` | every 5 min | `*/5 * * * *` | inline `UPDATE restaurants SET is_accepting_orders=true, accepting_orders_until=NULL WHERE is_accepting_orders=false AND accepting_orders_until IS NOT NULL AND accepting_orders_until <= now()` | `05:46-56` | none (relies on `cron.schedule` name-upsert) |
| 2 | `activate_scheduled_orders` | every minute | `* * * * *` | `SELECT activate_scheduled_orders();` | `06:110-114` | none |
| 3 | `purge_soft_deleted_menu` | daily 03:00 server time | `0 3 * * *` | `DELETE FROM menu_items WHERE deleted_at < now()-30d; DELETE FROM menu_categories WHERE deleted_at < now()-30d` | `07:5-17` | none |
| 4 | `courier_escalation_ladder` | every minute | `* * * * *` | `SELECT run_courier_escalation_ladder();` | `14:117-126` | `IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname=...)` `14:119` |
| 5 | `mark_no_show_deliveries` | every minute | `* * * * *` | `SELECT mark_no_show_deliveries();` | `16:142-151` | `IF NOT EXISTS (... cron.job ...)` `16:144` |

Three jobs fire **every minute** (#2, #4, #5). Jobs #4 and #5 are name-guarded,
so a changed cadence in a later edit of the file would silently not apply.

A sixth, **pre-existing** cron is referenced but not defined here: the "Batch 1
auto-cancel" job (`05:45` comment). Name and cadence **UNKNOWN**.

**Risk in #3.** `purge_soft_deleted_menu` hard-`DELETE`s `menu_items` rows.
`order_items.menu_item_id` is safe (`ON DELETE SET NULL`, `02:15`), but
`menu_item_modifier_groups` (a real table per the Swift surface) presumably FKs
`menu_items(id)` and its `ON DELETE` action is **UNKNOWN**. If it is `NO ACTION`
/ `RESTRICT`, the nightly purge throws and silently leaves soft-deleted rows
forever.

---

## 6. Indexes

| index | table | definition | evidence |
|---|---|---|---|
| `menu_items_active_idx` | `menu_items` | `(restaurant_id, sort_order) WHERE deleted_at IS NULL` | `01:10-12` |
| `menu_categories_active_idx` | `menu_categories` | `(restaurant_id, sort_order) WHERE deleted_at IS NULL` | `01:14-16` |
| `courier_locations_heartbeat_idx` | `courier_locations` | `(last_heartbeat_at) WHERE is_online = true` | `08:51-53` |
| `orders_action_sla_idx` | `orders` | `(expected_action_by) WHERE status IN ('assigned','courier_arrived_restaurant','picked_up','delivering','courier_arrived_customer')` | `08:55-57` |
| `courier_cancellation_log_recent_idx` | `courier_cancellation_log` | `(courier_id, created_at DESC)` | `09:48-49` |
| `chat_messages_order_recent_idx` | `chat_messages` | `(order_id, created_at DESC)` | `15:99-100` |

All six use `IF NOT EXISTS`. No index is ever dropped.

**Missing indexes implied by hot queries in 01..19:**

| query | file:line | index that would serve it | present? |
|---|---|---|---|
| `SELECT count(*) FROM orders WHERE restaurant_id = r.id AND status NOT IN (...)` — runs on every `validate_cart` and `create_order` | `04:57-63`, `04:188-194` | `orders(restaurant_id, status)` | **no** |
| `SELECT id FROM orders WHERE courier_id = v_uid AND status NOT IN (...)` — runs on every `claim_order` | `13:180-184` | `orders(courier_id, status)` | **no** |
| `SELECT o.id FROM orders o WHERE o.status='scheduled' AND ...` — runs every minute | `06:96-100` | `orders(status) WHERE status='scheduled'` | **no** |
| `WHERE status='courier_arrived_customer' AND no_show_started_at IS NOT NULL AND ...` — runs every minute | `16:59-63` | `orders(no_show_started_at) WHERE status='courier_arrived_customer'` | **no** |
| `WHERE restaurant_id = p_restaurant AND day_of_week = tjk_dow` on `restaurant_hours` — runs on every orderability check | `03:28-31` | `restaurant_hours(restaurant_id, day_of_week)` | **no** (and the `LIMIT 1` at `03:31` implies no unique constraint either) |
| `WHERE is_accepting_orders=false AND accepting_orders_until IS NOT NULL AND accepting_orders_until <= now()` — every 5 min | `05:52-54` | partial index on `restaurants(accepting_orders_until)` | **no** |

---

## 7. RLS

### 7.1 `ENABLE ROW LEVEL SECURITY` — exactly one statement in 01..19

`ALTER TABLE courier_cancellation_log ENABLE ROW LEVEL SECURITY;` (`09:51`).

**This is the single most important finding in this section.** Migration 01
creates four SELECT policies on `menu_items` and `menu_categories`
(`01:21,36,48,57`) and migration 15 creates three policies on `chat_messages`
(`15:46,63,80`), but **neither migration enables RLS on those tables**. Policies
on a table with `relrowsecurity = false` are completely inert — Postgres stores
them and ignores them. So either RLS was already enabled on those tables by an
earlier, uncommitted migration (likely, given the Russian-named policies dropped
at `15:40-42`), or all seven policies are dead. Migrations 01..19 cannot tell
you which. **UNKNOWN — needs live introspection** (`SELECT relname, relrowsecurity,
relforcerowsecurity FROM pg_class WHERE relname IN (...)`).

Tables with **no** RLS statement of any kind in 01..19:
`orders`, `order_items`, `order_item_modifiers`, `restaurants`,
`restaurant_hours`, `addresses`, `profiles`, `courier_locations`,
`courier_earnings` (9 tables). Their RLS posture is entirely pre-existing and
unverifiable from this set.

### 7.2 Policies created

| policy | table | cmd | roles | expression | evidence |
|---|---|---|---|---|---|
| `menu_items_select_consumer` | `menu_items` | SELECT | `authenticated` | USING `deleted_at IS NULL AND is_available = true AND EXISTS(restaurant with restaurant_status='active')` | `01:21-32` |
| `menu_items_select_merchant` | `menu_items` | SELECT | `authenticated` | USING `EXISTS(restaurants r WHERE r.id = menu_items.restaurant_id AND r.owner_id = auth.uid())` | `01:36-45` |
| `menu_categories_select_consumer` | `menu_categories` | SELECT | `authenticated` | USING `deleted_at IS NULL AND is_available = true` | `01:48-54` |
| `menu_categories_select_merchant` | `menu_categories` | SELECT | `authenticated` | USING `EXISTS(restaurants r ... owner_id = auth.uid())` | `01:57-66` |
| `courier_cancel_log_self_select` | `courier_cancellation_log` | SELECT | `authenticated` | USING `courier_id = auth.uid()` | `09:54-56` |
| `chat_messages_insert` | `chat_messages` | INSERT | `authenticated` | WITH CHECK `sender_id = auth.uid() AND EXISTS(order where caller is user/courier/owner AND (status IN 5 active values OR (status='delivered' AND delivered_at > now()-5min)))` | `15:46-60` |
| `chat_messages_select` | `chat_messages` | SELECT | `authenticated` | USING `EXISTS(order where caller is user/courier/owner AND (status NOT IN 7 terminal values OR COALESCE(delivered_at, updated_at) > now()-30 days))` | `15:63-77` |
| `chat_messages_mark_read` | `chat_messages` | UPDATE | `authenticated` | USING **and** WITH CHECK: `sender_id <> auth.uid() AND EXISTS(orders o WHERE o.id = chat_messages.order_id AND (o.user_id = auth.uid() OR o.courier_id = auth.uid()))` | `15:80-97` |

### 7.3 Policies dropped

| policy | table | re-created? | evidence |
|---|---|---|---|
| `menu_items_select_consumer` | `menu_items` | yes, same name | `01:20` → `01:21` |
| `menu_items_select_merchant` | `menu_items` | yes | `01:35` → `01:36` |
| `menu_categories_select_consumer` | `menu_categories` | yes | `01:47` → `01:48` |
| `menu_categories_select_merchant` | `menu_categories` | yes | `01:56` → `01:57` |
| `courier_cancel_log_self_select` | `courier_cancellation_log` | yes | `09:53` → `09:54` |
| `"Order participants can read chat"` | `chat_messages` | **no — retired** | `15:40` |
| `"Order participants can send chat"` | `chat_messages` | **no — retired** | `15:41` |
| `"Recipients can mark chat read"` | `chat_messages` | **no — retired** | `15:42` |

`01:19` explicitly admits the policy names are a guess: *"Adjust policy names to
match the project — these are illustrative."* So the four `DROP POLICY IF EXISTS`
in migration 01 may be no-ops that leave the *real* pre-existing consumer/merchant
policies in place alongside the new ones. Since multiple PERMISSIVE policies on
the same command OR together, a leftover broad policy would defeat the new
soft-delete filter at `01:25`. **UNKNOWN — needs live introspection.**

### 7.4 RLS gaps and over-broad grants (severity-ordered)

1. **`chat_messages_mark_read` is an unrestricted UPDATE, not a read-receipt.**
   `15:80-97`. Postgres RLS cannot scope columns, and the policy's `WITH CHECK`
   only re-asserts `sender_id <> auth.uid()` plus participation. Nothing stops an
   order participant from `PATCH /chat_messages?id=eq.<x>` with
   `{"body":"...", "sender_role":"system"}` and rewriting the *content* of any
   message they did not send, including forging a `system` notice. The comment at
   `15:79` claims "only mark messages NOT sent by self as read (set read_at)" —
   the SQL does not implement that. This is the "over-broad UPDATE policies"
   pattern `CLAUDE.md` flags.
2. **No `REVOKE` anywhere, so `EXECUTE` defaults to `PUBLIC`.** §8.3.
3. **`restaurants_orderable` granted to `anon` without `security_invoker`.** §2.
4. **No DELETE policy on any table** — deletes are implicitly denied wherever
   RLS is on, which is the safe default, but `courier_cancellation_log` has RLS
   on with only a SELECT policy, so the cooldown log is append-only-via-RPC.
   Correct by design (`09:58`).

---

## 8. Grants and function privileges

### 8.1 Table/view grants (1 statement)

| object | privilege | grantees | evidence |
|---|---|---|---|
| `restaurants_orderable` (view) | `SELECT` | `authenticated`, `anon` | `03:79` |

No `GRANT` on any base table anywhere in 01..19.

### 8.2 `GRANT EXECUTE` — all 35 statements, 24 distinct functions

| function | grantees | evidence | `SECURITY DEFINER`? | `SET search_path`? |
|---|---|---|---|---|
| `restaurant_within_hours(uuid, timestamptz)` | `authenticated`, **`anon`** | `03:152` | yes `03:13` | `public` `03:14` |
| `restaurant_is_orderable(uuid, timestamptz)` | `authenticated`, **`anon`** | `03:153` | yes `03:62` | `public` `03:63` |
| `get_restaurant_orderability(uuid, timestamptz)` | `authenticated`, **`anon`** | `03:154` | yes `03:90` | `public` `03:91` |
| `validate_cart(uuid, jsonb, timestamptz)` | `authenticated` | `04:118` | yes `04:14` | `public` `04:15` |
| `create_order(uuid, uuid, jsonb, text, timestamptz)` | `authenticated` | `04:277` | yes `04:136` | `public` `04:137` |
| `set_accepting_orders(uuid, boolean, timestamptz)` | `authenticated` | `05:42` | yes `05:14` | `public` `05:15` |
| `activate_scheduled_order(uuid)` | `authenticated` | `06:107` | yes `06:24` | `public` `06:25` |
| `earnings_tier_for_cancel(order_status)` | `authenticated` | `12:103` | no (IMMUTABLE sql) | **NO** `12:35-36` |
| `earning_type_for_status(order_status)` | `authenticated` | `12:104` | no (IMMUTABLE sql) | **NO** `12:47-48` |
| `compute_eta_minutes(uuid)` | `authenticated` | `13:63`, `13:739` (duplicated) | yes `13:23` | `public, extensions` `13:24` |
| `update_courier_heartbeat(double precision ×5)` | `authenticated` | `13:143`, `13:740` (duplicated) | yes `13:80` | `public, extensions` `13:81` |
| `claim_order(uuid)` | `authenticated` | `13:741` | yes `13:151` | `public` `13:152` |
| `courier_arrived_restaurant(uuid)` | `authenticated` | `13:742` | yes `13:229` | `public` `13:230` |
| `courier_pickup_order(uuid, text)` | `authenticated` | `13:743` | yes `13:261` | `public` `13:262` |
| `courier_start_delivering(uuid)` | `authenticated` | `13:744` | yes `13:307` | `public` `13:308` |
| `courier_arrived_at_customer(uuid)` | `authenticated` | `13:745` | yes `13:343` | `public` `13:344` |
| `courier_deliver_order(uuid, text, text)` | `authenticated` | `13:746` | yes `13:380` | `public` `13:381` |
| `cancel_order_by_consumer(uuid, text)` | `authenticated` | `13:747` | yes `13:434` | `public` `13:435` |
| `cancel_order_by_courier(uuid, text)` | `authenticated` | `13:748` | yes `13:484` | `public` `13:485` |
| `report_problem_post_pickup(uuid, text, text)` | `authenticated` | `13:749`, `17:286` | yes `13:570`, `17:162` | `public` |
| `courier_explain_delay(uuid, text, text)` | `authenticated` | `13:750`, `17:285` | yes `13:612`, `17:118` | `public` |
| `reassign_ghosted_order(uuid)` | `authenticated` | `13:751` | yes `13:654` | `public` `13:655` |
| `fetch_available_orders(double precision ×3)` | `authenticated` | `13:752` | yes `13:722` | `public, extensions` `13:723` |
| `run_courier_escalation_ladder()` | `authenticated` | `14:114`, `17:284` | yes `14:21`, `17:21` | `public` |
| `courier_report_customer_no_show(uuid)` | `authenticated` | `16:137`, `17:287` | yes `16:17`, `17:196` | `public` |
| `mark_no_show_deliveries()` | `authenticated` | `16:138` | yes `16:52` | `public` `16:53` |
| `courier_report_restaurant_delay(uuid, int)` | `authenticated` | `16:139`, `17:288` | yes `16:83`, `17:232` | `public` |

### 8.3 Functions created but **never granted** — and never revoked

`REVOKE` appears **zero** times in 01..19 (verified by grep). In stock Postgres,
`CREATE FUNCTION` grants `EXECUTE` to `PUBLIC` by default. Supabase does not
alter that default for functions created in `public`. Therefore every function
below is callable by `PUBLIC`, which includes both the `authenticated` and
**`anon`** roles:

| function | `SECURITY DEFINER`? | evidence | consequence if `PUBLIC` EXECUTE holds |
|---|---|---|---|
| `insert_courier_earning_for_cancel(uuid, uuid, order_status, text, int, text)` | **yes** `12:70` | defined `12:61-101`, no GRANT | **Critical.** Any caller can mint or overwrite a `courier_earnings` row for any order/courier with an arbitrary `p_tier_override` (including negative clawbacks) and arbitrary `p_earning_type_override`. `ON CONFLICT (order_id) DO UPDATE` (`12:94`) means it can also *rewrite* a legitimately-earned row. Zero authorization check in the body. |
| `activate_scheduled_orders()` | **yes** `06:89` | defined `06:86-105`, no GRANT | Any caller can force the global scheduled-order sweep. |
| `handle_new_user()` | **yes** `18:18` | defined `18:15-33` | Trigger function; called with a `trigger` context, so direct invocation fails with "may only be called as a trigger". Low risk. |
| `profiles_block_role_change()` | **yes** `19:21` | defined `19:18-32` | same — trigger-only. Low risk. |
| `generate_verification_code()` | no | defined `10:34-45` | trigger-only. Low risk. |
| `sync_order_delivery_mode_from_address()` | no | defined `10:55-68` | trigger-only. Low risk. |
| `set_chat_sender_role()` | no | defined `15:23-32` | trigger-only. Low risk. |

### 8.4 Granted functions that are `SECURITY DEFINER` with **no caller authorization**

These are granted to `authenticated` but perform privileged, global-scope work
without checking who the caller is. This is the "anon-callable SECURITY DEFINER
RPC" class `CLAUDE.md` calls out, one tier down (authenticated, not anon):

| function | grant | missing check | blast radius |
|---|---|---|---|
| `reassign_ghosted_order(uuid)` | `13:751` | **none at all** — body starts at `13:661` with `SELECT * INTO o FROM orders WHERE id = p_order_id FOR UPDATE` and never compares `auth.uid()` to anything | Any logged-in user can, for *any* order in `assigned`/`courier_arrived_restaurant`: mint a partial courier earning (`13:670`), strip the assigned courier (`13:689`), add them to `excluded_courier_ids` (`13:699-701`), bump `reassign_count`, and on the 3rd call force `cancelled_by_system` (`13:677-685`). Three REST calls cancel any in-flight order. |
| `mark_no_show_deliveries()` | `16:138` | none | Any logged-in user force-`delivered`s **every** order globally whose `no_show_started_at + 5 min` has elapsed, stamping `no_show = true` and `cancellation_reason_code = 'CUSTOMER_NO_SHOW'` (`16:65-71`). |
| `run_courier_escalation_ladder()` | `14:114`, `17:284` | none | Any logged-in user runs the **global** 3-pass ladder: writes `courier_no_show_*` stamps, posts system chat messages into other people's orders (`17:56-62`), cancels post-pickup orders with `-100%` clawbacks (`17:86-94`), increments `ghost_strikes`, and **suspends couriers for 24 h** (`17:103`) while forcing them offline (`17:104`). |
| `activate_scheduled_order(uuid)` | `06:107` | none | Any logged-in user can activate, or force-`cancelled_by_system`, any scheduled order belonging to anyone (`06:33-81`). |
| `compute_eta_minutes(uuid)` | `13:63`, `13:739` | none | Read-only, but leaks courier live position indirectly (returns an ETA for any order id). Low. |
| `earnings_tier_for_cancel` / `earning_type_for_status` | `12:103-104` | n/a | Pure functions. No risk. |

By contrast, the well-guarded ones do check: `claim_order` verifies role +
suspension + online + exclusion (`13:163-204`), `set_accepting_orders` verifies
ownership (`05:20-27`), and every `courier_*` transition RPC verifies
`courier_id IS DISTINCT FROM auth.uid()`.

### 8.5 Functions missing `SET search_path` (mutable-search_path lint)

| function | evidence |
|---|---|
| `generate_verification_code()` | `10:34-35` |
| `sync_order_delivery_mode_from_address()` | `10:55-56` |
| `earnings_tier_for_cancel(order_status)` | `12:35-36` |
| `earning_type_for_status(order_status)` | `12:47-48` |
| `set_chat_sender_role()` | `15:23-24` |

`README.md:138-141` says these were "tightened post-migration with
`ALTER FUNCTION ... SET search_path = public`" — but no such statement exists in
any of the 19 files, so **re-applying this migration set reintroduces the lint on
all five.** The README also names only two of the five
(`earnings_tier_for_cancel`, `set_chat_sender_role`).

---

## 9. Triggers

### 9.1 Created in 01..19

| trigger | table | timing / scope | `WHEN` | function | evidence |
|---|---|---|---|---|---|
| `orders_sync_delivery_mode` | `orders` | `BEFORE INSERT FOR EACH ROW` | — | `sync_order_delivery_mode_from_address()` | `10:70-73` |
| `chat_messages_set_sender_role` | `chat_messages` | `BEFORE INSERT FOR EACH ROW` | — | `set_chat_sender_role()` | `15:34-37` |
| `on_auth_user_created` | `auth.users` | `AFTER INSERT FOR EACH ROW` | — | `public.handle_new_user()` | `18:35-38` |
| `profiles_block_role_change` | `public.profiles` | `BEFORE UPDATE FOR EACH ROW` | `auth.uid() IS NOT NULL AND auth.uid() = OLD.id` | `public.profiles_block_role_change()` | `19:34-39` |

All four are `DROP TRIGGER IF EXISTS` then `CREATE TRIGGER`, so all four are idempotent.

### 9.2 Referenced but NOT defined in 01..19 — pre-existing, definition **UNKNOWN**

| trigger | evidence of existence | what it must do |
|---|---|---|
| *(name unknown)* on `orders` BEFORE INSERT calling `generate_verification_code()` | `10:33` "Update the existing INSERT trigger function"; the function is `CREATE OR REPLACE`d at `10:34` but **no `CREATE TRIGGER` is issued** | generate `verification_code` and (post-10) `delivery_verification_code` |
| `cleanup_cancelled_order` | comments `13:556`, `16:122` | clears `courier_locations.current_order_id` when an order enters a cancelled status |
| `create_courier_earning` | comment `16:72`; also `12:10` "The `delivered` trigger from Bunch 2 already inserts a default-tier row" | inserts a full-tier `courier_earnings` row on transition to `delivered` |
| *(name unknown)* populating `order_status_history` | none — the table is never mentioned in 01..19 | see §1.16 |

**Ordering hazard in §9.1 + §9.2.** Both `orders_generate_verification_code`
(unknown name) and `orders_sync_delivery_mode` are `BEFORE INSERT` on `orders`.
Postgres fires same-timing row triggers in **alphabetical order by trigger name**.
`orders_sync_delivery_mode` does not touch verification codes, so they do not
conflict today — but the interaction is undocumented and depends on a name we
cannot see. **UNKNOWN — needs live introspection.**

**Behavioural note on `orders_sync_delivery_mode`.** `10:60-64` overwrites
`NEW.delivery_mode` with the address default **unconditionally** whenever
`NEW.address_id IS NOT NULL` and the address has a non-null default. A client
that explicitly requests `leave_at_door` on an order whose address defaults to
`hand_to_me` will be silently overridden. Since `create_order` (`04:238-247`)
never sets `delivery_mode` at all, the only way to change an order's delivery
mode is to change the address default first — there is no per-order override
path in this migration set.

---

## 10. Functions catalogue (26 distinct)

| function | file:line | language | volatility | returns | SECURITY | notes |
|---|---|---|---|---|---|---|
| `restaurant_within_hours(uuid, timestamptz)` | `03:6` | plpgsql | STABLE | boolean | DEFINER | missing-row ⇒ open (`03:34`) |
| `restaurant_is_orderable(uuid, timestamptz)` | `03:55` | sql | STABLE | boolean | DEFINER | |
| `get_restaurant_orderability(uuid, timestamptz)` | `03:83` | plpgsql | STABLE | jsonb | DEFINER | always returns `opens_at: null` (`03:139`, `03:147`) — server never computes it |
| `validate_cart(uuid, jsonb, timestamptz)` | `04:6` | plpgsql | STABLE | jsonb | DEFINER | |
| `create_order(uuid, uuid, jsonb, text, timestamptz)` | `04:127` | plpgsql | VOLATILE | uuid | DEFINER | v3 |
| `set_accepting_orders(uuid, boolean, timestamptz)` | `05:7` | plpgsql | VOLATILE | void | DEFINER | owner check `05:20` |
| `activate_scheduled_order(uuid)` | `06:21` | plpgsql | VOLATILE | void | DEFINER | no authz |
| `activate_scheduled_orders()` | `06:86` | plpgsql | VOLATILE | void | DEFINER | not granted |
| `generate_verification_code()` | `10:34` | plpgsql | VOLATILE | trigger | INVOKER | no search_path |
| `sync_order_delivery_mode_from_address()` | `10:55` | plpgsql | VOLATILE | trigger | INVOKER | no search_path |
| `earnings_tier_for_cancel(order_status)` | `12:35` | sql | IMMUTABLE | int | INVOKER | no search_path |
| `earning_type_for_status(order_status)` | `12:47` | sql | IMMUTABLE | text | INVOKER | no search_path |
| `insert_courier_earning_for_cancel(...)` | `12:61` | plpgsql | VOLATILE | void | DEFINER | **not granted → PUBLIC** |
| `compute_eta_minutes(uuid)` | `13:19` | plpgsql | STABLE | int | DEFINER | PostGIS; 25 km/h fallback `13:57` |
| `update_courier_heartbeat(dp ×5)` | `13:72` | plpgsql | VOLATILE | void | DEFINER | 1 s soft rate limit `13:112`; 200 m accuracy gate `13:102`; 25 m move gate `13:123` |
| `claim_order(uuid)` | `13:148` | plpgsql | VOLATILE | uuid | DEFINER | best-guarded RPC in the set |
| `courier_arrived_restaurant(uuid)` | `13:226` | plpgsql | VOLATILE | void | DEFINER | 6-min SLA `13:239` |
| `courier_pickup_order(uuid, text)` | `13:258` | plpgsql | VOLATILE | void | DEFINER | 1-min SLA `13:292` |
| `courier_start_delivering(uuid)` | `13:304` | plpgsql | VOLATILE | void | DEFINER | SLA = ETA+3 min `13:332` |
| `courier_arrived_at_customer(uuid)` | `13:340` | plpgsql | VOLATILE | void | DEFINER | 5-min SLA `13:353` |
| `courier_deliver_order(uuid, text, text)` | `13:374` | plpgsql | VOLATILE | void | DEFINER | dual-mode proof `13:406-416` |
| `cancel_order_by_consumer(uuid, text)` | `13:431` | plpgsql | VOLATILE | void | DEFINER | refuses post-pickup `13:453` |
| `cancel_order_by_courier(uuid, text)` | `13:481` | plpgsql | VOLATILE | void | DEFINER | 5-code whitelist `13:494`; 3-in-24 h cooldown `13:503-509` |
| `report_problem_post_pickup(uuid, text, text)` | `13:564` / `17:155` | plpgsql | VOLATILE | void | DEFINER | `p_reason_code` **unvalidated** — free text into a chat message `17:188` |
| `courier_explain_delay(uuid, text, text)` | `13:606` / `17:112` | plpgsql | VOLATILE | void | DEFINER | 5-code whitelist `17:125` |
| `reassign_ghosted_order(uuid)` | `13:651` | plpgsql | VOLATILE | void | DEFINER | **no authz**; 3-strike auto-cancel `13:677` |
| `fetch_available_orders(dp ×3)` | `13:715` | sql | STABLE | `SETOF orders` | DEFINER | respects `excluded_courier_ids` `13:730` |
| `run_courier_escalation_ladder()` | `14:18` / `17:18` | plpgsql | VOLATILE | void | DEFINER | **no authz**; `FOR UPDATE SKIP LOCKED` |
| `set_chat_sender_role()` | `15:23` | plpgsql | VOLATILE | trigger | INVOKER | no search_path |
| `courier_report_customer_no_show(uuid)` | `16:14` / `17:193` | plpgsql | VOLATILE | void | DEFINER | |
| `mark_no_show_deliveries()` | `16:49` | plpgsql | VOLATILE | void | DEFINER | **no authz** |
| `courier_report_restaurant_delay(uuid, int)` | `16:78` / `17:227` | plpgsql | VOLATILE | void | DEFINER | ≤15 min per call `16:92`, 30-min cap `16:110` |
| `handle_new_user()` | `18:15` | plpgsql | VOLATILE | trigger | DEFINER | |
| `profiles_block_role_change()` | `19:18` | plpgsql | VOLATILE | trigger | DEFINER | |

(31 `CREATE OR REPLACE FUNCTION` statements; 5 functions are defined twice —
`run_courier_escalation_ladder`, `courier_explain_delay`,
`report_problem_post_pickup`, `courier_report_customer_no_show`,
`courier_report_restaurant_delay` — in `14`/`16` then again in `17`.)

---

## 11. Defects and hazards found while reconstructing

Ordered by severity. Every one is anchored to a line.

### S1 — `insert_courier_earning_for_cancel` is a `SECURITY DEFINER` money-writer with no GRANT, no REVOKE, and no authorization check
`12:61-101`. Defaults to `PUBLIC EXECUTE`. `p_tier_override` (`12:66`) and
`p_earning_type_override` (`12:67`) are attacker-controlled, and
`ON CONFLICT (order_id) DO UPDATE` (`12:94`) lets an attacker overwrite an
existing earning. The only input validation is `IF v_delivery_fee IS NULL THEN
RETURN` (`12:80`), which merely requires the order to exist.

### S2 — `reassign_ghosted_order(uuid)` granted to `authenticated` with zero authorization
`13:651-709`, granted `13:751`. Three calls against any order in
`assigned`/`courier_arrived_restaurant` drive `reassign_count` to 3 and force
`cancelled_by_system` (`13:677-685`). Denial-of-service against any merchant's
order flow, plus arbitrary courier-earning writes via `13:670`.

### S3 — `run_courier_escalation_ladder()` and `mark_no_show_deliveries()` are global mutators granted to `authenticated`
`14:114` / `17:284` and `16:138`. `run_courier_escalation_ladder` can **suspend
a courier for 24 h** (`17:103`) and force them offline (`17:104`).
`mark_no_show_deliveries` force-`delivered`s orders (`16:65-71`). Both were
written to be cron-only (`14:117`, `16:142`) — `pg_cron` runs as the job owner
and never needs `authenticated` to hold EXECUTE.

### S4 — `chat_messages_mark_read` UPDATE policy does not scope columns
`15:80-97`. See §7.4 item 1. Any order participant can rewrite `body` and
`sender_role` of messages they did not send.

### S5 — `restaurants_orderable` is granted to `anon` and is not `security_invoker`
`03:73-79`. `SELECT r.*` exposes every `restaurants` column, including
`owner_id`, to unauthenticated REST callers, bypassing whatever RLS exists on
`restaurants`.

### S6 — Migration 01 and 15 create policies but never `ENABLE ROW LEVEL SECURITY`
`01:21,36,48,57` and `15:46,63,80` vs. the single `ENABLE` at `09:51`. If RLS
is not already on for `menu_items` / `menu_categories` / `chat_messages`, all
seven policies are inert and those tables are fully readable/writable by any
`authenticated` caller. Cannot be determined from the files.

### S7 — Migration 04 depends on columns and an enum value added only in 05 and 06
- `04:49` and `04:169` read `r.accepting_orders_until` → added at `05:4`.
- `04:63` and `04:194` compare `status NOT IN (..., 'scheduled')` → value added at `06:15`.
- `04:204` assigns `status_value := 'scheduled'`; `04:241,246` insert `scheduled_for` → column added at `06:6`.

Because `validate_cart` and `create_order` are `LANGUAGE plpgsql`, the bodies are
not resolved at `CREATE` time, so migration 04 applies cleanly — and then
**every `create_order` and `validate_cart` call fails at runtime** until 05 and
06 land. `README.md:2` says "Apply in numeric order"; `06:3` even says "Apply
AFTER migration 04". So the documented order deliberately produces a window in
which ordering is broken. In a production apply this is a live outage window,
not a theoretical one.

### S8 — `courier_locations.geog` is read but never written
See §1.11. Depends on an undocumented generated column or pre-existing trigger.
If absent, first-heartbeat couriers get NULL ETAs forever and never register
movement.

### S9 — Migration 15 is not idempotent, contradicting `README.md:4`
`15:46`, `15:63`, `15:80` issue `CREATE POLICY` for `chat_messages_insert`,
`chat_messages_select`, `chat_messages_mark_read` with **no** preceding
`DROP POLICY IF EXISTS` for those names (the three drops at `15:40-42` target the
retired Russian names). `CREATE POLICY` has no `IF NOT EXISTS` form in Postgres,
so re-running migration 15 aborts with `42710 policy ... already exists`. Because
the whole file is wrapped in `BEGIN`/`COMMIT` (`15:9`, `15:102`), the entire
migration rolls back — including the `sender_role` column and the trigger.

### S10 — `README.md:138-141` claims a `search_path` hardening that exists in no file
Five functions still lack `SET search_path` (§8.5) and no `ALTER FUNCTION`
statement appears anywhere in 01..19. Re-applying the set silently regresses the
security advisor's `function_search_path_mutable` lint.

### S11 — Zero-UUID sender fallback would violate the `chat_messages.sender_id` FK
`14:59` and `17:59`:
`COALESCE(rec.courier_id, '00000000-0000-0000-0000-000000000000'::uuid)`.
`chat_messages.sender_id` almost certainly FKs `profiles(id)` (that is the only
way `15:19-20` and `15:27` make sense). The fallback is unreachable in practice —
the Pass-2 query filters `status IN ('assigned', ...)` (`17:48`), which implies a
courier is assigned — but if it ever fires, the whole minute's cron transaction
aborts. FK existence is **UNKNOWN**.

### S12 — `report_problem_post_pickup` interpolates unvalidated caller text into a chat message
`17:186-188`:
`'Курьер сообщил о проблеме: ' || p_reason_code || COALESCE(' — ' || p_free_form, '')`.
Unlike its sibling `courier_explain_delay` (whitelist at `17:125`),
`p_reason_code` here is never validated. Combined with `sender_role = 'system'`
(`17:187`), a courier can post arbitrary text into an order's chat that the
consumer app will render as an official system notice.

### S13 — `min_order_amount` comparison is NULL-unsafe
`04:100` (`IF subtotal < r.min_order_amount`) and `04:230`. If
`restaurants.min_order_amount` is NULL, the predicate is NULL, the `IF` takes the
false branch, and the minimum is silently skipped. `04:112-113` then returns
`'min_order_amount': null` and `'min_order_met': null` in the jsonb, which the
Swift `CartValidationResult` decoder must tolerate. Nullability of the column is
**UNKNOWN**.

### S14 — `courier_start_delivering` narrows the SLA reset into two statements
`13:314-333`. The first `UPDATE` sets `status='delivering'` and clears the four
delay/no-show columns; a **second** `UPDATE` (`13:330-333`) then sets
`eta_minutes` and `expected_action_by`. Between them, `compute_eta_minutes` runs
(`13:329`). The row therefore sits briefly in `delivering` with
`expected_action_by` still holding the stale `picked_up` deadline (1 minute,
`13:292`), and the every-minute escalation ladder (`14:35-42`) can observe it and
stamp `courier_no_show_warned_at` spuriously. Narrow race, but real.

### S15 — `06:12` can raise `more than one row returned by a subquery`
`SELECT oid FROM pg_type WHERE typname = 'order_status'` is unqualified by
`typnamespace`. If an `order_status` type exists in more than one schema
(plausible in a Supabase project with both `public` and a legacy schema), the
guard itself errors out. Same shape at `09:9`.

### S16 — Caveat: `ALTER TYPE ... ADD VALUE` inside a `DO` block
`06:9-17` and `09:6-13` run `ALTER TYPE order_status ADD VALUE` inside a
`DO $$ ... $$` block. On Postgres ≥ 12 this is permitted (the restriction that
made it fail inside a transaction block was relaxed), provided the new value is
not *used* before commit — and neither migration uses it at DDL time. Supabase
runs PG 15/17, so this should work. Flagged as a caveat rather than a defect
because it is version-dependent and cannot be confirmed without a live database.

---

## 12. What this migration set does NOT tell us

| unknown | why it matters |
|---|---|
| Whether RLS is enabled on `menu_items`, `menu_categories`, `chat_messages`, `orders`, `profiles`, `addresses`, `courier_locations`, `courier_earnings`, `order_items`, `restaurants` | §S6. Only `courier_cancellation_log` is proven RLS-on (`09:51`) |
| The `order_status` ordinal order for values 2–16 | no `CREATE TYPE`; §3.1 |
| Whether `user_role` contains `merchant` | comment-only evidence (`19:45`); §3.2 |
| Whether `restaurants.restaurant_status` is `text` or an enum | no cast anywhere; §1.5 |
| The full column list of `addresses` | hidden behind `to_jsonb(a.*)` `04:202`; §1.9 |
| The full column list of `restaurants` | hidden behind `SELECT r.*` `03:74` and `SETOF orders` `13:719`; §1.5 |
| Schema of `order_status_history`, `menu_item_modifier_groups`, `modifier_groups`, `modifier_options` | zero references in 01..19; §1.16 |
| Whether `courier_locations.geog` is a generated column | §S8 |
| The names and bodies of the pre-existing triggers `cleanup_cancelled_order`, `create_courier_earning`, and the `generate_verification_code` trigger | §9.2 |
| Whether `chat_messages.sender_id` FKs `profiles(id)` | §S11 |
| The name and cadence of the pre-existing "Batch 1 auto-cancel" cron | `05:45` comment; §5 |
| Nullability of `restaurants.min_order_amount` | §S13 |
| Whether the live DB actually has the `NOT NULL` constraints declared at `11:5-6` and `16:9` | the defensive `COALESCE`s in 13/16 suggest doubt; §1.2 |

Every one of these needs live introspection. Per the orchestrator's verified
finding, **no Ravon Supabase project exists** (`<dead-ravon-project-ref>.supabase.co`
= NXDOMAIN), so none of them is resolvable today. `README.md:3` still directs the
reader to "the Supabase project (`milan` / production)", which does not exist.
