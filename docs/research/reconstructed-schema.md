# The reconstructed schema — reconciliation of three independent sources

Per-column detail lives in the three source documents; this document does the **reconciliation**:
what the sources disagree about, what only one source knows, what is unknowable, and what the
rebuild must therefore decide. Re-typing 265 columns here would add a fourth source to disagree
with.

| Source | Document | What it proves |
|---|---|---|
| **M** migrations | `schema-from-migrations.md` | 1 `CREATE TABLE`; everything else is `ALTER`/reference |
| **S** Swift models | `schema-from-swift-models.md` | 265 wire keys across 14 `CodingKeys` blocks |
| **C** call sites | `schema-from-callsites.md` | projections, filters, embeds, 21 RPC contracts |

**17 tables** are named in the repo: the 15 Swift touches, plus `courier_cancellation_log` (read
through an anonymous struct, and the *only* table with complete DDL) and `order_item_modifiers`
(dead — migration 02 folded it into `order_items.modifiers_snapshot`; the model has zero call
sites anywhere; **do not carry it into the rebuild**).

---

## 1. The drift tool cannot see 14 % of the schema. Fix it before trusting it.

This is the most important finding in this document, because `scripts/schema_drift.py` is one of
the five CI jobs and it is the project's declared gate for exactly this failure class — *"a
mismatch is not a compile error and not a test failure — it is a decode crash in a shipped iOS
app."* It has two independent blind spots, both measured:

### Blind spot 1 — comma-separated `case` lists. 36 of 265 keys dropped.

`SWIFT_CASE = re.compile(r'case\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*(?:=\s*"([^"]+)")?')` captures only
the **first** identifier after `case`. Swift permits several per line, and the models use that
form heavily:

```swift
// Sources/RavonCore/Models/Address.swift:56
case label, street, apartment, city, latitude, longitude
```

The tool sees `label` and silently drops `street`, `apartment`, `city`, `latitude`, `longitude`.

Measured with a corrected parser: the tool parses **229** wire keys; **265** exist. **36 dropped
(13.6 %)**, across seven files:

| File | Dropped |
|---|---|
| `Address.swift` | `street`, `apartment`, `city`, `latitude`, `longitude` (×2 blocks) |
| `CourierLocation.swift` | `longitude`, `heading`, `speed` (×3 blocks) |
| `Restaurant.swift` | `description`, `latitude`, `longitude` (×2) |
| `MenuItem.swift` | `description`, `price` (×2) |
| `CartValidation.swift` | `reason`, `items`, `subtotal` |
| `Order.swift` | `subtotal` |
| `Profile.swift` | `role` |

`Profile.role` and `MenuItem.price` being invisible is the sharp end: `role` is the column behind
the S1 privilege finding, and `price` is money.

### Blind spot 2 — single-word wire keys are unreportable by construction.

`sql_identifiers` is `re.findall(r"\b([a-z][a-z0-9]*(?:_[a-z0-9]+)+)\b", sql)` — the
`(?:_[a-z0-9]+)+` group requires **at least one underscore**, so no single-word column can ever be
in the evidence set. The report line compensates with a `"_" in wire` filter, which means such
keys are *excluded from the output* rather than reported as unverified. Self-consistent, and blind.

After fixing blind spot 1, **8 keys (5 distinct) are single-word AND absent from every migration**:
`street`, `apartment`, `city` (`Address`), `phone` (`Profile`), `rating` (`Restaurant`).
`street` and `city` are non-optional `String` in `Address`, so if either is missing or NULL the
**entire address fetch throws** — Tier 1.

### Consequence

`0 drift, 15 unverified` is a **floor, not a count**. The true unverified set is at least
15 + 5 = 20, and the 36-key parse gap means an unknown number of real mismatches are simply not
examined. Two fixes, both small:

1. Parse comma-separated case lists (split on `,` after `case `, per line, strip comments).
2. Widen `sql_identifiers` to all lowercase tokens and drop the `"_" in wire` filter. The
   docstring already says the filter is "deliberately over-broad… better to under-report" — that
   trade was chosen without knowing it silently excluded a whole syntactic class.

Add a regression test asserting the parser finds 265 keys, so the next comma-list does not
re-open the hole.

---

## 2. Enum inventory — the inventory doc is wrong about four of six

