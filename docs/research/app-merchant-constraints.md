# Merchant app — constraints on a Kotlin backend extraction

**Source of record:** `/Users/mmarufov/conductor/workspaces/ravon-merchant/milan`
(branch `mmarufov/milan-v1`, HEAD `d0842d6`).
**Input brief:** `/Users/mmarufov/conductor/workspaces/ravon-merchant/milan/.context/STATE-REPORT.md` (23 KB, 2026-09-15).
**Builds on:** `.context/research/schema-from-callsites.md` §5, `.context/research/order-lifecycle-spec.md` §5–§7,
`.context/research/sql-function-catalogue.md` §6, `.context/research/app-courier-constraints.md` §6.

**HEAD is not clean.** The STATE-REPORT says "clean at `d0842d6`". It is not: 10 files are
modified in the working tree — the `сум` → `сомони` currency change described in its §0 was
never committed.

```
 M RavonMerchant/RavonMerchant/Views/DashboardView.swift
 M RavonMerchant/RavonMerchant/Views/MenuItemCreateView.swift
 M RavonMerchant/RavonMerchant/Views/MenuItemEditView.swift
 M RavonMerchant/RavonMerchant/Views/MenuView.swift
 M RavonMerchant/RavonMerchant/Views/ModifierGroupsView.swift
 M RavonMerchant/RavonMerchant/Views/Onboarding/OnboardingView.swift
 M RavonMerchant/RavonMerchant/Views/OrderDetailView.swift
 M RavonMerchant/RavonMerchant/Views/OrdersView.swift
 M RavonMerchant/RavonMerchant/Views/RestaurantEditView.swift
 M RavonMerchant/RavonMerchant/Views/SettingsView.swift
```

All line numbers in this document are against the **working tree**, which is what a
port would read. 22 Swift files, 5 ViewModels, 16 Views + `ContentView` + `RavonMerchantApp`.

### `supabase/` directory — contents

One file, 1,636 bytes:
`/Users/mmarufov/conductor/workspaces/ravon-merchant/milan/supabase/migrations/20260503051636_restaurants_non_null_defaults.sql`

It is a **backfill + NOT NULL lockdown on `public.restaurants`** and nothing else. No
functions, no RLS, no grants. It sets defaults (`rating=0`, `is_accepting_orders=true`,
`restaurant_status='draft'`), coalesces NULLs on 7 columns, then `SET NOT NULL` on
`rating, is_accepting_orders, restaurant_status, cuisine_type, delivery_time_min,
delivery_fee, min_order_amount`. Its header comment records *why*: a NULL `rating` /
`is_accepting_orders` / `restaurant_status` made the **consumer** fail decoding
`Restaurant` with "ошибка загрузки".

**This file is not in `ravon-core/.context/migrations/` (01–19).** It is a 20th migration
living in a different repo, and it is the only `CREATE`-adjacent DDL any app repo owns.
Two consequences for the extraction:

1. The Kotlin schema must carry these 7 NOT NULL constraints and 3 defaults, or the
   consumer's non-optional decode breaks again. `.context/research/schema-from-migrations.md`
   reconstructs from 01–19 only and will be missing them.
2. Migration numbering is contended: this file timestamps `20260503051636` while core uses
   `01_`–`19_`. Pick one scheme before writing migration 20.

---

## 1. LOUD CORRECTIONS

Nine findings that change the plan, most consequential first.

### C1 — §4 is not a live contract. All six error strings are DEAD CODE. Proven.

This is the single most important correction in this document, because §4 is presented as
"the contract for the typed errors" and it describes behaviour that cannot occur.

`ServiceError` is declared `public enum ServiceError: LocalizedError`
(`Sources/RavonCore/Services/SupabaseService.swift:4`) with an `errorDescription`
(`:40-84`) that returns **Russian display strings**. Swift bridges `LocalizedError` such
that `Error.localizedDescription` returns `errorDescription`. Therefore:

| `ServiceError` case | `error.localizedDescription` | contains the case name? |
|---|---|---|
| `.merchantAlreadyHasRestaurant` (`:55`) | `У вас уже есть ресторан` | **no** |
| `.imageTooLarge` (`:57`) | `Изображение слишком большое (макс. 5 МБ)` | **no** |
| `.unsupportedImageFormat` (`:58`) | `Неподдерживаемый формат изображения` | **no** |
| `.categoryNotEmpty` (`:59`) | `Удалите все блюда из категории перед удалением` | **no** |
| `.onboardingIncomplete` (`:56`) | `Заполните все данные перед открытием` | **no** |
| `.invalidStatusTransition` (`:45`) | `Недопустимый переход статуса` | **no** |

Measured, not reasoned — a standalone reproduction of the exact pattern:

```
localizedDescription = У вас уже есть ресторан
  contains("merchantAlreadyHasRestaurant") = false
  contains("already")                      = false
localizedDescription = Изображение слишком большое (макс. 5 МБ)
  contains("imageTooLarge")                = false
localizedDescription = Недопустимый переход статуса
  contains("invalidStatusTransition")      = false
```

Every one of the merchant's six matches reads `let desc = error.localizedDescription`
first (`MenuViewModel.swift:333`, `SettingsViewModel.swift:158`,
`OnboardingViewModel.swift:261`, and the control-flow copy at `OnboardingViewModel.swift:58`).
**None of the six branches has ever been taken for a `ServiceError`.** Every one of the 19
`mapError` call sites falls through to `return desc`.

Three follow-on facts:

1. **The UX is accidentally fine for five of the six**, because the fallthrough returns
   core's Russian `errorDescription`. The merchant sees Russian text — just core's wording
   rather than the merchant's. So the STATE-REPORT's §4 table is not a contract to
   *preserve*; it is a list of **wordings that have never shipped**. Treat it as a wishlist,
   not a compatibility constraint. The authoritative Russian strings are
   `SupabaseService.swift:42-83`.

2. **The one branch that is load-bearing is broken, and §1 of the STATE-REPORT gets it
   backwards.** §1 says a transient failure showing the blank onboarding wizard is
   "partially caught later by the `merchantAlreadyHasRestaurant` branch at
   `OnboardingViewModel.swift:58`, which refetches and resumes". That branch
   (`OnboardingViewModel.swift:59`) is:
   ```swift
   if desc.contains("merchantAlreadyHasRestaurant") || desc.contains("already") {
       if let existing = try? await SupabaseService.shared.fetchMyRestaurant() {
           await resumeOnboarding(for: existing)
       }
   } else { errorMessage = mapError(error) }
   ```
   The **only** producer of that condition is `SupabaseService.createRestaurant`'s
   client-side pre-check at `SupabaseService.swift:1113-1116`
   (`if let _ = try await fetchMyRestaurant() { throw .merchantAlreadyHasRestaurant }`),
   whose `localizedDescription` is `У вас уже есть ресторан`. The branch is
   **unreachable**. There is no partial catch. The wizard never auto-resumes on conflict.

3. **The `contains("already")` hazard the report ranks as "kill it first" is not the
   hazard it thinks.** It cannot fire on a typed error at all. It can only fire on a raw
   `PostgrestError` whose `localizedDescription` happens to contain the ASCII substring
   `already` — and since every user-facing message in this stack is Cyrillic, the realistic
   trigger is a Postgres/PostgREST English message. It is still wrong, but it is a
   latent false-positive, not an active misroute.

**What this means for the extraction:** do not budget effort on "preserving the six
wordings". Budget it on the fact that **the merchant app has no working error taxonomy at
all today** — 19 `mapError` sites that are no-ops plus 31 raw sites. The typed-error work
is greenfield, which is *easier* than the report implies, and it means you may pick
wordings freely.

### C2 — money truncation is a WRITE path. Every edit-and-save destroys stored cents.