`12-BACKEND-INVENTORY.md` claims six dashboard-created enums: `order_status`, `user_role`,
`courier_status`, `delivery_mode`, `sender_role`, `restaurant_status`. Verified:

| Name | Actually is | Evidence |
|---|---|---|
| `order_status` | **real Postgres enum**, 17 values, no `CREATE TYPE` anywhere | `ALTER TYPE … ADD VALUE` at `06:15`, `09:11`; `v_status order_status` at `13:160` |
| `user_role` | **real Postgres enum**, 3 values | cast `::user_role` at `18:26` |
| `delivery_mode` | **`text` + CHECK**, not an enum | `10:25`, CHECK `10:29-31` |
| `sender_role` | **`text` + CHECK**, not an enum | `15:12`, CHECK `15:15-16` |
| `restaurant_status` | **UNKNOWN** — no cast, no `ALTER TYPE`, no CHECK anywhere | — |
| `courier_status` | **does not exist.** Client-side computed property with zero wire mapping and zero references in any app | `CourierStatus.swift:21-24` |
| *(omitted by the doc)* `courier_earnings.earning_type` | **`text` + CHECK** | `12:18, 12:27` |
| *(omitted)* `orders.cancellation_reason_code` | **`text` + CHECK, 18 values** — and `CancellationReason.swift:8-37` declares the same 18. Exact match, no drift | `09:20-36` |

So only **two** real enums, **four** text+CHECK domains, one unknown, one non-existent. That
matters for the rebuild: a text+CHECK domain is cheap to extend and a Postgres enum is not, and
`CREATE TYPE` statements must be authored for the two real ones because none exists.

---

## 3. Disagreements between the sources

| # | Subject | Conflict | Resolution | Blocks? |
|---|---|---|---|---|
| D1 | `orders` client UPDATE policy | `OrderLifecycle.swift:79-80` asserts *"`orders` carries no client UPDATE policy"*; **C** finds five `SupabaseService` functions moving `orders.status` by direct `.update()` (`:395, :410, :424, :440, :643`), four of them reachable from the merchant UI. | Both cannot be true. Either the comment is wrong or all four merchant operations have always silently failed. The merchant app shows no error on failure (its `mapError` sites are no-ops), so **a silent total failure is consistent with the observed behaviour** and cannot be ruled out from the repo. Irrelevant to the rebuild: the plan grants clients no write access at all. | no |
| D2 | `orders.delivery_address_snapshot` shape | **M**: `to_jsonb(a.*)` over the whole `addresses` row (`04:202`) — 11 fields. **S**: `AddressSnapshot` declares 6. | **M** wins; the column already carries `id`, `user_id`, `is_default`, `default_delivery_mode`, `created_at` beyond the 6. Typing it as the 6-field shape **loses data already being written**. Rebuild as an explicit snapshot type with all 11, or narrow it deliberately and document the loss. | no |
| D3 | `courier_locations.last_updated` | **M**: nullable — `COALESCE(last_updated, now())` at `08:26` proves NULL is possible. **S**: `try c.decode(Date.self, …)` at `CourierLocation.swift:60` — non-optional. | Latent decode crash. **Rebuild `NOT NULL DEFAULT now()`**; that satisfies both. | no |
| D4 | `restaurants.delivery_time_min` | **M**: nullable — `COALESCE(r.delivery_time_min, 30)` at `06:100`. **S**: `try c.decode(Int.self, …)` at `Restaurant.swift:74` — non-optional. | Same shape. **`NOT NULL DEFAULT 30`**. | no |
| D5 | `orders` NOT NULL declarations vs defensive `COALESCE` | **M**: `11:5-6` and `16:9` declare `reassign_count`, `excluded_courier_ids`, `restaurant_delay_min` as `NOT NULL DEFAULT …`. Yet migrations 13/16 `COALESCE` all three six times (`13:544, :675, :543, :700, :730`, `16:108`). | The author was not confident the `NOT NULL` had applied — a signal the live DB had diverged from what 01–19 declare. Harmless now. Rebuild with the declared `NOT NULL DEFAULT` and **drop the `COALESCE`s**, so a NULL becomes a loud failure rather than a silent zero. | no |
| D6 | `restaurants.owner_id` | Referenced by RLS policies at `01:43`, `01:64`, `05:22`, `15:54`, `15:70` and by `fetchMyRestaurant` (`:1132`). **Created by no migration.** `RestaurantInsert` omits it. | Three migrations reference a column their own migration set never creates. Rebuild it as `NOT NULL REFERENCES profiles(id)` declared in `CREATE TABLE` (security R9), so the class of error is impossible. **How existing rows got populated is UNKNOWN.** | no |
| D7 | Offer-feed radius | Cost model 8 km; Swift default 10 km; SQL default 50 km. | Product decision. One number. Asked in the courier prompt. | **yes** |
| D8 | `courier_earnings` `ON CONFLICT` target | `12:96` upserts on conflict but **the conflict target is not written out**. | **UNKNOWN.** Moot — `courier_earnings` is retired in favour of ledger postings. | no |
| D9 | `validate_cart` `PRICE_CHANGED` | **S**: `CartValidation.swift:102-103` requires `old_price`/`new_price` (non-optional decode). **M**: no SQL path emits `PRICE_CHANGED`. | The client can decode a status the server never sends. Either implement it in the rebuild (worth doing — prices change) or delete the case. | no |
| D10 | `orders.estimated_delivery_time` | **S** only, and **fully orphaned**: no SQL, no write site, no reader in any app. | Delete. | no |