The STATE-REPORT frames `Int(x)` as a *rendering* choice ("a 2dp formatter would render
precision the merchant has no way to author"). It is worse than that: the same truncation
seeds the **edit fields**, and those fields are sent back unconditionally.

Three verified round-trips:

| load (truncates) | save (sends) | core write | column |
|---|---|---|---|
| `MenuItemEditView.swift:27` `_price = State(initialValue: String(Int(item.price)))` | `:135` `price: Double(price) ?? item.price` | `SupabaseService.swift:994` `updates["price"] = .double(price)` | `menu_items.price` |
| `ModifierGroupsView.swift:109` `editOptionPrice = String(Int(option.priceAdjustment))` | `:321` `priceAdjustment: Double(editOptionPrice)` | `SupabaseService.swift:1357` `updates["price_adjustment"]` | `modifier_options.price_adjustment` |
| `RestaurantEditView.swift:30-31` `String(Int(restaurant.minOrderAmount))` / `String(Int(restaurant.deliveryFee))` | `:146-147` `Double(deliveryFee)` / `Double(minOrderAmount)` | `SupabaseService.swift:1023-1024` | `restaurants.delivery_fee`, `restaurants.min_order_amount` |

Failure scenario, fully concrete: a menu item is stored at `99.50`. The merchant opens
"Редактировать блюдо" to toggle `isAvailable`, does **not** touch the price field, taps
"Сохранить". The field was seeded `"99"`; `Double("99") = 99.0`; core's
`if let price { updates["price"] = .double(price) }` fires because 99.0 is non-nil;
the row becomes `99.00`. The 50 dirham is gone, silently, and the `.numberPad` keyboard
(no decimal separator, 15 sites, zero `.decimalPad`) means the merchant **cannot type it
back**.

This is the strongest argument in this document for **integer minor units on the wire**.
It is not a formatting preference; it is silent data loss on a path the merchant uses daily.

A fourth, non-money instance of the same "optional means don't change" trap:
`MenuItemEditView.swift:138` sends `stockCount: isUnlimitedStock ? nil : Int(stockCount)`,
and core's `if let stockCount` (`SupabaseService.swift:996`) **skips** the field on nil.
So switching an item from limited to unlimited stock is a no-op — the old `stock_count`
persists. Any Kotlin `UpdateMenuItem` message needs explicit
presence-vs-null (`optional` / `FieldMask` / a `clear_stock_count` bool), not
"absent = unchanged".

### C3 — §5b is half wrong: there is only ONE accepting-orders API and ONE RPC.

§5b: "Two core methods for one concept, and the merchant app hits both from different
screens — so the same toggle behaves differently depending on where the merchant touches
it (only one supports the `until` snooze)."

`toggleAcceptingOrders` is a **six-line forwarding wrapper**:

```swift
// SupabaseService.swift:1034-1036
public func toggleAcceptingOrders(restaurantId: UUID, accepting: Bool) async throws {
    try await setAcceptingOrders(restaurantId: restaurantId, accepting: accepting, until: nil)
}
```

Both paths land on the same RPC `set_accepting_orders(p_restaurant_id, p_accepting, p_until)`
(`SupabaseService.swift:1042-1051`, defined in `.context/migrations/05_set_accepting_orders_with_until.sql`).
The behaviour is **identical** for identical inputs; the Settings screen simply never
offers a non-nil `until`. There is nothing to "collapse" server-side — the Kotlin
extraction implements exactly one RPC and deletes one Swift alias. This shrinks the §5b
item from a design decision to a one-line deprecation.

### C4 — `.numberPad` is 15 sites, not 16. Zero `.decimalPad`.

`ModifierGroupsView.swift:231, 310`; `RestaurantEditView.swift:102, 110, 118, 126`;
`MenuItemEditView.swift:94, 110, 122`; `MenuItemCreateView.swift:65, 77`;
`OnboardingView.swift:106, 112, 120, 404`. Of the 15, **10 are money** and 5 are non-money
(`deliveryTimeMin`, `maxConcurrentOrders`, `sortOrder`, `stockCount` ×2). `.decimalPad`:
zero occurrences in the app.

### C5 — §3's list of merchant-reached core read lines is wrong.

§3 correctly enumerates core's 12 `from("orders"/"order_items"/"order_status_history")`
sites — verified exactly: **276, 284, 293, 305, 394, 409, 423, 439, 590, 642, 774, 813**.
But it then claims the merchant reaches "394/409/423/439 (your four) plus reads at
276/284/293/305/813".

The merchant reaches **305 only** (`fetchOrdersForRestaurant`). It has zero call sites for
`fetchOrders` (:276), `fetchOrder` (:284), `fetchOrderStatusHistory` (:293), and
:813 is `fetchActiveOrderForCourier` — courier-only. Verified: the three `fetchOrders`
grep hits in the merchant app are all `vm.fetchOrders` (the ViewModel's own method), not
`SupabaseService.fetchOrders`.

The report's parenthetical "Merchant never touches `order_items` or `order_status_history`
except through `fetchOrderStatusHistory`" is doubly wrong: it never calls
`fetchOrderStatusHistory`, and it *does* read `order_items` — through the embedded join in
`fetchOrdersForRestaurant`, `select("*, order_items(*)")` (`SupabaseService.swift:306`).

Net effect on the extraction: the merchant's **entire** `orders` read surface is one query.
That is a *smaller* target than the report suggests and it is trivially projectable.

### C6 — a 23rd money render site, in roubles, missed by §0.

§0: "All 22 occurrences of `сум` → `сомони`. Verified 0 remaining, 22 present… No `TJS`,
`somoni`, or symbol forms exist anywhere in the app."

The 22 `сомони` sites are confirmed exactly (13 value + 9 label; full enumeration in §7).
But there is a 23rd money render that was never `сум` and so escaped the sweep:

```swift
// Views/OrdersView.swift:176 — OrderRowView.cancelledByCourierHeader
Text("[CANCELLED] Заказ #\(order.id.uuidString.prefix(6).uppercased()) · \(Int(order.total)) ₽")
```

`₽` (U+20BD, rouble). It is on the `cancelled_by_courier` header — one of the two terminal
states the merchant queue deliberately surfaces, i.e. a path the merchant *will* see. The
`[CANCELLED]` ASCII prefix is also untranslated debug scaffolding in a Cyrillic UI.

`₽` count in the app: 1. The rouble also survives core-side at
`SupabaseService.swift:60` (`.minOrderNotMet` → `"Минимальная сумма заказа: \(Int(need)) ₽"`),
already flagged by the courier doc.

### C7 — §6's prescription is already done, and the fleet has THREE versions, not two.

§6's git-history table is **confirmed byte-for-byte** (re-read from each commit's tracked
`Package.resolved`):

| commit | supabase-swift |
|---|---|
| `076f76d` (#1) | 2.41.1 |
| `71579a8` (#2) | 2.43.0 |
| `61712b1` (#4) | 2.43.1 |
| `d0842d6` (#5) | 2.43.1 |

Two corrections to the conclusion:

1. **`Package.resolved` is already tracked in all three apps and in core.**
   `git ls-files` finds
   `RavonMerchant/RavonMerchant.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
   in merchant, the equivalents in consumer and courier, and `Package.resolved` at the root
   of ravon-core (pinning **2.41.1**). §6's fix — "commit `Package.resolved`, so this can't
   drift again" — is already in effect **and did not prevent the drift**, because each app
   owns its own lockfile and SPM ignores a *library* package's `Package.resolved` when that
   library is consumed as a dependency. The only mechanism that can actually pin the fleet
   is tightening core's `Package.swift:11` from `from: "2.41.0"` to `.upToNextMinor` or an
   exact `"2.43.1"..<"2.44.0"` range.
2. **Three live versions, not "merchant drifted away from consumer".**

| app | ravon-core pin | supabase-swift |
|---|---|---|
| consumer (`kolkata`) | branch `mmarufov/auth-overhaul` @ `a1e9d6c8…` | **2.41.1** |
| courier (`buffalo`) | branch `mmarufov/auth-overhaul` @ `a1e9d6c8…` | **2.42.0** |
| merchant (`milan`) | branch `mmarufov/auth-overhaul` @ `a1e9d6c8…` | **2.43.1** |
| ravon-core (own lockfile, ignored downstream) | — | 2.41.1 |

The merchant's claim "Merchant *started* on 2.41.1 — same as consumer" is right. It did not
know courier sits at a third value. §6's operative conclusion survives intact and is the
right one: **merchant imposes zero constraint** (see §9 — 0 `import Supabase`), so pick
whatever consumer and courier need.

Merchant SPM pin, verified in `project.pbxproj:365-370`: `kind = branch`,
`branch = "mmarufov/auth-overhaul"`, `repositoryURL = https://github.com/mmarufov/ravon-core.git`,
resolved revision `a1e9d6c814436c82dd93388158768e6720c2b18e`. `IPHONEOS_DEPLOYMENT_TARGET = 26.2`
(`pbxproj:276, 320`). No entitlements file, no `Info.plist`, no `INFOPLIST_KEY_UIBackgroundModes`.

### C8 — the reimplemented hours logic diverges from the server in TWO ways, not one.

§5a identifies the past-midnight bug correctly (see §10). It misses a second divergence on
the *missing-row* default, which flips the answer in the opposite direction:

| condition | server `restaurant_within_hours` | merchant `isWithinHours` |
|---|---|---|
| no rows at all | `true` (no row for today → open, `03_…:33-35`) | `true` (`DashboardViewModel.swift:135`) |
| **rows exist, none for today's DOW** | **`true`** (`03_…:33-35`) | **`false`** (`DashboardViewModel.swift:137` `guard let today … else { return false }`) |
| `is_closed = true` | `false` (`:37-39`) | `false` (`:138`) |
| `opening == closing` | `false`, explicit marker (`:41-43`) | `false`, by arithmetic |
| normal window | `time >= open AND time <= close` (`:45-46`) | `open <= now AND now < close` — **`<` vs `<=`** |
| past-midnight | `time >= open OR time <= close` (`:48-50`) | always `false` — **the §5a bug** |

So a restaurant with hours for Mon–Fri only shows "Сейчас закрыто по расписанию" on
Saturday in the merchant dashboard while the server happily accepts Saturday orders.
The closing boundary also disagrees by one second.

### C9 — this document closes an UNKNOWN in `order-lifecycle-spec.md` §7.

`order-lifecycle-spec.md` §7 records: *"The header comment (`OrderLifecycle.swift:106`) says
'merchant currently calls the consumer's cancel RPC'; I could not verify that from the
merchant app source (the `ravon-merchant` checkout at `/Users/mmarufov/conductor/repos/ravon-merchant`
contains only 2 Swift files and no cancel call site) … **UNKNOWN — needs the full merchant
app source.**"*

**Resolved: CONFIRMED.** Full source is at
`/Users/mmarufov/conductor/workspaces/ravon-merchant/milan` (22 Swift files). The call
chain is verified end to end in §4 below. `OrderLifecycle.swift:106` is correct.

### C10 — line-number drift in the STATE-REPORT (minor, listed for the porter)

| §  | report says | actual |
|---|---|---|
| 2a | `isActiveOrSurfacedTerminal` at `OrdersViewModel.swift:45` | `:46` |
| 3  | actions at `OrdersViewModel.swift:118/128/138` | funcs at `:122/131/140`; the core calls at `:124/133/144,146` |
| 3  | silent refetch at `OrdersViewModel.swift:114` | `:116` |
| 2e / 3 | sheets dismiss at `OrderDetailView.swift:473, 504, 536` | those are the *call* lines; dismissals at `:474, 505-506, 537-538` |
| 1 / 4 | resume control flow at `OnboardingViewModel.swift:58` | `:59` (`:58` is `let desc = …`) |
| 2f | `linkModifierToItem` / `unlinkModifierFromItem` at `MenuViewModel.swift:314/322` | methods are named `linkModifierGroup` / `unlinkModifierGroup`, at `:316/324` |
| 5a | hours logic at `DashboardViewModel.swift:120-152` | `:120` is the `// MARK:`; the three functions are `:123`, `:134-140`, `:143-157` |
| 4 | "5 alert sites … Dashboard, Menu, ModifierGroups, Settings, Onboarding" | **6**: it misses `MenuItemCreateView.swift:97` (also bound to `MenuViewModel.errorMessage`) |
| 4 | "50 catch blocks" | **54** total; **50** assign `errorMessage`. The 31/19 split is exact. |

Everything else I spot-checked in the STATE-REPORT is accurate, including the harder
claims: the 12 core order-table line numbers, the 31-raw/19-mapped split and its full
per-ViewModel breakdown (Onboarding 10/0, Settings 5/5, Menu 4/16, Dashboard 0/4,
Orders 0/6), the `hasNewOrderAlert` dead-state diagnosis, zero `import Supabase`, and the
four-commit SDK drift table. It is a high-quality report; the corrections above are about
its *conclusions*, not its diligence.

---

## 2. The four merchant order actions — the error contract the 4 new RPCs must satisfy

### 2.1 Exact call chain, verified

| # | UI trigger | VM method | core method | write |
|---|---|---|---|---|
| 1 | `OrderDetailView.swift:471-476` acceptSheet → `:473` | `OrdersViewModel.acceptOrder` `:122-129` → `:124` | `SupabaseService.acceptOrder` `:393-406` | `UPDATE orders SET status='accepted', estimated_prep_time, accepted_at` |
| 2 | `OrderDetailView.swift:502-508` rejectSheet → `:504` | `OrdersViewModel.rejectOrder` `:131-138` → `:133` | `SupabaseService.rejectOrder` `:419-436` | `UPDATE orders SET status='rejected', cancellation_reason, cancelled_by, rejected_at` |
| 3 | `OrderDetailView.swift:422-424` "Начать готовить" | `OrdersViewModel.advanceOrder(.accepted)` `:140-154` → `:144` | `SupabaseService.startPreparing` `:408-417` | `UPDATE orders SET status='preparing'` |
| 4 | `OrderDetailView.swift:430-432` "Готово" | `OrdersViewModel.advanceOrder(.preparing)` `:140-154` → `:146` | `SupabaseService.markOrderReady` `:438-449` | `UPDATE orders SET status='ready'` |
| 5 | `OrderDetailView.swift:534-540` cancelSheet → `:536` | `OrdersViewModel.cancelOrder` `:156-163` → `:158` | `SupabaseService.cancelOrder` `:632-639` | RPC `cancel_order_by_consumer` — **wrong actor**, see §4 |

`advanceOrder` is one method with a `switch currentStatus` (`:142-149`) and a
`default: return` — so tapping advance on any other status is a silent no-op with no
refetch.

### 2.2 The empty-result CAS idiom, verbatim

All four use the identical shape. `acceptOrder` in full (`SupabaseService.swift:393-406`):

```swift
public func acceptOrder(orderId: UUID, estimatedPrepMinutes: Int) async throws {
    let results: [IdRow] = try await client.from("orders")
        .update([
            "status": AnyJSON.string(OrderStatus.accepted.rawValue),
            "estimated_prep_time": AnyJSON.integer(estimatedPrepMinutes),
            "accepted_at": AnyJSON.string(Self.isoFormatter.string(from: Date())),
        ])
        .eq("id", value: orderId.uuidString)
        .eq("status", value: OrderStatus.created.rawValue)   // <- the compare
        .select("id")                                        // <- the swap's receipt
        .execute()
        .value
    guard !results.isEmpty else { throw ServiceError.invalidStatusTransition }
}
```

`IdRow` is `private struct IdRow: Decodable { let id: UUID }` (`SupabaseService.swift:138`).

Guard predicates, exact:

| method | line | predicate | on empty |
|---|---|---|---|
| `acceptOrder` | `:401-402` | `id = ? AND status = 'created'` | `throw .invalidStatusTransition` (`:405`) |
| `startPreparing` | `:412-413` | `id = ? AND status = 'accepted'` | `throw .invalidStatusTransition` (`:416`) |
| `rejectOrder` | `:430-431` | `id = ? AND status = 'created'` | `throw .invalidStatusTransition` (`:435`) |
| `markOrderReady` | `:442-443` | `id = ? AND status IN ('accepted','preparing')` | `throw .invalidStatusTransition` (`:448`) |

The idiom is **correct** optimistic concurrency: the `status` equality is the compare, the
`RETURNING id` row count is the swap receipt. `rejectOrder` additionally does
`guard let uid = AuthService.shared.userId else { throw .notAuthenticated }` (`:420-422`)
and stamps `cancelled_by = uid` **client-side** — the only one of the four that writes an
actor attribution, and it trusts the client for it.

**The information loss that matters:** all four collapse *every* failure into the single
value `.invalidStatusTransition`. The client cannot distinguish:

- the order moved to a state outside the from-set (a real invalid transition)
- the order was claimed/cancelled by someone else mid-flight (a race the merchant should retry or be told about specifically)
- the order id does not exist (`ORDER_NOT_FOUND`)
- the caller does not own the restaurant (`UNAUTHORIZED`) — **note: today there is no ownership check at all, client or server; see §2.5**

An RPC that raises with structured `DETAIL` recovers all four. That is the whole point of
doing the RPCs.

### 2.3 What the merchant UI does on failure: nothing. Verified three ways.

1. **`OrdersViewModel.errorMessage` is rendered nowhere.** `grep -n errorMessage` over
   `Views/OrdersView.swift` and `Views/OrderDetailView.swift` returns **zero** hits. The
   six `.alert("Ошибка", …)` sites in the app are `DashboardView.swift:55`,
   `SettingsView.swift:166`, `ModifierGroupsView.swift:174`, `MenuItemCreateView.swift:97`,
   `MenuView.swift:76`, `OnboardingView.swift:41`. None of them is in the Orders tree, and
   `OrdersViewModel` is never handed to any of them.
2. **Sheets dismiss unconditionally, on the same `Task` line, after the `await`.**
   `OrderDetailView.swift:472-475` / `:503-507` / `:535-539`. There is no
   `if vm.errorMessage == nil` guard — contrast `ModifierGroupsView.swift:326-328`, which
   *does* guard (`if vm.errorMessage == nil { editingOption = nil }`). The Orders sheets do not.
3. **The refetch also swallows.** `OrdersViewModel.fetchOrders(silent:)` is called with
   `silent: true` from all four actions, and `:116` is
   `if !silent { errorMessage = error.localizedDescription }` — so a successful mutation
   followed by a failed refetch leaves a stale row with no signal.

Net today: **tap Accept → it fails → sheet closes → list refetches → order is still
`created` → merchant is told nothing.** No toast, no retry, no log. `hasNewOrderAlert`
(declared `OrdersViewModel.swift:14`, written `:113`) is likewise read nowhere — confirmed
dead.

**Implication for the RPC design, and it is not the one §3 asks for.** §3 asks for a
dedicated `CONCURRENT_CLAIM` / `LOCK_CONTENDED` code so the client can retry rather than
scold. That is reasonable, but it is worth being precise about what races actually exist
here, because it changes whether the code is worth minting (see §2.5). The
harder constraint is this: **any error the server emits on these four paths is dropped on
the floor by the current client**, so the server must not *rely* on the client to present
it. Prefer server-side resolution (retry inside the RPC, idempotent re-application) over
new error codes wherever the semantics allow.

### 2.4 The four RPCs, specified

Naming is fixed by `OrderLifecycle.swift:113-117` and pinned by
`Tests/RavonCoreTests/OrderLifecycleInvariantTests.swift:215-217` — the test suite
hard-codes exactly these five as `knownMissing` and asserts set equality, so renaming
breaks a test.

Shared contract for all four:

- **Signature** returns the order id (`uuid`) or `void`. §3 is explicit and I confirm it
  from source: the VM ignores every return value and calls `fetchOrders(silent: true)`
  (`OrdersViewModel.swift:125, 134, 150`). Nothing in the merchant app reads a mutation
  response. **Do not widen these to return the row.** (§3's aside that it would save a
  round-trip on Tajik mobile data is fair but it is a client-perf change, not a contract
  change — it can be added later without breaking anyone, because nobody reads the value.)
- **Authorization:** `auth.uid()` must own the restaurant the order belongs to. There is
  **no such check anywhere today** — not in the client (`acceptOrder` takes only
  `orderId`), not in SQL (no policy on `orders` in any migration). Failure → `UNAUTHORIZED`.
  This is new security, not a port of existing security.
- **Locking:** `SELECT … FROM orders WHERE id = p_order_id FOR UPDATE`, matching the
  established pattern in `13_courier_status_transition_rpcs_v2.sql` (`:271`, `:444`) and
  `16_no_show_and_restaurant_delay.sql:97`.
- **Error style:** `RAISE EXCEPTION '<snake_case>' USING ERRCODE='P0001',
  DETAIL=jsonb_build_object('reason','<KIND>', 'status', v_status)::text` — 61 of the 63
  existing `RAISE` sites use exactly this (`sql-function-catalogue.md` §6).

| RPC | params | from-states | to-state | extra columns | errors (ordered) |
|---|---|---|---|---|---|
| `merchant_accept_order` | `p_order_id uuid, p_estimated_prep_minutes int` | `created` | `accepted` | `estimated_prep_time`, `accepted_at = now()` | `ORDER_NOT_FOUND`, `UNAUTHORIZED`, `INVALID_STATUS_TRANSITION`(+`status`), `INVALID_PREP_MINUTES` |
| `merchant_reject_order` | `p_order_id uuid, p_reason text` | `created` | `rejected` | `cancellation_reason = p_reason`, `cancellation_reason_code = 'RESTAURANT_REJECTED'`, `cancelled_by = auth.uid()`, `rejected_at = now()` | `ORDER_NOT_FOUND`, `UNAUTHORIZED`, `INVALID_STATUS_TRANSITION`(+`status`) |
| `merchant_start_preparing` | `p_order_id uuid` | `accepted` | `preparing` | — | `ORDER_NOT_FOUND`, `UNAUTHORIZED`, `INVALID_STATUS_TRANSITION`(+`status`) |
| `merchant_mark_order_ready` | `p_order_id uuid` | `accepted`, `preparing` | `ready` | — | `ORDER_NOT_FOUND`, `UNAUTHORIZED`, `INVALID_STATUS_TRANSITION`(+`status`) |

Four notes the porter needs:

1. **`p_estimated_prep_minutes` has a client-side domain the server does not know about.**
   `OrderDetailView.swift:466` is `Stepper(value: $estimatedMinutes, in: 5...120, step: 5)`
   with `@State private var estimatedMinutes = 20` (`:13`). So the client can only send
   `{5,10,…,120}`. Either enforce `5 <= p <= 120` server-side (and mint
   `INVALID_PREP_MINUTES`) or document that the column is unvalidated. Precedent exists:
   `courier_report_restaurant_delay` validates `p_extra_minutes` with `INVALID_EXTRA_MINUTES`
   (`16_…:93-96`).

2. **`p_reason` on reject is free text, not a code.** `OrderDetailView.swift:498` is a
   `TextField("Например: закрыты, нет ингредиентов...", text: $rejectReason, axis: .vertical)`
   with no validation and no minimum length — an empty string is submittable
   (`RavonPrimaryButton` at `:502` has no `.disabled`). Meanwhile
   `orders.cancellation_reason_code` has a 17-value CHECK whitelist
   (`09_…:20-35`) with `'RESTAURANT_REJECTED'` sitting unused. Today `rejectOrder` writes
   `cancellation_reason` (free text) and **never** writes `cancellation_reason_code`, so
   rejected orders carry no machine-readable reason. The RPC should stamp
   `'RESTAURANT_REJECTED'` and keep `p_reason` as the free-text note. Better still: promote
   the sheet to a picker over `RESTAURANT_CLOSED` / `RESTAURANT_OUT_OF_ITEMS` /
   `RESTAURANT_REJECTED` (all three already whitelisted, all three already have Russian
   display names at `CancellationReason.swift:59-61`).

3. **`cancelled_by` must move server-side.** Today `rejectOrder` stamps it from
   `AuthService.shared.userId` (`SupabaseService.swift:419-433`). In the RPC it is
   `auth.uid()`, and the client-supplied value must be rejected, not trusted.

4. **`rejected` is a terminal state with no consumer-visible producer today.** Cross-check
   confirmed in `order-lifecycle-spec.md` §7: **no migration ever writes `'accepted'`,
   `'preparing'`, or `'rejected'`.** These three statuses have no server-side producer at
   all. So these four RPCs are not a refactor of existing SQL — they are the first
   server-side code that ever produces three of the 17 statuses.

### 2.5 On `CONCURRENT_CLAIM` — which races are real, and my recommendation

§3 asks for (1) a lock-contention code distinguishable from a genuine invalid transition
and (2) ideally a short `NOWAIT` retry inside the RPC. Worth separating two different things:

**Row-lock contention** (two writers on the same row, one waits on `FOR UPDATE`). With
`FOR UPDATE` and no `NOWAIT`, the second writer *blocks and then proceeds* — it does not
error. It only errors if you opt into `NOWAIT`/`SKIP LOCKED` or hit `lock_timeout` /
`statement_timeout` (Supabase's PostgREST default `statement_timeout` applies). So a
`LOCK_CONTENDED` code only exists if you create it. **Recommendation: don't.** Plain
`FOR UPDATE` serialises correctly; the second transaction re-reads the fresh status and
then either succeeds or raises a semantically accurate error.

**Lost-update races** (the second writer finds the status already moved). These are real
and enumerable for the merchant's four edges. Who can move an order out from under the
merchant, per the reconciled 41-edge graph:

| merchant is at | who else can move it | resulting status | merchant sees today |
|---|---|---|---|
| `created` (about to accept) | consumer `cancel_order_by_consumer` (`13_…:457` allows `created`) | `cancelled_by_customer` | `.invalidStatusTransition` |
| `created` | system `activate_scheduled_orders` / escalation | `cancelled_by_system` | `.invalidStatusTransition` |
| `accepted`/`preparing` (about to advance) | courier `claim_order` | `assigned` | `.invalidStatusTransition` |
| `accepted`/`preparing`/`ready` | consumer cancel, courier cancel, `RESTAURANT_TOO_LONG_WAIT` auto-cancel (`16_…:109-120`) | `cancelled_by_*` | `.invalidStatusTransition` |

Note `claim_order` allows a courier to claim from `accepted` and `preparing`, **not just
`ready`** — so "courier claimed while I was still cooking" is the single most likely race
and it is completely benign: `assigned` does not block `merchant_mark_order_ready`
semantically (the kitchen still finishes the food). Today it *does* block it, because
`markOrderReady`'s predicate is `status IN ('accepted','preparing')` and `assigned` is
excluded.

**So the highest-value fix is not a new error code — it is widening the from-set.**
`merchant_mark_order_ready` should accept `{accepted, preparing, assigned,
courier_arrived_restaurant}`. That makes the common race succeed instead of failing, which
matters precisely *because* the client drops errors (§2.3). This also aligns with
`OrderLifecycle`'s merchant-visible set (§5.2), which includes `assigned` and
`courier_arrived_restaurant`.

**What the client genuinely cannot do without a new distinction** is tell "you're too late,
the order is gone" from "you're too late, someone else did your job". So mint **one** code,
not two, and make it carry the payload:

```
RAISE EXCEPTION 'order_already_terminal'
  USING ERRCODE='P0001',
        DETAIL=jsonb_build_object('reason','ORDER_ALREADY_TERMINAL',
                                  'status', v_status,
                                  'cancellation_reason_code', v_reason_code)::text;
```

`ORDER_ALREADY_TERMINAL` already exists (kind #16 of the 29, emitted by
`cancel_order_by_consumer` `13_…:458-459`, decoded by
`ServiceError.from(serverError:)` at `SupabaseService.swift:121`) — reuse it rather than
minting `CONCURRENT_CLAIM`. Add `cancellation_reason_code` to its DETAIL so the merchant
can say *why*: `Заказ отменён клиентом` vs `Заказ отменён системой (30 мин)`. That is
exactly the specificity §4 asks for ("`Невозможно изменить статус` is too vague for a
counter — it should say what happened") and it needs **zero new enum values**.

Reserve `INVALID_STATUS_TRANSITION` for non-terminal mismatches, which after the widening
above are genuine client bugs.

---

## 3. §4's six strings → typed reasons, mapped against the 29-kind set

Re-read from source; the STATE-REPORT's table is accurate as a *transcription* (it is the
*reachability* that is wrong — see C1).

`mapError` bodies: `MenuViewModel.swift:332-344` (3 matches), `SettingsViewModel.swift:157-169`
(3 matches), `OnboardingViewModel.swift:260-276` (5 matches). Plus the control-flow duplicate
at `OnboardingViewModel.swift:59`.

| matched substring | Russian shown | in | reachable today | proposed typed reason | in the 29-set? |
|---|---|---|---|---|---|
| `invalidStatusTransition` | `Невозможно изменить статус` | Settings (`:159`) | **no** (C1) | `INVALID_STATUS_TRANSITION` (#2) | **yes** |
| `imageTooLarge` | `Фото слишком большое (макс. 5 МБ)` | Settings `:161`, Onboarding `:267`, Menu `:336` | **no** | *none needed* — client-side precondition | **no; keep client-side** |
| `unsupportedImageFormat` | `Поддерживаются только JPG, PNG, WEBP` | Settings `:163`, Onboarding `:269`, Menu `:338` | **no** | *none needed* — client-side precondition | **no; keep client-side** |
| `categoryNotEmpty` | `Сначала удалите все блюда из категории` | Onboarding `:271`, Menu `:334` | **no** | **`CATEGORY_NOT_EMPTY`** — NEW | **no — mint it** |
| `merchantAlreadyHasRestaurant` **or** `already` | `У вас уже есть ресторан` | Onboarding `:262` + control flow `:59` | **no** | **`MERCHANT_ALREADY_HAS_RESTAURANT`** — NEW | **no — mint it** |
| `onboardingIncomplete` | `Заполните все данные перед открытием` | Onboarding `:265` | **no** | **`ONBOARDING_INCOMPLETE`** — NEW | **no — mint it** |

### 3.1 Why two of the six should stay client-side

`imageTooLarge` and `unsupportedImageFormat` are **not server errors** and never were:

- `uploadRestaurantImage` / `uploadMenuItemImage` (`SupabaseService.swift:1397-1431`) throw
  `.imageTooLarge` at `:1439` and `.unsupportedImageFormat` at `:1442`, both from a
  client-side `guard` before the network call.
- A third, different size limit lives at `SupabaseService.swift:620`
  (`guard jpegData.count <= 500 * 1024 else { throw .imageTooLarge }`) on the courier's
  delivery-proof path — 500 KB, while the merchant UI says 5 MB.

So the "5 МБ" wording in the merchant UI may not even match the enforced ceiling on the
merchant path. Verify the merchant-path constant before reusing the string. Either way,
these two do not belong in a wire enum; they belong in a shared client-side validator with
one documented limit per bucket.

### 3.2 The genuinely-new reason kinds the merchant needs (5, not 1)

§4 says "Fifth distinct error I need but have no case for: the lock-contention retry". The
real count of *new wire kinds* the merchant requires is five, and lock contention is not
one of them (§2.5):

| # | new reason kind | raised by | DETAIL keys | Russian (proposed) |
|---|---|---|---|---|
| 1 | `CATEGORY_NOT_EMPTY` | `merchant_delete_category` (replacing `SupabaseService.deleteMenuCategory` `:1252-1266`, whose guard is `guard items.isEmpty else { throw .categoryNotEmpty }` at `:1260`) | `item_count` | `Сначала удалите все блюда из категории (осталось N)` |
| 2 | `MERCHANT_ALREADY_HAS_RESTAURANT` | `merchant_create_restaurant` (replacing the TOCTOU pre-check at `:1113-1116`) | `restaurant_id` | `У вас уже есть ресторан` |
| 3 | `ONBOARDING_INCOMPLETE` | `merchant_activate_restaurant` (replacing `activateRestaurant` `:1142-1156`, guard at `:1145`) | `missing` (array: `photo`/`categories`/`items`/`hours`) | `Заполните все данные перед открытием: <list>` |
| 4 | `INVALID_PREP_MINUTES` | `merchant_accept_order` | `min`, `max` | `Время приготовления должно быть от 5 до 120 минут` |
| 5 | *(reuse)* `ORDER_ALREADY_TERMINAL` **+ new `cancellation_reason_code` DETAIL key** | all four merchant RPCs + `merchant_cancel_order` | `status`, **`cancellation_reason_code`** | branch on the code: `Заказ отменён клиентом` / `Заказ отменён системой — превышено время` / `Заказ отменён курьером` |

`MERCHANT_ALREADY_HAS_RESTAURANT` carries real value beyond wording: it makes the
`restaurant_id` available, which is exactly what `OnboardingViewModel:60`'s dead resume
branch needs (`fetchMyRestaurant()` then `resumeOnboarding(for:)`). With the id in the
DETAIL the resume becomes a single round trip and a reachable branch.

`ONBOARDING_INCOMPLETE` carrying a `missing` array is the fix for the §2d complaint
("step 6 correctly *tells* you what is missing and then gives you no way to go fix it"):
the client can route straight to the offending step.

### 3.3 Which of the existing 29 kinds the merchant actually needs

Of the 29, the merchant's paths can see **6**:

`UNAUTHORIZED` (#1), `INVALID_STATUS_TRANSITION` (#2), `ORDER_NOT_FOUND` (#3),
`ORDER_ALREADY_TERMINAL` (#16), `NOT_AUTHENTICATED` (#17), `INVALID_REASON_CODE` (#4, once
reject/cancel take codes).

All six are already decoded by `ServiceError.from(serverError:)`
(`SupabaseService.swift:106-126` — `:123, :122, :120, :121, :124, :117`). So the decoder
needs **no** changes for the existing kinds and **five** additions for §3.2.

`ROLE_CHANGE_FORBIDDEN` (#11, SQLSTATE **42501**, from `profiles_block_role_change`
`19_lock_down_profile_role.sql:27`) is *adjacent* — the merchant never changes a role, but
it is one of the 11 kinds the decoder drops, and it is the only non-`P0001` kind besides
`set_accepting_orders:26`'s bare `42501`. `setAcceptingOrders` **is** on the merchant's
call list (`DashboardViewModel.swift:96`, `SettingsViewModel.swift:40`), so the merchant is
one of the two callers who can receive a `42501` with **no DETAIL at all** — the regex in
`from(serverError:)` (`:98`) finds nothing and returns `nil`. Give
`set_accepting_orders:26` a DETAIL (`UNAUTHORIZED`) as part of the extraction; it is a
one-line fix that closes the merchant's only untyped-error hole outside the four kitchen ops.

### 3.4 The exhaustiveness ask

§7 of the STATE-REPORT: *"a `ServiceError` that is exhaustive enough to `switch` over
without a `default` branch is what makes that stick."* Concretely that means:

- `ServiceError` today has **32 cases** (`SupabaseService.swift:5-38`) and `from()` maps
  **18 of 29** kinds with `default: return nil` (`:126`). The 11 unmapped are listed in
  `sql-function-catalogue.md` §6.1; **none** of the 11 is on a merchant path, so the
  merchant can get exhaustive coverage without waiting for the consumer's `create_order`
  work.
- For a `when` in Kotlin / `switch` in Swift with no `else`, the enum must be closed. The
  counter-requirement from `sql-function-catalogue.md` §6.2 is that any *proto* enum needs
  `UNKNOWN = 0` tolerated by the client, because three pinned app binaries cannot be
  updated in lockstep. Those two requirements are compatible only if the **Swift** enum
  keeps one `unknown(String)` case that the UI maps to a generic Russian fallback, and the
  merchant's `switch` is exhaustive *including* that case. Say so explicitly in the design,
  or the first new reason code ships a crash.

---

## 4. `merchant_cancel_order` — verified need, and the specification

### 4.1 Verification of the wrong-actor call (§2e)

Confirmed in source, full chain:

```
Views/OrderDetailView.swift:444-456   cancelButton  ->  showCancelSheet = true
Views/OrderDetailView.swift:524-554   cancelSheet
Views/OrderDetailView.swift:534-540     RavonPrimaryButton("Отменить заказ") {
                                          await vm.cancelOrder(orderId, reason: cancelReason)  // :536
                                          showCancelSheet = false                              // :537
                                          cancelReason = ""                                    // :538
ViewModels/OrdersViewModel.swift:156-163  func cancelOrder(_:reason:)
ViewModels/OrdersViewModel.swift:158        SupabaseService.shared.cancelOrder(orderId:reason:)
```

and in core:

```swift
// Sources/RavonCore/Services/SupabaseService.swift:631-639
// MARK: - Order Lifecycle (Consumer)
public func cancelOrder(orderId: UUID, reason: String?) async throws {
    struct Params: Encodable { let p_order_id: UUID; let p_reason: String? }
    try await client.rpc("cancel_order_by_consumer", params: Params(
        p_order_id: orderId, p_reason: reason
    )).execute()
}
```

The button is offered on `.accepted` (`OrderDetailView.swift:425`), `.preparing` (`:433`),
and `.ready` (`:437`). This closes the UNKNOWN in `order-lifecycle-spec.md` §7 (see C9).

### 4.2 What `cancel_order_by_consumer` does to a merchant caller

`13_courier_status_transition_rpcs_v2.sql:431-476`. Relevant lines:

```sql
v_uid uuid := auth.uid();
SELECT status, user_id, courier_id INTO v_status, v_user, v_courier
FROM orders WHERE id = p_order_id FOR UPDATE;          -- :443-444
IF v_user <> v_uid THEN                                 -- :449
  RAISE EXCEPTION 'unauthorized'
    USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason','UNAUTHORIZED')::text;
END IF;
...
UPDATE orders SET
  status = 'cancelled_by_customer',                     -- :470
  cancelled_by = v_uid,                                 -- :471
  cancellation_reason = p_reason,
  cancellation_reason_code = 'CONSUMER_CHANGED_MIND'    -- :473
WHERE id = p_order_id;
```

So the merchant's tap **always** raises `UNAUTHORIZED` at `:449` (`orders.user_id` is the
consumer, never the merchant). The `ServiceError` is `.unauthorized`
(`SupabaseService.swift:123`), `localizedDescription` = `Недостаточно прав`, assigned to
`OrdersViewModel.errorMessage` at `:161`, rendered **nowhere** (§2.3), sheet already
dismissed at `:537`. Exactly as §2e describes: "the merchant taps 'Отменить заказ', the
sheet closes, and nothing happened."

The counterfactual is worse than the current failure. If the ownership check were ever
relaxed, a merchant cancellation would be written as
`status='cancelled_by_customer'`, `cancellation_reason_code='CONSUMER_CHANGED_MIND'`,
`cancelled_by=<merchant uid>` — i.e. **restaurant-fault cancellations booked against the
customer**, plus `insert_courier_earning_for_cancel(…, 'CONSUMER_CHANGED_MIND', …)` at
`:464-467` filing the courier's partial pay under the wrong reason code. A ledger would
inherit that misattribution permanently. The failing `UNAUTHORIZED` is currently the only
thing preventing it. **Do not make this RPC merchant-callable; write a new one.**

Corollary: `cancelled_by_restaurant` has **no producer anywhere** — not in Swift, not in
SQL. `order-lifecycle-spec.md` §7: *"the merchant cannot cancel an order at all"* — the
state is model-reachable via rows 27–29 and operationally dead. Confirmed.

### 4.3 `merchant_cancel_order` — full specification

```sql
CREATE OR REPLACE FUNCTION merchant_cancel_order(
  p_order_id    uuid,
  p_reason_code text,           -- whitelisted, see below
  p_reason      text DEFAULT NULL   -- free-text note, optional
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
```

**Actor.** `auth.uid()` must be `restaurants.owner_id` for `orders.restaurant_id`.
Caveat, and it is a blocker: **`restaurants.owner_id` is referenced in 5 places and created
in no migration** (established fact; the reference the merchant depends on is
`SupabaseService.fetchMyRestaurant` `:1132` `.eq("owner_id", value: uid.uuidString)`).
The column must be added, typed, FK'd to `profiles(id)`, and indexed before any
merchant-ownership check can be written. That is a prerequisite for all five merchant RPCs,
not just this one.

**From-states.** `OrderLifecycle.swift` rows 27–29 give three. The from-set should be the
merchant's actionable set minus `created` (which is `merchant_reject_order`'s job):

`{accepted, preparing, ready}` — matching exactly where the button is offered today
(`OrderDetailView.swift:425, 433, 437`).

Explicitly **excluded**, and each needs a distinct answer rather than a shared error:

| status | why excluded | what the merchant should get |
|---|---|---|
| `created` | that is `merchant_reject_order` | `INVALID_STATUS_TRANSITION` — the UI never offers the button here anyway |
| `assigned`, `courier_arrived_restaurant` | a courier is committed and owed money; needs a policy decision, not a silent allow | **open question** — see §11 |
| `picked_up`, `delivering`, `courier_arrived_customer` | food has left the building | `CANNOT_CANCEL_POST_PICKUP` (#27, already in the 29-set, already decoded at `SupabaseService.swift:108`) |
| any terminal | — | `ORDER_ALREADY_TERMINAL` (+`status`, +`cancellation_reason_code`, per §2.5) |

**To-state.** `cancelled_by_restaurant`. This makes it the **first and only** producer of
that status, which means: it must be added to every status-set that enumerates cancels.
Verified inventory of what needs updating —
`OrderStatus.isTerminal` / `.isCancelled` already include it
(`Sources/RavonCore/Models/Order.swift:49, 59`); the merchant's own `statusColor`
switches already list it (`OrdersView.swift:207`, `OrderDetailView.swift:562`); but
`SupabaseService.swift:805-812`'s `terminalStatuses` array (used by
`fetchActiveOrderForCourier`) **does** include `cancelledByRestaurant.rawValue` at `:809`.
Good. The gap is the merchant's own `isActiveOrSurfacedTerminal`
(`OrdersViewModel.swift:46-59`), which surfaces `cancelledByCourier` and
`cancelledBySystem`-for-restaurant-too-long but **not** `cancelledByRestaurant` — so a
merchant who cancels an order watches it vanish from every tab (the §2a failure mode,
reached by a second route).

**Reason codes.** From the 17-value CHECK whitelist at
`09_cancellation_reason_code_and_courier_cancel_log.sql:21-35`, the three
`RESTAURANT_*` values that are not already spoken for:

| code | `CancellationReason` case | Russian (`CancellationReason.swift`) | notes |
|---|---|---|---|
| `RESTAURANT_CLOSED` | `.restaurantClosed` (`:14`) | `Ресторан закрыт` (`:59`) | |
| `RESTAURANT_OUT_OF_ITEMS` | `.restaurantOutOfItems` (`:15`) | `Не хватает позиций` (`:60`) | the common case — matches the sheet's own placeholder "нет ингредиентов" (`OrderDetailView.swift:530`) |
| `RESTAURANT_REJECTED` | `.restaurantRejected` (`:16`) | `Ресторан отклонил заказ` (`:61`) | reserve for `merchant_reject_order` (§2.4) |

`RESTAURANT_TOO_LONG_WAIT` is **excluded** — it is the courier/system auto-cancel code,
written only by `courier_report_restaurant_delay` (`16_…:113, 117`). A merchant must not be
able to self-assign it, because the merchant's own queue treats it as the 50%-payout
attention case (`OrdersViewModel.swift:55, 64`).

`CancellationReason.swift:40-53` declares `consumerAllowed` and `courierAllowed` static
sets but **no `merchantAllowed`**. Add:

```swift
public static var merchantAllowed: Set<CancellationReason> {
    [.restaurantClosed, .restaurantOutOfItems]
}
```

and validate `p_reason_code` against it server-side, raising `INVALID_REASON_CODE` (#4,
already decoded) with `DETAIL … 'code', p_reason_code` — matching
`cancel_order_by_courier`'s precedent. Note `sql-function-catalogue.md` §6.2 flags that
`cancel_order_by_courier`'s runtime whitelist already **disagrees** with the table CHECK;
do not add a third disagreeing list — derive all three from one source.

**Earnings consequence.** Reuse `insert_courier_earning_for_cancel` (`12_…:61-101`)
unchanged. The tier is data, not policy — `earnings_tier_for_cancel` (`12_…:35-45`):

| `status_at_cancel` | `tier_pct` | `earning_type` (`12_…:47-57`) |
|---|---|---|
| `assigned` | 25 | `partial_assigned` |
| `courier_arrived_restaurant` | 50 | `partial_at_restaurant` |
| `picked_up` / `delivering` / `courier_arrived_customer` | 100 | `partial_picked_up_lost` |
| anything else (incl. `accepted`, `preparing`, `ready`) | **0** | `manual_adjustment` |

So for the recommended from-set `{accepted, preparing, ready}`, `courier_id` is normally
`NULL` and the tier would be 0 anyway. Call the helper only `IF v_courier IS NOT NULL`,
mirroring `cancel_order_by_consumer:463-467`. Amount is
`round((delivery_fee * tier / 100.0)::numeric, 2)` (`12_…:84`), and the insert is
`ON CONFLICT (order_id) DO UPDATE` (`12_…:94-99`) — idempotent, which matters because the
merchant client will retry blindly.

**The 50% claim in the merchant UI is correct — verified, and it is NOT a hardcoded 50.**
`OrdersView.swift:161` and `OrderDetailView.swift:204` both read "Ресторан превысил время
ожидания (30 мин). Курьер получил 50% оплаты." The producing call
(`16_…:111-114`) passes `p_tier_override = NULL`, so the tier is derived from
`earnings_tier_for_cancel(v_status)`. And `courier_report_restaurant_delay` gates on
`IF v_status <> 'courier_arrived_restaurant' THEN RAISE …` (`16_…:102-105`), so
`v_status` is *always* `courier_arrived_restaurant` at that point → tier **50**. The UI
string is right by construction. Do not change the number; do note that it is derived, so
editing `earnings_tier_for_cancel` silently makes two Russian strings lie.

**Side effects to mirror.** `cancel_order_by_consumer` relies on a
`cleanup_cancelled_order` trigger to clear `courier_locations.current_order_id`
(commented at `16_…:122`). `merchant_cancel_order` must fire the same trigger (it will, if
the trigger is `AFTER UPDATE ON orders`) or the courier stays pinned to a dead order and
receives no further offers.

**Chat.** `courier_report_restaurant_delay` posts a system `chat_messages` row on the
non-cancel branch (`16_…:132-135`). A merchant cancellation is at least as
notification-worthy — the consumer has paid intent and the courier may be en route.
Recommend an `INSERT INTO chat_messages(order_id, sender_id, body)` with
`sender_role='system'` (forced per `17_system_messages_sender_role_fix.sql`). Note this is
the **only** write the merchant would ever make to `chat_messages` — today the merchant's
access is read-only (§9), and it never calls `sendMessage`.

---

## 5. §2a — "order disappears at handoff". Client-side. But the OrderLifecycle model only half-fixes it.

### 5.1 Re-verified, and the pickup-code finding is sharper than §2a states

The tab sources (`OrdersView.swift:12-20`) are `vm.newOrders` / `vm.activeOrders` /
`vm.readyOrders` / `vm.scheduledOrders`:

| tab | predicate | line |
|---|---|---|
| Новые | `status == .created` | `OrdersViewModel.swift:24` |
| В работе | `isActiveOrSurfacedTerminal` | `:30` → `:46-59` |
| Готовые | `status == .ready` | `:42` |
| Запланированные | `status == .scheduled` | `:70` |

`isActiveOrSurfacedTerminal` (`:46-59`) returns `true` only for `.accepted`, `.preparing`,
`.cancelledByCourier`, and `.cancelledBySystem` where
`cancellationReasonCode == CancellationReason.restaurantTooLongWait.rawValue`.

Statuses matching **no tab**: `.assigned`, `.courierArrivedRestaurant`, `.pickedUp`,
`.delivering`, `.courierArrivedCustomer`, `.delivered`, `.cancelled`, `.rejected`,
`.cancelledByCustomer`, `.cancelledByRestaurant`. Ten of seventeen.

`OrderDetailView` is only reachable via `NavigationLink(value: order.id)` from those lists
(`OrdersView.swift:62`, destination `:71-73`), so it becomes unreachable too. **But** the
detail view's `order` is `vm.orders.first { $0.id == orderId }` (`OrderDetailView.swift:20-22`)
and `vm.orders` is the *unfiltered* result of `fetchOrdersForRestaurant` — so if the
merchant is already *on* the detail screen when the status flips, the screen stays alive
and renders. What it loses is the code.

**The sharper finding: the merchant's pickup-code gate and the server's pickup window are
DISJOINT SETS.**

| | statuses |
|---|---|
| merchant **shows** the code | `{preparing, ready}` — `OrderDetailView.swift:47`, `OrdersView.swift:127` |
| server **requires** the code | `{courier_arrived_restaurant}` — `courier_pickup_order`, `13_…:280-283`: `IF v_status <> 'courier_arrived_restaurant' THEN RAISE 'order_no_longer_pickupable'` |
| `OrderLifecycle` says show it | `{assigned, courier_arrived_restaurant}` — obligation `showPickupCode`, per `order-lifecycle-spec.md` §5 |

Intersection of row 1 and row 2: **empty**. The code is displayed at exactly the two
statuses where it cannot be used, and hidden at the one status where it must be read aloud.
§2a says the gates "sort after `.ready`"; the stronger statement is that they never overlap
at all.

And the courier cannot self-serve: `ActiveDeliveryView.swift:444-459` is a manual 4-digit
`TextField("0000", text: $pickupCode)` filtered to `.filter(\.isNumber).prefix(4)`, submitted
at `:601` with `.disabled(pickupCode.count != 4)`. Nothing auto-fills it. So the merchant
reading it aloud is the only path.

(The code *is* physically present in the courier's payload, because
`fetchOrdersForRestaurant`-style `select("*")` queries ship `verification_code` — the
established leak. But no courier screen displays it, so the operational blocker is real
even though the cryptographic assurance is already zero.)

### 5.2 Does `OrderLifecycle`'s obligation model fix it? Partially — and it breaks three things.

Per `order-lifecycle-spec.md` §5–§6, the model's merchant sets are:

- `actionable(merchant)` = `{created, accepted, preparing, ready}` (4)
- `obligated(merchant)` = `{created, accepted, preparing, ready, assigned, courier_arrived_restaurant}` (6)
- `visibleStatuses(merchant)` = the union = **6**
- `showPickupCode` at `{assigned, courier_arrived_restaurant}`

Mapped against what the app does today:

| status | app tab today | model visible? | model obligation | verdict |
|---|---|---|---|---|
| `created` | Новые | yes | `startCooking` | ✅ agree |
| `accepted` | В работе | yes | `startCooking`, `trackProgress` | ✅ agree |
| `preparing` | В работе | yes | `startCooking`, `trackProgress` | ✅ agree |
| `ready` | Готовые | yes | `trackProgress` | ✅ agree — but model drops the pickup code here, app shows it |
| `assigned` | **none** | **yes** | **`showPickupCode`**, `trackProgress` | ✅ **model FIXES the hole** |
| `courier_arrived_restaurant` | **none** | **yes** | **`showPickupCode`**, `trackProgress` | ✅ **model FIXES the hole** |
| `scheduled` | Запланированные (a whole tab) | **no** | — | ❌ **model DELETES a shipped tab** |
| `cancelled_by_courier` | В работе (top, attention) | **no** | — | ❌ **model DELETES the attention banner** |
| `cancelled_by_system` + `RESTAURANT_TOO_LONG_WAIT` | В работе (top, attention) | **no** | — | ❌ **model DELETES the 50%-payout notice** |
| `picked_up` / `delivering` / `courier_arrived_customer` | none (but `courierMapSection` gates on them, `OrderDetailView.swift:53`) | **no** | — | ❌ the live courier map is dead code under the model |

So: **adopting `visibleStatuses(for: .merchant)` verbatim fixes the handoff hole and
simultaneously removes the scheduled-orders tab, both surfaced-terminal attention cases,
and the post-pickup courier map.** This is the concrete instance of the derivation hole
`order-lifecycle-spec.md` §6 already flags — *"no actor can see any terminal state"*, and
`scheduled` additionally falls out because nothing makes it `merchant`-actionable.

The `historical(actor)` third term proposed in `order-lifecycle-spec.md` §6 is necessary
but not sufficient for the merchant: `scheduled` is **not** terminal, so it needs a fourth
consideration. The merchant's real need is three buckets, not one visible set:

| bucket | statuses | why |
|---|---|---|
| **actionable** | `created`, `accepted`, `preparing`, `ready` | tap-to-advance |
| **monitor** | `assigned`, `courier_arrived_restaurant` (+ optionally `picked_up`) | show pickup code, show courier map, do not offer actions |
| **attention** | `cancelled_by_courier`, `cancelled_by_system`(`RESTAURANT_TOO_LONG_WAIT`), and — once §4 ships — `cancelled_by_restaurant` | food may be sitting on the counter; money changed hands |
| **informational** | `scheduled` | read-only, cron flips it (`activate_scheduled_orders`) |

Whatever shape the Kotlin/core model takes, it must be able to express these four. A single
`Set<OrderStatus>` per actor cannot.

### 5.3 Verdict: no server work required for §2a. Two server-adjacent asks.

**Zero server work.** The data is already client-side: `fetchOrdersForRestaurant`
(`SupabaseService.swift:304-312`) is `select("*, order_items(*)").eq("restaurant_id", …)
.order("created_at", ascending: false)` with **no status filter, no limit, no pagination**.
Every status is already in `vm.orders`. §2a is 100% presentation, and the STATE-REPORT's
call to rank it first is correct.

`OrderLifecycle` cannot fix it in its current form, for the reason the orchestrator already
established: **it has zero production callers.** Nothing in the merchant app imports or
references `OrderLifecycle`, `OrderObligation`, or `visibleStatuses` — and
`Sources/RavonCore/Models/OrderLifecycle.swift` is itself **untracked**, 0 commits ahead of
`origin/main`. The merchant is pinned to `a1e9d6c8`, which predates the file entirely. So
the model is not available to this app at any version it can resolve.

Two things the extraction should nonetheless change, because §2a exposes them:

1. **Project the order payload.** `select("*")` ships `verification_code` **and**
   `delivery_verification_code` to the merchant (`Order.swift:341-342` maps both;
   `10_dual_verification_codes_and_delivery_mode.sql:14` adds the second). The merchant
   legitimately needs the *pickup* code and has no business holding the customer's *door*
   code. A gRPC `MerchantOrder` message should carry `pickup_verification_code` and omit
   `delivery_verification_code`. Zero client behaviour changes; one field-level leak closes.
2. **Widen `merchant_mark_order_ready`'s from-set** to include `assigned` and
   `courier_arrived_restaurant` (§2.5). Without it, a courier who claims during `preparing`
   — which `claim_order` permits — permanently blocks the merchant from marking ready.

---

## 6. §2b — new-order alerting. What the merchant needs from realtime/push after extraction.

### 6.1 The three defects, re-verified

**(a) The alert is suppressed in the idle state.** `OrdersViewModel.swift:105-114`:

```swift
let previousCreatedIds = Set(orders.filter { $0.status == .created }.map(\.id))
let newCreatedIds      = Set(fetched.filter { $0.status == .created }.map(\.id))
let brandNewOrders     = newCreatedIds.subtracting(previousCreatedIds)
orders = fetched
if !brandNewOrders.isEmpty && !previousCreatedIds.isEmpty {   // :111
    alertNewOrder(); hasNewOrderAlert = true
}
```

`previousCreatedIds` is the set of *already-pending* `created` orders. A merchant with a
clear queue — the desirable state — has an empty set, so the **first** order to arrive is
silent. The chime only ever fires for the 2nd+ concurrent order. Exactly as reported.

**(b) The subscription only exists while the Orders tab is on screen.** `startListening()`
is in `OrdersView`'s `.task` (`:74-77`), `stopListening()` in its `.onDisappear`
(`:78-80`). `MainTabView`'s default tab is Дашборд.

I can prove the dependency **without** resolving SwiftUI's re-fire semantics, which the
report honestly marks unconfirmed. `stopListening()` (`OrdersViewModel.swift:92-97`) does
two things: `unsubscribeFromOrders()` *and* `cancellables.removeAll()`. The Combine sink on
`RealtimeService.shared.$lastOrderChange` is created **only** in `startListening()`
(`:81-89`), which is called **only** from `OrdersView.swift:76`. So if `.task` does not
re-fire, there is no other code path in the app that can recreate the sink. The subscription
is not merely stale — it is unrecoverable for the process lifetime. (Whether `.task`
re-fires on pop from a `NavigationStack` push is **UNKNOWN — needs a device**; either way
the fix is the same.)

**(c) `hasNewOrderAlert` is dead state.** Declared `:14`, written `:113`, `grep` finds no
third occurrence in the app. No tab badge, no unread count.

**(d) — not in the report: the alert mechanism itself is foreground-only.**
`alertNewOrder()` (`:167-173`) is `AudioServicesPlayAlertSound(SystemSoundID(1005))` plus
`UINotificationFeedbackGenerator().notificationOccurred(.warning)`. Both require the app to
be foregrounded and unlocked. So even with (a), (b), (c) all fixed, a counter tablet whose
screen has auto-locked gets nothing.

### 6.2 The merchant's realtime path is *better* than the courier's — do not port them together

This is an important asymmetry for the extraction plan, because the established facts
describe the courier's feed as pathological and it would be easy to assume the merchant
shares it.

`RealtimeService.subscribeToRestaurantOrders` (`Sources/RavonCore/Services/RealtimeService.swift:147-199`):

```swift
let channel = client.channel("restaurant-orders-\(restaurantId.uuidString)")
let changes = channel.postgresChange(
    AnyAction.self, schema: "public", table: "orders",
    filter: .eq("restaurant_id", value: restaurantId)   // :154 — SERVER-SIDE FILTER
)
```

| | courier offer feed (established) | merchant order feed (verified here) |
|---|---|---|
| server-side filter | **none** — unfiltered realtime on ALL of `orders` | `.eq("restaurant_id", …)` (`:154`) |
| action types | — | `AnyAction`; `.insert` handled (`:163-176`), `.update` handled (`:177-193`), `.delete` ignored (`:194-195`) |
| fanout | O(active × idle / 5) full scans/sec | one channel per restaurant, rows scoped to that restaurant |
| re-SELECT on event | oldest unassigned order **nationwide** | full re-list of this restaurant's orders |

So the merchant's realtime does **not** need re-architecting to be correct — only to be
efficient and to survive backgrounding. Two carry-overs do apply:

- **`REPLICA IDENTITY FULL` on `orders` is required.** `RealtimeService.swift:181-183`
  reads `action.oldRecord["status"]`. This is one of the four undocumented dependencies the
  orchestrator established. (`subscribeToRestaurantStatus`, `:299-330`, reads only
  `change.record[...]` — so the restaurant-status channel does **not** need it.)
- **Realtime `postgres_changes` filters are still gated by RLS on the subscribing role, and
  there is NO policy on `orders` in any migration.** Whether the merchant receives anything
  at all is **UNKNOWN — needs live introspection**. Designing the merchant's `orders` RLS /
  gRPC-stream authorization is a prerequisite, not a follow-up.

Channel slots are singletons on the shared `@MainActor` `RealtimeService`
(`:86-97`): `orderChannel`, `restaurantStatusChannel`, `chatChannel`,
`courierLocationChannel`. The merchant uses all four concurrently (Orders tab + Dashboard +
OrderDetail) with **no collision** — each `subscribeTo…` calls its own matching
`unsubscribeFrom…` first (`:148`, `:300`). The constraint is one *instance* each: only one
order's chat and one courier's location can be tracked at a time. Fine for one counter
device, a hard ceiling if the merchant ever wants two open details.

### 6.3 Zero push infrastructure exists. Verified.

`grep` over all 22 Swift files for `UNUserNotificationCenter`,
`UIApplication.shared.register`, `remoteNotification`, `apns`, `aps-environment`,
`BGTaskScheduler`, `UIBackgroundModes`: **zero hits**. No `.entitlements` file, no
`Info.plist`, no `INFOPLIST_KEY_UIBackgroundModes` in `project.pbxproj`. No device token is
captured, stored, or sent; there is no `device_tokens` table in any migration and no
`profiles` column for one.

### 6.4 What extraction must provide

Ranked by what the merchant cannot do without:

1. **A server-authored "new order" signal, not a client-side diff.** The gating bug in (a)
   exists *because* newness is inferred by set subtraction over refetched lists. If the
   stream carries the event (`OrderCreated{order_id, restaurant_id, created_at}`), the
   client alerts on the event and the `previousCreatedIds` heuristic disappears. The
   existing `.insert` branch (`RealtimeService.swift:163-176`) already builds such an
   event and then throws it away — `OrdersViewModel.swift:84-88` sinks
   `$lastOrderChange` and ignores the payload, calling `fetchOrders(silent: true)`. So this
   is a client-side waste today and a natural gRPC server-stream tomorrow.
2. **A subscription whose lifetime is the session, not a view.** Whether that is one
   long-lived gRPC server-stream per merchant or a reconnecting WebSocket, it must be owned
   above the view layer. This is the (b) fix and it is *enabled* by extraction: a single
   `MerchantEventStream` RPC replacing four view-scoped Supabase channels.
3. **Push (APNs), because sound+haptics cannot reach a locked counter device.** This is
   net-new infrastructure on both sides:
   - client: capability, entitlement, `UNUserNotificationCenter` authorization, token upload
   - server: a `device_tokens` table (`user_id`, `token`, `platform`, `app`, `updated_at`,
     unique on token), an APNs sender, and a trigger/outbox on `orders` INSERT
   - **Do not use a Postgres trigger calling `pg_net` directly** — the existing 5 pg_cron
     jobs are the precedent for out-of-band work, and `create_order` already takes
     `FOR UPDATE` on `restaurants` + `menu_items`; adding an HTTP call inside that
     transaction extends the lock window on the hottest write path. Use an outbox row +
     a worker.
   - **Tajikistan reality check:** APNs requires an outbound path from the device. This is
     exactly the `sjc` primary-region question the abandoned `Ravon_android/backend/fly.toml`
     raises. Latency from Dushanbe to `sjc` is ~250 ms RTT minimum. For a *notification*
     that is irrelevant; for a long-lived order stream it is not. Region choice is a
     decision, not a detail.
4. **A badge count.** (c) is client-side, but it wants a number the server can supply
   cheaply (`pending_order_count`) rather than a client-side `filter().count` over a full
   list refetch.
5. **Retire the 30-second stats poll.** §5c is right and the number is worth stating:
   `DashboardViewModel.startStatsTimer()` (`:72-80`) is a `Timer.scheduledTimer(
   withTimeInterval: 30, repeats: true)` re-calling `fetchMerchantStats` → RPC
   `get_merchant_stats`, with `try?` swallowing every failure. 2,880 RPC calls per device
   per day, forever, for a dashboard nobody is looking at. Fold stats deltas into the same
   event stream as (1).

---

## 7. Currency and rounding, exactly

### 7.1 Sites: 22 `сомони` + 1 `₽` = 23 money renders

`сум`: **0** remaining. `сомони`: **22**. `TJS` / `somoni` / `сом.`: 0. `₽`: **1** (C6).

**Value renders — 13** (all `\(Int(x)) сомони`):

| file:line | expression |
|---|---|
| `Views/DashboardView.swift:256` | `private func formatCurrency(_ value: Double) -> String { "\(Int(value)) сомони" }` — the app's only helper, used by Dashboard alone |
| `Views/SettingsView.swift:61` | `"\(Int(restaurant.minOrderAmount)) сомони"` |
| `Views/SettingsView.swift:62` | `"\(Int(restaurant.deliveryFee)) сомони"` |
| `Views/ModifierGroupsView.swift:99` | `"+\(Int(option.priceAdjustment)) сомони"` — the only `+`-prefixed variant |
| `Views/ModifierGroupsView.swift:357` | `"\(Int(item.price)) сомони"` |
| `Views/OrderDetailView.swift:325` | `"\(Int(item.totalPrice)) сомони"` `.monospacedDigit()` |
| `Views/OrderDetailView.swift:339` | `"\(Int(order.deliveryFee)) сомони"` `.monospacedDigit()` |
| `Views/OrderDetailView.swift:348` | `"\(Int(order.total)) сомони"` `.monospacedDigit()` |
| `Views/MenuView.swift:293` | `"\(Int(item.price)) сомони"` |
| `Views/OrdersView.swift:111` | `"\(Int(order.total)) сомони"` |
| `Views/OrdersView.swift:227` | `"\(Int(order.total)) сомони"` (ScheduledOrderRow) |
| `Views/Onboarding/OnboardingView.swift:438` | `"\(Int(item.price)) сомони"` |
| `Views/Onboarding/OnboardingView.swift:643` | `"\(Int(item.price)) сомони"` |

**Field labels — 9** (all `<Label> (сомони)`): `ModifierGroupsView.swift:228, 307`;
`RestaurantEditView.swift:99, 107`; `MenuItemCreateView.swift:62`;
`MenuItemEditView.swift:91`; `OnboardingView.swift:103, 109, 404`.

`OnboardingView.swift:404` is the odd one — the unit is inside a `placeholder`, not a
`Text`: `RavonTextField(icon: "banknote", placeholder: "Цена (сомони)", …)`. A third
placement, alongside the courier's standalone `Text("сомони")`.

**Shape:** integer, zero decimals, **no grouping separator**, unit suffixed after one ASCII
space, no symbol. 12 of the 13 value sites inline the interpolation rather than using
`formatCurrency`.

### 7.2 Rounding — measured, all three apps

| value | merchant `Int(x)` | courier `%.0f` | consumer `formatPrice` |
|---|---|---|---|
| 99.9 | **99** | **100** | `"99.90"` |
| 0.5 | 0 | 0 | — |
| 1.5 | **1** | **2** | — |
| 2.5 | 2 | 2 | — |
| 12.5 | 12 | 12 | — |
| 13.5 | **13** | **14** | — |
| −0.5 | 0 | `"-0"` | — |
| −99.9 | **−99** | **−100** | — |
| 99.999999 | **99** | **100** | — |

Measured on this machine with the exact expressions. The three rules are:

- **merchant:** `Int(Double)` — **truncation toward zero**
- **courier:** `String(format: "%.0f")` / SwiftUI `specifier: "%.0f"` — libc `printf`,
  **half-to-even** (established by `app-courier-constraints.md` §6, re-confirmed above)
- **consumer:** `CheckoutViewModel.formatPrice` — integer when whole, `%.2f` otherwise

§0 of the STATE-REPORT characterises courier as "rounds (99.9 → 100)". True for 99.9, but
the rule is banker's rounding, not half-up: courier renders 0.5→0, 2.5→2, 12.5→12.
Merchant and courier therefore **agree** on every `x.5` where `floor(x)` is even and
**disagree** on every other fractional value ≥ .5. That is a worse failure mode than
uniform disagreement, because it looks consistent in spot checks.

Two crash/render hazards `Int(Double)` carries that `%.0f` does not:

- `Int(Double.nan)` and `Int(Double.infinity)` **trap** (`Fatal error: Double value cannot
  be converted to Int because it is either infinite or NaN`), as does any value outside
  `Int` range. `order.total` / `item.price` are `Double`s decoded from JSON; a malformed or
  hostile payload crashes the app at 13 sites. `%.0f` prints `nan`/`inf` harmlessly.
- Negative zero: `Int(-0.5)` is `0`, `String(format: "%.0f", -0.5)` is `"-0"`. Only reachable
  via clawbacks today (courier-side), but relevant the moment merchant-side adjustments exist.

### 7.3 The `.numberPad` consequence, and why it points at integer minor units

15 `.numberPad`, 0 `.decimalPad` (C4). 10 of the 15 are money. So the merchant can only
**author** integers.

§0 concludes: "if the shared formatter is 2dp, merchant needs `.decimalPad` and parsing
changes too; that is a product decision, not a formatting one." Agreed on the shape of the
decision, but C2 changes its urgency: the merchant is **already destroying** stored 2dp
values on every edit-and-save. The question is not "should we let the merchant author
cents" but "how do we stop the merchant from silently deleting cents the consumer and the
ledger already depend on".

`create_order` computes with Postgres `numeric` and `round(…, 2)`
(established; `12_…:84` is the visible instance). So 2dp values *do* exist server-side,
authored by pricing math the merchant never sees.

**Recommendation for the wire:** integer minor units (dirham; 1 somoni = 100 dirham), i.e.
`int64 amount_minor` on every money field, plus a `currency` string fixed to `TJS`. That
makes:

- truncation impossible on the transport
- the edit round-trip lossless regardless of keypad (field seeds from `amount_minor / 100`
  and `% 100`, and an untouched field reserialises byte-identically)
- rounding a pure presentation concern with one documented rule
- the round-then-sum vs sum-then-round problem the courier doc raises for earnings
  (`app-courier-constraints.md` §6) go away for the same reason

Until then, the **minimum** safe change is to stop seeding edit fields with
`String(Int(x))` — use a lossless round-trip or send `nil` for untouched fields — and to
add an explicit dirty-check so `updates["price"]` is omitted when the merchant did not
touch the price.

One cross-cutting requirement all three apps share: the formatter needs a **bare-unit
accessor** (label placement `(сомони)`, courier's standalone `Text("сомони")`,
OnboardingView's placeholder) in addition to the inline value form. §0 is right about this.

---

## 8. §6 — the supabase-swift 2.43.1 drift story

Confirmed exactly as reported (table in C7), and extended:

- **No merchant-specific reason exists.** 2.41.1 → 2.43.0 → 2.43.1 across two ordinary
  feature commits, no commit message, code change, or comment referencing a Supabase fix.
- **Merchant is version-agnostic by construction.** Verified by grep over all 22 files:
  **zero** `import Supabase`, `import PostgREST`, `import Realtime`, `import Auth`,
  `import Functions`, `import Storage`, and zero `AnyJSON`. Imports present: `SwiftUI` (21),
  `RavonCore` (22), `Combine` (7), `PhotosUI` (5), `Foundation` (1), `UIKit` (1),
  `MapKit` (1), `AudioToolbox` (1). So merchant imposes **zero** constraint on the fleet
  version — pick what consumer and courier need.
- **Corrections:** `Package.resolved` is already committed everywhere and did not stop the
  drift; the fleet has three live versions (consumer 2.41.1, courier 2.42.0, merchant
  2.43.1). See C7. The actual fix is `Package.swift:11`.
- **For the extraction this matters less than it looks.** If gRPC replaces PostgREST, the
  supabase-swift dependency shrinks to Auth + Realtime (or disappears, if auth and streaming
  also move). The `from: "2.41.0"` range is a problem worth exactly one line of
  `Package.swift` and no planning.
- **The branch pin is the real hazard.** All three apps resolve ravon-core by *branch*
  (`mmarufov/auth-overhaul`), not revision or tag. A push to that branch retargets all
  three apps' next resolve. §7's ask — "Tag `v1.0.0` and I'll repoint the same day" — should
  be done before any extraction work lands, because otherwise every app rebuild is a
  moving target. Note the branch is not an ancestor of `main` and there are no tags.

---

## 9. The full core surface a gRPC migration must cover

**0 `import Supabase`, confirmed.** Also 0 `from("`, 0 `.rpc(`, 0 `.channel(`, 0
`supabaseClient`. The merchant physically cannot issue a query RavonCore did not author.
The entire migration surface is the set of core method names it calls.

**48 distinct `SupabaseService` methods across 92 call sites**, plus 12 `RealtimeService`
members, plus 2 `AuthService` members, plus `RavonCore.configure` and `RavonAuthFlow`.

### 9.1 Only 3 of the 48 are RPCs today. 45 are raw PostgREST.

| method | core lines | RPC | verbs | tables / storage |
|---|---|---|---|---|
| `acceptOrder` | 393-406 | — | select,update | `orders` |
| `activateRestaurant` | 1142-1156 | — | select,update | `restaurants` |
| `cancelOrder` | 632-639 | **`cancel_order_by_consumer`** | rpc | — |
| `closeRestaurant` | 1182-1194 | — | select,update | `restaurants` |
| `createMenuCategory` | 1230-1237 | — | insert,select | `menu_categories` |
| `createMenuItem` | 1277-1288 | — | insert,select | `menu_items` |
| `createModifierGroup` | 1307-1314 | — | insert,select | `modifier_groups` |
| `createModifierOption` | 1342-1349 | — | insert,select | `modifier_options` |
| `createRestaurant` | 1109-1124 | — | insert,select | `restaurants` |
| `deleteMenuCategory` | 1252-1266 | — | select,update | `menu_categories`, `menu_items` |
| `deleteMenuItem` | 1290-1296 | — | update | `menu_items` |
| `deleteModifierGroup` | 1333-1340 | — | delete | `modifier_groups` |
| `deleteModifierOption` | 1367-1374 | — | delete | `modifier_options` |
| `fetchAllMenuCategories` | 949-958 | — | select | `menu_categories` |
| `fetchAllMenuItems` | 939-947 | — | select | `menu_items` |
| `fetchAllModifierGroups` | 926-937 | — | select | `modifier_groups` |
| `fetchMenuCategories` | 224-234 | — | select | `menu_categories` |
| `fetchMerchantStats` | 1449-1457 | **`get_merchant_stats`** | rpc | — |
| `fetchMessages` | 1068-1078 | — | select | `chat_messages` |
| `fetchMyRestaurant` | 1126-1140 | — | select | `restaurants` |
| `fetchOnboardingProgress` | 1196-1219 | — | select (+4 internal calls) | `menu_items` |
| `fetchOrdersForRestaurant` | 304-312 | — | select | `orders` (+ `order_items` join) |
| `fetchProfile` | 143-153 | — | select | `profiles` |
| `fetchRestaurant` | 186-209 | — | select | `restaurants` |
| `fetchRestaurantHours` | 885-892 | — | select | `restaurant_hours` |
| `fetchRestaurantPreview` | 1221-1228 | — | *composite* | (delegates) |
| `linkModifierGroup` | 1376-1381 | — | insert | `menu_item_modifier_groups` |
| `markOrderReady` | 438-449 | — | select,update | `orders` |
| `pauseRestaurant` | 1170-1180 | — | select,update | `restaurants` |
| `rejectOrder` | 419-436 | — | select,update | `orders` |
| `restoreMenuCategory` | 1268-1275 | — | update | `menu_categories` |
| `restoreMenuItem` | 1298-1305 | — | update | `menu_items` |
| `resumeRestaurant` | 1158-1168 | — | select,update | `restaurants` |
| `setAcceptingOrders` | 1042-1051 | **`set_accepting_orders`** | rpc | — |
| `startPreparing` | 408-417 | — | select,update | `orders` |
| `toggleAcceptingOrders` | 1034-1036 | *(forwards → `set_accepting_orders`)* | — | — |
| `toggleMenuCategoryAvailability` | 960-965 | — | update | `menu_categories` |
| `toggleMenuItemAvailability` | 967-972 | — | update | `menu_items` |
| `unlinkModifierGroup` | 1383-1395 | — | delete | `menu_item_modifier_groups` |
| `updateMenuCategory` | 1239-1250 | — | update | `menu_categories` |
| `updateMenuItem` | 982-1005 | — | update | `menu_items` |
| `updateModifierGroup` | 1316-1331 | — | update | `modifier_groups` |
| `updateModifierOption` | 1351-1365 | — | update | `modifier_options` |
| `updateRestaurant` | 1007-1032 | — | update | `restaurants` |
| `updateStock` | 974-980 | — | update | `menu_items` |
| `uploadMenuItemImage` | 1415-1431 | — | update, upload | `menu_items` + storage `menu-item-images` |
| `uploadRestaurantImage` | 1397-1413 | — | update, upload | `restaurants` + storage `restaurant-images` |
| `upsertRestaurantHours` | 894-907 | — | upsert | `restaurant_hours` |

**10 tables, 2 storage buckets.** Write access by table:

| table | merchant verbs | note |
|---|---|---|
| `orders` | select, **update** ×4 | the four CAS ops — the migration-20 blocker |
| `restaurants` | select, insert, update | includes lifecycle: draft → active → paused → closed |
| `menu_items` | select, insert, update | soft-delete via update; `updateStock`; availability toggle |
| `menu_categories` | select, insert, update | soft-delete via update |
| `modifier_groups` | select, insert, update, **delete** | hard delete |
| `modifier_options` | select, insert, update, **delete** | hard delete |
| `menu_item_modifier_groups` | insert, **delete** | join table; hard delete |
| `restaurant_hours` | select, **upsert** | the only `upsert` in the merchant surface |
| `chat_messages` | **select only** | merchant never calls `sendMessage` — read-only today |
| `profiles` | **select only** | `fetchProfile` |

`order_items` is read only as an embedded PostgREST join
(`select("*, order_items(*)")`, `SupabaseService.swift:306`) — no separate query, no write.
`order_status_history` is **never touched** (C5).

### 9.2 Three RPCs, three different problems

| RPC | status | problem |
|---|---|---|
| `set_accepting_orders` | exists (`05_…`) | its one `RAISE` at `:26` has **no DETAIL** (SQLSTATE `42501`), so `ServiceError.from` cannot decode it. Merchant is one of only two callers of an untyped error in the whole system. One-line fix. |
| `get_merchant_stats` | **no migration** | one of the 3 RPCs that exist in Swift and no SQL. A prior spec exists in `.context/plans/` (see `sql-function-catalogue.md` §5b). Must be written from scratch. Polled every 30 s (§6.4). |
| `cancel_order_by_consumer` | exists (`13_…:431`) | **wrong actor** — always raises `UNAUTHORIZED` for a merchant (§4). |

### 9.3 Composite methods that should collapse to one RPC

Two of the 48 are client-side fan-out and are gRPC round-trip wins:

- **`fetchOnboardingProgress`** (`:1196-1219`) — **4 sequential round trips**:
  `fetchMyRestaurant()` → `fetchMenuCategories()` → a `menu_items` query
  (`.eq("is_available", true).gt("price", 0)`) → `fetchRestaurantHours()`. Called twice
  (`OnboardingViewModel.swift:210, 237`).
- **`fetchRestaurantPreview`** (`:1221-1228`) — delegates to three other methods. Called
  once (`OnboardingViewModel.swift:201`).

Both are read-only and idempotent; both are pure wins as single RPCs.

### 9.4 Realtime and auth surface

`RealtimeService` — **12 members**, 8 methods + 4 publishers:

| member | merchant call site | needs `REPLICA IDENTITY FULL`? |
|---|---|---|
| `subscribeToRestaurantOrders(restaurantId:)` | `OrdersViewModel.swift:76` | **yes** (reads `oldRecord["status"]`, `RealtimeService.swift:181-183`) |
| `unsubscribeFromOrders()` | `OrdersViewModel.swift:94` | — |
| `$lastOrderChange` | `OrdersViewModel.swift:81` | — |
| `subscribeToRestaurantStatus(restaurantId:)` | `DashboardViewModel.swift:55` | no (reads `record` only, `:314-322`) |
| `unsubscribeFromRestaurantStatus()` | `DashboardViewModel.swift:33` | — |
| `$lastRestaurantStatusChange` | `DashboardViewModel.swift:60` | — |
| `subscribeToChat(orderId:)` | `OrderDetailView.swift:96` | — |
| `unsubscribeFromChat()` | `OrderDetailView.swift:127` | — |
| `$lastChatMessage` | `OrderDetailView.swift:97` | — |
| `subscribeToCourierLocation(courierId:)` | `OrderDetailView.swift:110` | — |
| `unsubscribeFromCourierLocation()` | `OrderDetailView.swift:126` | — |
| `$lastCourierLocationChange` | `OrderDetailView.swift:113` | — |

Tables streamed to the merchant: `orders`, `restaurants`, `chat_messages`,
`courier_locations` — 4. The merchant is the **only** app that subscribes to
`courier_locations` for a courier it does not own, which is its own authorization question.

`AuthService` — **2 members**: `signOut()` (`ContentView.swift:60`,
`SettingsViewModel.swift:149`, `ClosedRestaurantView.swift:25`) and the observed state
`isLoaded` / `isSignedIn` / `userRole` / `loadSession()`
(`ContentView.swift:9, 11, 55, 56, 58`). Plus `RavonAuthFlow(role: .merchant)`
(`ContentView.swift:14`) — the shared OTP UI from core.

`RavonCore.configure(supabaseURL:supabaseAnonKey:)` at `RavonMerchantApp.swift:16-19`
**hardcodes both values in source**, including a legacy `HS256` anon JWT for
`<dead-ravon-project-ref>.supabase.co` (the dead project). Since the orchestrator established
that new Supabase projects sign **ES256**, this constant is not merely dead but
*wrong-algorithm* dead. Any extraction replaces this call site.

### 9.5 Zero local model copies

All 22 files `import RavonCore`; every model type comes from it (`Order`, `OrderStatus`,
`Restaurant`, `RestaurantStatus`, `RestaurantHours`, `MenuItem`, `MenuCategory`,
`ModifierGroup`, `ModifierOption`, `MerchantStats`, `OnboardingProgress`, `Profile`,
`ChatMessage`, `AddressSnapshot`, `CancellationReason`, `MenuCategoryTemplate`, plus
`Theme`/`RavonPrimaryButton`/`RavonTextField`/`cardStyle`/`Color.ravonRed`). §5's "leanest
app in the fleet" read is confirmed. One app-level `Layout` (`FlowLayout`,
`OnboardingView.swift:332`) which is genuinely presentational.

---

## 10. §5a — the reimplemented hours logic, and what it needs

### 10.1 The reimplementation, verified

`DashboardViewModel.swift`:
- `private static func dushanbeNow() -> (weekday: Int, hms: String, hourMinute: String)` `:123-132`
- `var isWithinHours: Bool` `:134-140`
- `var nextOpeningTime: String?` `:143-157`
- `func formatUntil(_:) -> String` `:160-165`

Consumed at `DashboardView.swift:119` (`if vm.isWithinHours`) and `:123`
(`if let next = vm.nextOpeningTime`), producing
`"⏰ Сейчас закрыто по расписанию"` at `:128`.

### 10.2 The past-midnight bug, confirmed

```swift
// DashboardViewModel.swift:139
return today.openingTime <= now.hms && now.hms < today.closingTime
```

`openingTime` / `closingTime` are `String` (`RestaurantHours.swift:10-11`), compared
lexicographically. For a restaurant open 18:00–02:00, `"02:00:00" < "18:00:00"`, so the
conjunction is **unsatisfiable** — `isWithinHours` is `false` 24 hours a day. At 20:00 on a
Friday the dashboard tells an open, order-taking restaurant it is closed. Late-night hours
are normal in Dushanbe. Confirmed.

`dushanbeNow()`'s weekday math is correct: `((comps.weekday ?? 1) - 1) % 7` maps Swift's
1=Sunday…7=Saturday onto the DB's 0=Sun…6=Sat, matching
`restaurant_within_hours`'s `EXTRACT(DOW …)` (`03_…:23-24`) and
`RestaurantHours.dayName` (`:35-46`).

Plus the **missing-today's-row** divergence in C8 (server says open, client says closed),
and a `<` vs `<=` boundary difference at the closing instant.

`nextOpeningTime` has a third, smaller defect: the loop `for offset in 1...7` with
`let d = (now.weekday + offset) % 7` (`:150-151`) includes `offset == 7`, which wraps back
to today — so a restaurant closed for the rest of today can be told it opens at today's
(already past) opening time.

### 10.3 Why the workaround happened, and what core must ship

§5a's diagnosis is right and worth preserving verbatim as the API lesson:

> core exposes `nextOpenAt` (a `Date?`) but no `isOpenNow`. `nextOpenAt` signals "open right
> now" by returning the *reference date itself*, which is a subtle calling convention —
> comparing a returned `Date` to `now` for equality is not an obvious API.

Confirmed at `RestaurantHours.swift:71-85`: inside the `offset == 0` arm,
`if inWindow { return reference }` (`:82`). A caller must do
`hours.nextOpenAt(from: now) == now` to learn "open now" — a `Date` equality comparison
against a value it passed in. No app will discover that.

**The ask is `isOpen(at:) -> Bool` on `Array where Element == RestaurantHours`.** But three
constraints on the implementation, because a naive one perpetuates the divergence:

1. **It must match `restaurant_within_hours` exactly**, including the two semantics in C8
   (missing-today's-row → **open**; `opening == closing` → **closed**, an intentional
   fully-closed marker per `03_…:41-43`) and the inclusive closing boundary (`<=`,
   `03_…:45-46`). The file's own header already says the server is the source of truth
   (`RestaurantHours.swift:3-5`: *"Server `restaurant_within_hours()` is the source of
   truth… Helpers below are for UI rendering only — never for blocking decisions."*). That
   comment is the contract; the helper has to honour it.
2. **`nextOpenAt` has its own past-midnight edge that `isOpen(at:)` will inherit if it
   shares the code.** `:74-81` resolves the pre-dawn tail against **today's** row
   (`reference >= startOfDay && reference <= close`). The server does the same
   (`03_…:48-50`, `tjk_time >= opening OR tjk_time <= closing` on today's DOW row). So
   "Monday 18:00–02:00" means *Monday's row also governs Monday 00:00–02:00*, **not**
   Sunday's late window. That is internally consistent and must be **ported deliberately**,
   because it is surprising: a restaurant open Mon 18:00–02:00 and closed Tuesday is
   reported **closed** at Tuesday 01:00, even though a human would say it is still open
   from Monday night. Whether that is the intended product semantic is a question, not a
   bug to silently fix — but client and server must not diverge on it, and today both
   agree.
3. **The eventual server side should be `isOpen` too.** `restaurant_within_hours` already
   exists and is already the arbiter for `create_order` (`04_…:50, 172`),
   `restaurant_is_orderable` (`03_…:67`), `get_restaurant_orderability` (`03_…:134`), and
   `activate_scheduled_orders` (`06_…:40`). A Kotlin port should expose it on the
   orderability response so the merchant dashboard **reads the server's answer** rather
   than recomputing it. That is the durable fix: the merchant app is the app that *authors*
   hours and should never be the app that disagrees about them.

Also worth folding in: §2f notes the day-of-week editor is built twice
(`RestaurantHoursView.DayEntry` and `Step5Hours.DayEntry`), each with its own `dayName`
switch, while `RestaurantHours.dayName` exists in core and is used correctly at
`SettingsView.swift:81`. Three copies of one 7-way mapping; the DOW convention (0=Sun) is
exactly the kind of off-by-one that a Kotlin port will get wrong once and ship everywhere.

---

## 11. Residual UNKNOWNs and open decisions

**UNKNOWN — needs live introspection** (no Ravon Supabase project exists):

1. Whether the merchant receives any Realtime events at all. `postgres_changes` filters are
   RLS-gated for the subscribing role and **no migration contains a policy on `orders`**.
   §6.2's entire filtered-feed advantage is contingent on this.
2. Whether `orders` currently has `REPLICA IDENTITY FULL`. Required by
   `RealtimeService.swift:181-183`, set in no migration.
3. Whether `restaurants.owner_id` exists, its type, nullability, FK, and index. Referenced
   in 5 places (including `SupabaseService.swift:1132`, the merchant's single most-called
   read) and created in no migration. **Prerequisite for all five merchant RPCs' auth checks.**
4. Whether an UPDATE policy on `orders` exists that permits the four client CAS writes. If
   it does not, the merchant's kitchen ops have been silently failing (empty result →
   `.invalidStatusTransition` → swallowed), which is indistinguishable from "no orders" on
   a dead backend. `order-lifecycle-spec.md` §7 flags the same contradiction.
5. The actual size ceiling enforced on the merchant image paths (`uploadRestaurantImage`
   `:1397`, `uploadMenuItemImage` `:1415`) vs the "5 МБ" in the UI vs the 500 KB at `:620`.
6. `get_merchant_stats`'s real return shape. `MerchantStats` decodes it, no SQL defines it.
7. Whether `.task` re-fires on `NavigationStack` pop (§6.1(b)) — needs a device, not a
   backend. Does not change the fix.

**Open decisions the extraction must make, not inherit:**

8. **Can the merchant cancel at `assigned` / `courier_arrived_restaurant`?** A courier is
   committed and `earnings_tier_for_cancel` would pay 25% / 50%. Allowing it means the
   merchant can unilaterally trigger a courier payout; forbidding it means a restaurant
   that has genuinely run out of food must wait for the courier to arrive and cancel. The
   parallel decision was already made for the courier
   (`CancellationReason.courierAllowed` includes `restaurantTooLongWait`) and for the
   system (30-min auto-cancel at 50%). There is no merchant answer yet.
9. **Money representation.** Integer minor units vs `Double` vs decimal string. §7.3
   recommends minor units; it is a fleet-wide, breaking decision.
10. **Rounding rule.** Three apps, three rules, measured. Pick one explicitly.
11. **`сомони` vs `сом.`** Merchant uses the full word 22×; courier uses both (5× full,
    10× abbreviated). Pick one.
12. **Migration numbering** — `01_`–`19_` in core vs `20260503051636_` in the merchant repo.
13. **Region.** APNs + a long-lived order stream from Dushanbe. The abandoned
    `Ravon_android/backend/fly.toml` says `primary_region = 'sjc'`; ~250 ms RTT is fine for
    a notification and questionable for a stream.
14. **Whether `OrderLifecycle` is adopted at all.** It is untracked, has zero production
    callers, and the merchant is pinned to a revision that predates it. Its merchant
    visible-set would delete three shipped features (§5.2). Adopting it is a
    four-bucket redesign, not a drop-in.

---

## 12. What the merchant needs from the extraction, ranked

Ordered by consequence, with who owns each.

| # | item | owner | blocks? |
|---|---|---|---|
| 1 | **`restaurants.owner_id`** — add, type, FK, index | server | **all 5 merchant RPCs' auth** |
| 2 | **Stop truncating money on the write path** (C2) — minimum: lossless field seeding + dirty-check; ideal: integer minor units | core + apps | silent data loss today |
| 3 | **4 merchant kitchen RPCs** with `ORDER_ALREADY_TERMINAL` + `cancellation_reason_code` in DETAIL, and `merchant_mark_order_ready` widened to include `assigned` / `courier_arrived_restaurant` (§2.4, §2.5) | server | revoking client UPDATE on `orders` |
| 4 | **`merchant_cancel_order`** (§4.3) — the first producer of `cancelled_by_restaurant` | server | merchant cannot cancel at all |
| 5 | **RLS / stream authorization for `orders`**, plus `REPLICA IDENTITY FULL` | server | whether realtime works at all |
| 6 | **Project the order payload** — drop `delivery_verification_code`, keep `verification_code` | server | field-level leak |
| 7 | **Session-scoped event stream** replacing four view-scoped channels, carrying the new-order event and stats deltas (§6.4) | server + apps | §2b, §2c, the 2,880/day poll |
| 8 | **`isOpen(at:)`** on `[RestaurantHours]`, semantics identical to `restaurant_within_hours` incl. the missing-row default (§10.3) | core | §5a; merchant deletes its copy same day |
| 9 | **5 new reason kinds** + `set_accepting_orders`'s missing DETAIL (§3.2, §3.3) | server + core | typed errors |
| 10 | **`ServiceError` exhaustive over merchant paths, with one tolerated `unknown` case** (§3.4) | core | collapsing 3 `mapError` copies |
| 11 | **APNs**: `device_tokens` table, outbox+worker sender, client capability (§6.4) | server + apps | locked-tablet alerting |
| 12 | **Tag `v1.0.0`** and repoint all three apps off the branch pin | core | reproducible builds |
| 13 | Collapse `toggleAcceptingOrders` into `setAcceptingOrders` (C3) — one-line deprecation | core | nothing |
| 14 | `get_merchant_stats` written from scratch | server | the dashboard |
| 15 | `fetchOnboardingProgress` / `fetchRestaurantPreview` → single RPCs (§9.3) | server | nothing; pure win |
| 16 | Fix `₽` at `OrdersView.swift:176` and the `[CANCELLED]` ASCII prefix (C6) | app | nothing |

**What is purely client-side and needs nothing from the extraction** — worth stating so the
server plan does not absorb it: §2a's widened status gates and the handoff bucket (§5.3),
rendering `OrdersViewModel.errorMessage`, keeping the three sheets open on failure, the
`hasLoadedOnce` alert gate, moving subscription lifetime off `.onDisappear`, and
onboarding resume-to-step-5. The STATE-REPORT's §7 call — make the handoff window visible,
then make order-action failures visible, both ahead of migration-20 adoption — is correct
and independent of everything above.