**No disagreement blocks the rebuild except D7**, which is a product decision rather than a
reconstruction failure.

---

## 4. Columns with exactly one source — the real risk register

A column proven by one source is a column that may not exist. **S**-only, hard-decoded (absence or
NULL throws and the whole fetch fails):

| Column | Breaks | Tier |
|---|---|---|
| `restaurants.rating`, `.cuisine_type` | consumer restaurant feed, and `.order("rating")` | 1 |
| `addresses.label`, `.street`, `.city`, `.is_default` | address list, and `.order("is_default")` | 1 |
| `menu_items.category_id` | every menu fetch | 1 |
| `modifier_groups.{is_required,min_selections,max_selections}`, `modifier_options.group_id`, `menu_item_modifier_groups.modifier_group_id` | modifier fetch | 1 |
| `order_status_history.{id,order_id,status,created_at}` | order history | 1 |
| **all of** `modifier_groups`, `modifier_options`, `menu_item_modifier_groups` | three tables, **zero** SQL evidence | 1 |
| **all of** `order_status_history` | one table, **zero** SQL evidence | 1 |
| `get_merchant_stats`'s four keys | merchant dashboard | 1 |

Four tables have no SQL evidence whatsoever and exist only because Swift decodes them. They are
not optional — the modifier tables are how the consumer's discarded-modifier feature is supposed
to work, and `order_status_history` is the audit trail the order state machine appends to.

**Unenforced domains** — Swift is stricter than the database, so the DB accepts values the client
cannot decode: `orders.courier_delay_reason_code` (`text`, no CHECK, 5 Swift values),
`courier_earnings.cancellation_reason_code` (no CHECK, unlike its `orders` counterpart's 18-value
CHECK), `courier_earnings.tier_pct` (`int`, no CHECK, domain documented as `0/25/50/100/-100` in
the migration's own comment), `courier_cancellation_log.reason_code` (no CHECK). All become CHECK
constraints in the rebuild (security R8).

**Structural constraints asserted only by Swift**: `restaurant_hours` composite UNIQUE
`(restaurant_id, day_of_week)` — inferred solely from `onConflict:` at `:896`; `courier_locations`
PK/unique on `courier_id` — from `onConflict:` at `:688`, `:731`.

---

## 5. What is unknowable from this repo

Do not let anyone fill these in from memory. The database is gone, so these are permanently
unrecoverable and each needs an explicit decision:

1. **The text of every RLS policy.** No migration creates a policy on `orders`, `profiles`,
   `restaurants`, `addresses`, `courier_locations`, `courier_earnings`, `order_items` or
   `order_status_history`. The security reports quote fragments; those fragments are now the only
   record. **RLS must be designed, not reconstructed** — §6.
2. **Whether `restaurants.owner_id` ever existed** (D6).
3. **The definitions of** `find_nearby_couriers`, `get_merchant_stats`, `add_tip`,
   `auto_cancel_stale_orders`, `create_courier_earning`, `cleanup_cancelled_order`. Referenced,
   never in the repo. (Three have partial specs in `.context/plans/` — see
   `sql-function-catalogue.md` §5b.)
4. **`generate_verification_code`'s trigger binding.** Migration 10 replaces the function body and
   says *"update the existing INSERT trigger function"*, but no migration ever issues
   `CREATE TRIGGER` for it. Name, timing and table are gone.
5. **Whether `ALTER DEFAULT PRIVILEGES … GRANT ALL ON FUNCTIONS TO anon, authenticated` was in
   effect.** Decides how bad S3 actually was — and is exactly why security rule R3 must be a build
   assertion rather than an audit.
6. **Whether `orders.user_id` was `NOT NULL`** — decides whether an anonymous caller could have
   created orders.
7. **`restaurant_status`'s kind** (enum vs text+CHECK) and its value domain.
8. **PostgREST's `max-rows`** — decides where the unbounded `.all` earnings query silently
   truncates.

---

## 6. RLS is designed, not reconstructed

Only four tables have policies in any migration (`menu_items`, `menu_categories`,
`courier_cancellation_log`, `chat_messages`). The other eleven are gone, and **no source in the
repo can recover them** — a Swift call site records what the client *issued*, never what the
server *permitted*. This is a harder gap than the column gap and the brief does not name it.

The good news is that the plan's §10 goal ("no client write policies on `orders`") is therefore
**free**: there is nothing to remove, only something to not create. Same for the security reports'
over-broad `orders` UPDATE policies — they died with the project.

Design rules, from `security-by-construction.md` §7:

- **Grants first, policies second.** A policy is only ever consulted if the table-level `GRANT`
  exists. Clients get **no** `INSERT`/`UPDATE`/`DELETE` on `orders`, `order_items`,
  `order_status_history`, `courier_earnings`, or any ledger table. A future `CREATE POLICY` then
  cannot re-open anything.
- **RLS stays primary for the tables clients still write** — `addresses`, `chat_messages`,
  `profiles` (non-`role` columns). The plan's phrase "RLS becomes defence-in-depth" must be scoped
  to the five Kotlin-written tables **explicitly**, or two existing queries with no ownership
  predicate at all (`SupabaseService.swift:267`, `:1084`) become open endpoints.
- **Tables in `app`, client-readable views in `api`**, PostgREST configured `db-schemas = api`
  only, every view `WITH (security_invoker = true)`. Reachability becomes schema membership — a
  property you cannot forget to revoke.
- **`REPLICA IDENTITY FULL` on `orders`.** `RealtimeService` reads `change.oldRecord["status"]` in
  four places; the default replica identity ships only the primary key, so every `oldStatus`
  silently becomes `nil`. This is an infrastructure precondition recorded nowhere else in the repo.
- Publication `supabase_realtime` must contain exactly five tables: `orders`, `menu_items`,
  `restaurants`, `courier_locations`, `chat_messages`.

---

## 7. What `V1__baseline.sql` has to contain

The single largest unscoped piece of work in the corpus, and neither `10-POLYGLOT-RESTRUCTURE.md`
nor `migrations/README.md` mentions it. A checksummed migration runner needs a `V1` that creates
the world, and only one of 17 tables has DDL today.

1. `CREATE TYPE order_status` (17 values) and `user_role` (3) — no `CREATE TYPE` exists for either.
2. 16 `CREATE TABLE`s (17 minus the dead `order_item_modifiers`), with money as `bigint` minor
   units, `total_minor` as `GENERATED ALWAYS AS … STORED`, and the domain CHECKs from §4.
3. The four text+CHECK domains, plus the 18-value `cancellation_reason_code` CHECK.
4. Foreign keys — including the ones only provable from PostgREST embedded-resource syntax in the
   call sites.
5. Indexes implied by the call-site filter/order patterns.
6. `app.order_transitions` seeded with the reconciled 41 edges (plan §3.1), and
   `app.order_transition(...)` as the sole writer of `orders.status`.
7. The grant baseline: `REVOKE EXECUTE ON ALL FUNCTIONS … FROM PUBLIC, anon, authenticated` plus
   `ALTER DEFAULT PRIVILEGES … REVOKE EXECUTE`, then a checked-in allowlist.
8. RLS per §6, `REPLICA IDENTITY FULL` on `orders`, the realtime publication.
9. `schema/invariants.sql` — one assertion per security rule, run by the new `db-invariants` job.

The exit criterion for Phase 2 is a live introspection run — but **only after the drift tool is
fixed (§1)**, or "0 unverified" means only that the tool looked at 86 % of the schema.
