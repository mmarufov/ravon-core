# ravon-courier → constraints on a Kotlin backend extraction

Source read in full: `/Users/mmarufov/conductor/workspaces/ravon-courier/buffalo/.context/STATE-REPORT.md`
(38,828 bytes) plus `/Users/mmarufov/conductor/workspaces/ravon-courier/buffalo/CLAUDE.md`.

Every claim below was re-verified against the actual files. Courier repo is on branch
`mmarufov/buffalo-v1`, working tree **clean**, so line numbers in the report should have
matched exactly; where they didn't I say so. RavonCore verified in this worktree
(`/Users/mmarufov/conductor/workspaces/ravon-core/bucharest`), whose `Sources/` is
content-identical to the pinned `a1e9d6c8` the courier app builds against.

**Migrations ARE readable** at `/Users/mmarufov/conductor/workspaces/ravon-core/bucharest/.context/migrations/`
(01–19). The STATE-REPORT treats them as known-but-unquoted; I read them, which turned
several of its inferences into hard facts and overturned two.

---

## 0. The apparent contradiction in §6, resolved

The report says two things that look incompatible:

- "The courier app contains **no** Supabase query construction of any kind."
- "direct writes to `courier_locations`, three of them"

**Both are true, and the reconciliation is the single most important structural fact for
the extraction.** Verified:

```
$ grep -rn 'import Supabase' RavonCourier/          → 0 hits
$ grep -rnE '\.from\(|\brpc\(|\.upsert\(|\.insert\(|\.update\(' RavonCourier/
→ 6 hits, ALL of them `ServiceError.from(serverError:)`. Zero query builders.
$ grep -rln 'import RavonCore' RavonCourier/ | wc -l → 27 of 28 Swift files
```

The courier app has **no Supabase SDK dependency in its own source at all**. It cannot
construct a query. But `RavonCore.SupabaseService` is a **flat, public, 1,400-line
facade that mixes RPC wrappers and raw PostgREST table operations behind
indistinguishable method names**. `SupabaseService.shared.goOnline(latitude:longitude:)`
looks exactly like `SupabaseService.shared.claimOrder(orderId:)` from the call site; one
is `PATCH /courier_locations`, the other is `POST /rpc/claim_order`. The courier app is
therefore *simultaneously* free of direct writes (in its own code) and performing direct
writes (through core).

**Consequence for extraction:** the courier client's coupling surface is not "Supabase" —
it is exactly the 26 `SupabaseService` method names it calls. Swap the bodies of those 26
methods to HTTP calls against a Kotlin service and the courier app needs **zero** source
changes beyond typed-error handling. This makes courier (tied with merchant) the cheapest
client to cut over, contradicting the brief's claim that merchant is uniquely easiest —
courier has 0 `import Supabase` too, as the orchestrator already established.

### Complete list of courier-reachable mutations (the real §6)

Every one of these is a **direct table/storage write reachable from the courier app**,
with the courier-side call site and the core implementation site.

| # | Table / target | Op | Core impl | Courier call site |
|---|---|---|---|---|
| 1 | `courier_locations` | `UPSERT` (onConflict `courier_id`), sets `is_online=true` | `Sources/RavonCore/Services/SupabaseService.swift:730-732` (`goOnline`) | `Views/Home/HomeView.swift:342` |
| 2 | `courier_locations` | `UPDATE {is_online:false}` | `SupabaseService.swift:739-742` (`goOffline`) | `HomeView.swift:365` |
| 3 | `courier_locations` | `UPDATE {current_order_id:null}` | `SupabaseService.swift:829-832` (`clearCurrentOrder`) | `HomeView.swift:386` |
| 4 | `chat_messages` | `INSERT` | `SupabaseService.swift:1060-1065` (`sendMessage`) | `Views/Chat/ChatViewModel.swift:50` |
| 5 | `chat_messages` | `UPDATE {read_at: <client clock>}` | `SupabaseService.swift:1084-1089` (`markMessagesAsRead`) | `ChatViewModel.swift:61` |
| 6 | Storage bucket `delivery-proofs` | `PUT` object | `SupabaseService.swift:623-624` (`uploadDeliveryProof`) | `Services/OrderService.swift:142` |

**LOUD CORRECTION #1 — the report's §6 write table is incomplete.** It lists three
(`courier_locations` only) and states them as the complete answer to "any place you set
state outside an `rpc(...)` call." It misses **#4, #5 and #6**. `chat_messages` INSERT and
UPDATE are both reachable from the courier chat screen and both are raw PostgREST.
If "no direct client writes, ever" is the invariant being established, the count is six,
not three.

**#5 is a ledger-class defect in its own right:** `read_at` is stamped from the *client's*
`Date()` (`SupabaseService.swift:1085` → `Self.isoFormatter.string(from: Date())`). A
courier with a skewed phone clock writes a wrong or future read receipt. Same failure
family as the earnings boundary in §5 below: **client-authored timestamps in
server-authoritative rows.** A Kotlin extraction must make every timestamp server-minted.

### Courier-reachable reads (also all raw PostgREST)

| Table | Core impl | Notes |
|---|---|---|
| `orders` | `SupabaseService.swift:774-780` (`fetchAvailableOrders`, no-arg) | the offer feed — see §2 |
| `orders` | `SupabaseService.swift:813-820` (`fetchActiveOrder`) | `eq courier_id`, excludes 6 terminal statuses (note: **omits `cancelled_by_courier`**) |
| `orders` | `SupabaseService.swift:284` (`fetchOrder`) | by id |
| `courier_locations` | `SupabaseService.swift:749-754` (`fetchCourierStatus`) | `HomeView.swift:378` |
| `courier_cancellation_log` | `SupabaseService.swift:603` (`fetchCancellationCooldownStatus`) | `OrderService.swift:198` |
| `courier_earnings` | `SupabaseService.swift:848-870` (`fetchEarnings`) | see §5 |
| `profiles` | `SupabaseService.swift:147` (`fetchProfile`) | `ProfileService.swift:17`, wrapped in `try?` |
| `chat_messages` | `SupabaseService.swift:1072`, `:1096` | `fetchMessages`, `fetchUnreadCount` |

**Zero `orders` writes are reachable from courier — confirmed.** Core's five direct
`orders` UPDATEs (`SupabaseService.swift:395` acceptOrder, `:410` startPreparing, `:424`
rejectOrder, `:440` markOrderReady, `:643` assignCourier) are all merchant-side and none
appear in the courier's 26-method call list. The report is right that dropping the
`orders` UPDATE policy is transparent to this app.

### RLS: what the migrations actually say

- **No `CREATE POLICY` for `courier_locations` in migrations 01–19.** Verified by
  exhaustive grep. The report's claim holds. Writes #1–#3 are governed by baseline
  policies not in any file → **UNKNOWN — needs live introspection** (and the project
  does not exist, so this cannot be resolved now).
- **No `CREATE POLICY` for `orders` either.** The report's §6 Caveat 1 asks you to check
  whether the courier SELECT policy is `courier_id = auth.uid() OR courier_id IS NULL`.
  That is **not answerable from the repo** → UNKNOWN.
- Policies that *do* exist in files: `menu_items` (mig01:21,36), `menu_categories`
  (mig01:48,57), `courier_cancellation_log` (mig09:54), `chat_messages` (mig15:46,63,80).
  So write #5 is at least policy-gated; #1–#3 are not verifiably gated by anything.
- **Zero `REVOKE` statements and zero `ALTER DEFAULT PRIVILEGES` across all 19
  migrations.** Postgres grants `EXECUTE` on new functions to `PUBLIC` by default and
  Supabase does not revoke it. So every `SECURITY DEFINER` function in these migrations
  is presumptively callable by `anon` and `authenticated` regardless of the explicit
  `GRANT` lists. The most dangerous instance:
  `insert_courier_earning_for_cancel(p_order_id, p_courier_id, p_status_at_cancel,
  p_reason_code, p_tier_override, p_earning_type_override)` at
  `.context/migrations/12_tiered_earnings_columns_and_helpers.sql:60-99` — `SECURITY
  DEFINER`, **no `auth.uid()` check at all**, takes an arbitrary `p_courier_id` and an
  **unbounded `p_tier_override`**, and writes `courier_earnings` with
  `total_earned = round(delivery_fee * tier / 100.0, 2)`. Tier 100000 mints 1000× the fee
  to any courier id. Not in the STATE-REPORT. This is the strongest single argument that
  money mutations must move behind a service that owns the DB credential.
  (Whether `PUBLIC EXECUTE` is actually in force is UNKNOWN without live introspection,
  but nothing in the repo revokes it.)

---

## 1. The offer feed: what actually feeds it (report §2b) — Phase 1's real target

`fetch_available_orders` the RPC is called **zero** times. Verified:

```
$ grep -rn 'radiusKm' RavonCourier/      → 0 hits
```

The production offer feed is a three-link chain, all verified:

**Link 1 — the wake signal is an UNFILTERED realtime subscription on the whole `orders`
table.** `Sources/RavonCore/Services/RealtimeService.swift:381-425`:

```swift
let channel = client.channel("available-orders")
let changes = channel.postgresChange(AnyAction.self, schema: "public", table: "orders")
```

No `filter:`. Compare every sibling subscription in the same file, which all filter
(`:118` `.eq("id")`, `:154` `.eq("restaurant_id")`, `:209` `.eq("courier_id")`, `:250`,
`:306`, `:347`, `:437`). `.insert` and `.update` are both handled (`:398`, `:401`);
`.delete` is skipped (`:404`).

**Link 2 — the handler discards the event and re-fetches everything.**
`Views/Home/HomeView.swift:91-100`:

```swift
.onReceive(RealtimeService.shared.$lastAvailableOrderChange.compactMap { $0 }) { _ in
    guard dashState.isLookingForOrders else { return }
    Task {
        let orders = try? await SupabaseService.shared.fetchAvailableOrders()
        if let order = orders?.first { dashState = .offerShown(order) }
    }
}
```

The `{ _ in }` throws away the `OrderChangeEvent` (which carries `orderId`, `oldStatus`,
`newStatus`, and the full `record`) and issues a fresh full-table SELECT.

**Link 3 — the SELECT.** `Sources/RavonCore/Services/SupabaseService.swift:773-781`:

```swift
/// Fetch all available orders without location filter (for testing / fallback)
public func fetchAvailableOrders() async throws -> [Order] {
    try await client.from("orders")
        .select("*, restaurants(*), order_items(*)")
        .is("courier_id", value: nil)
        .in("status", values: ["accepted", "preparing", "ready"])
        .order("created_at")
        .execute().value
}
```

Offer selection = `.first` of `ORDER BY created_at ASC` = **the oldest unassigned order in
the country**, identically for every courier.

**Call-site count — LOUD CORRECTION #2.** The report says "**six** places (HomeView ×4,
OrderOfferView ×2)". Actual: **nine**. `HomeView.swift:95, 303, 349, 399, 423, 435`
(six, not four), `OrderOfferView.swift:173, 183` (two), and `OrderService.swift:63`
(the app's own service layer, reached from the dead `AvailableOrdersView.swift:33,53`).

**Radius — LOUD CORRECTION #3.** The report says "The 50 km `ST_DWithin` default is dead
code." The 50 km is the **SQL** default
(`13_courier_status_transition_rpcs_v2.sql:718`: `p_radius_km double precision DEFAULT
50.0`). The **Swift** wrapper overrides it to **10.0** km
(`SupabaseService.swift:787`). Two different dead defaults, 5× apart. Whoever writes the
Kotlin dispatch radius needs to know which was intended; the repo does not say.

**What the RPC would actually give you** (`mig13:715-736`, verified in full):
`SECURITY DEFINER`, `STABLE`, `LANGUAGE sql`, `RETURNS SETOF orders`, filtering
`courier_id IS NULL AND status IN ('accepted','preparing','ready') AND NOT (auth.uid() =
ANY(excluded_courier_ids)) AND ST_DWithin(restaurant_point, courier_point, radius)`,
`ORDER BY o.created_at`. Note the proximity is **courier → restaurant**
(`ST_MakePoint(r.longitude, r.latitude)`), not courier → customer.

**LOUD CORRECTION #4 — switching to the RPC does NOT close the PII hole the report says
it closes.** `RETURNS SETOF orders` returns *every column of `orders`*, including
`delivery_address_snapshot`, **`verification_code`** (the pickup code) and
**`delivery_verification_code`** (the customer's hand-off code). Verified: both columns
exist (`10_dual_verification_codes_and_delivery_mode.sql:13` and the pre-existing
`verification_code`), and `Sources/RavonCore/Models/Order.swift:341-342` decodes both
from `select("*")`. So today, *and* after the recommended fix, **any authenticated
courier receives the pickup and hand-off codes for every unassigned order** (today:
nationwide; after: within the radius). A courier who reads the delivery code from the
offer feed can complete `courier_deliver_order` in `hand_to_me` mode without ever meeting
the customer — the entire dual-code design is defeated by the read path. Codes are
`lpad(floor(random() * 9000 + 1000)::text, 4, '0')` (mig10:37-43) — 9,000 values, non-CSPRNG.

This is the load-bearing requirement for Phase 1: **the offer feed must become a projection
that omits codes and omits address snapshots for orders the courier has not claimed.**
Neither the current SELECT nor the current RPC can do that, because both return whole rows.

### Fanout: why this is a scalability constraint, not just a correctness one

`update_courier_heartbeat` (`mig13:72-140`) ends with:

```sql
UPDATE orders SET eta_minutes = compute_eta_minutes(orders.id), updated_at = now()
WHERE courier_id = v_uid AND status IN ('assigned','courier_arrived_restaurant',
                                        'picked_up','delivering','courier_arrived_customer');
```

Every heartbeat writes `orders`. Every `orders` write fires the **unfiltered**
`available-orders` realtime channel. Every idle courier on that channel then runs a full
`orders` scan returning every unassigned order with all columns. With `A` active
deliveries heartbeating at the 5 s `picked_up`/`delivering` cadence and `C` idle couriers,
that is `A × C / 5` full-table SELECTs per second. Not in the STATE-REPORT; verified from
the two files above. A Kotlin dispatch service replacing this must own offer *push*
(per-courier, filtered), not offer *polling*.

### What a Phase 1 dispatch service must therefore own

1. **Per-courier offer assignment.** Today every courier is shown the same oldest order.
2. **Decline / exclusion state.** Today it lives nowhere (§3 below).
3. **A projection type.** Not `SETOF orders`. No codes, no unclaimed-order addresses.
4. **A wake channel.** Today: unfiltered realtime, foreground-only, no push.
5. **Proximity semantics + one radius.** Courier→restaurant; 10 vs 50 km unresolved.

---

## 2. Wrong pickup code → raw Postgres error (report §2d), mapped to the typed-error design

### Verified exactly

`Views/Delivery/ActiveDeliveryView.swift:596-613`, the `.courierArrivedRestaurant` button:

```swift
try await orderService.pickUpOrder(pickupCode: pickupCode)
pickupCode = ""
showPickupCodeError = false
} catch let error as ServiceError {            // line 604 — never matches
    if case .invalidVerificationCode = error {
        showPickupCodeError = true             // line 606 — unreachable
    } else {
        showToast(error.errorDescription ?? "Ошибка")
    }
} catch {
    showToast(error.localizedDescription)      // line 611 — NO ServiceError.from() call
}
```

Report line range `604-612` is correct. The inline string the user never sees is at
`ActiveDeliveryView.swift:463-464`: `"Неверный код. Попросите ресторан назвать ещё раз."`
(the report quotes this correctly, but note it is the *view's* string, not
`ServiceError.invalidVerificationCode.errorDescription`, which is
`"Неверный код подтверждения"` at `SupabaseService.swift:47` — two different Russian
strings for the same condition).

The five call sites that *do* call `ServiceError.from(serverError:)`:
`OrderOfferView.swift:156`, `ActiveDeliveryView.swift:737, 745, 779, 810`. Plus one in
dead code, `OrderRowView.swift:203`. The pickup handler is the one that forgot. Confirmed.

### The server side of the contract

`courier_pickup_order` (`mig13:258-299`) raises, in order:
`ORDER_NOT_FOUND` → `UNAUTHORIZED` (courier mismatch) → `ORDER_NO_LONGER_PICKUPABLE`
(+ `'status'`) → `INVALID_VERIFICATION_CODE`. All as
`RAISE EXCEPTION ... USING ERRCODE='P0001', DETAIL=jsonb_build_object('reason', <CODE>, ...)::text`.

### LOUD CORRECTION #5 — the taxonomy is 33 cases, not 24

The report says "a 24-case `ServiceError` enum". Verified count at
`Sources/RavonCore/Services/SupabaseService.swift:5-38`: **33 cases** (21 original + 12
"Umbrella II — courier hardening"). `from(serverError:)` at `:90-127` maps **18** wire
reason strings.

The migrations raise **29 distinct** reason codes. So **11 server reason codes have no
mapping**: `RESTAURANT_CLOSED`, `RESTAURANT_PAUSED`, `RESTAURANT_NOT_ACCEPTING`,
`OVERLOADED`, `OUT_OF_HOURS`, `INSUFFICIENT_STOCK`, `ITEM_UNAVAILABLE`,
`MIN_ORDER_NOT_MET`, `SCHEDULED_TIME_INVALID`, `INVALID_EXTRA_MINUTES`,
`ROLE_CHANGE_FORBIDDEN`.

**`INVALID_EXTRA_MINUTES` is courier-reachable and unmapped.** It is raised by
`courier_report_restaurant_delay` (`16_no_show_and_restaurant_delay.sql:92-94`, when
`p_extra_minutes` is null, ≤0, or >15) — an RPC the courier app calls
(`OrderService.swift:188`). Even after the `callRPC` wrapper fix, this path will still
show a raw error, because there is no enum case to map to. The report's "one hour in core"
estimate for `callRPC` does not include closing these 11 gaps.

### LOUD CORRECTION #6 — a second dead branch the report missed, and it's on the accept path

`OrderOfferView.swift:147` and `:157` both test for `ServiceError.orderAlreadyClaimed`
to show `"Заказ уже занят другим курьером"`. **No server reason code maps to
`.orderAlreadyClaimed`.** `from()` (`SupabaseService.swift:106-126`) has no
`ORDER_ALREADY_CLAIMED` case, and `claim_order` raises `ORDER_NO_LONGER_PICKUPABLE` for
an already-taken order (`mig13:199-200`) which maps to `.orderNoLongerPickupable`
(`:109`). So the race-loss message a courier hits most often is unreachable **even after
the `callRPC` fix**; they get the generic `"Заказ больше недоступен"`. Two-courier races
are also item 2 on the report's own "cannot test" list, which is why nobody noticed.

### The structural defect for a Kotlin port

`from(serverError:)` is a **regex over `String(describing: error)`**
(`SupabaseService.swift:95-105`, pattern `#""reason"\s*:\s*"([A-Z_]+)""#`). It therefore
discards every structured field the server took care to send:

| Server sends (verified in migrations) | Swift keeps |
|---|---|
| `COURIER_SUSPENDED` + `'until', v_susp` | `.courierSuspended(until: nil)` — `:112` |
| `COURIER_CANCEL_COOLDOWN` + `'recent_cancels', v_recent` | `.courierCancelCooldown(recentCancels: 3)` — hardcoded, `:114` |
| `ACCURACY_TOO_LOW` + `'accuracy', p_accuracy_meters` | `.accuracyTooLow(meters: 0)` — `:118` |
| `INVALID_REASON_CODE` + `'code', p_reason_code` | `.invalidReasonCode("")` — `:117` |
| `ORDER_NO_LONGER_PICKUPABLE` + `'status', v_status` | `.orderNoLongerPickupable` — payload dropped |
| `COURIER_ALREADY_HAS_ACTIVE_ORDER` + `'order_id'` | `.courierBusy` — payload dropped |
| `MIN_ORDER_NOT_MET` + `'need', r.min_order_amount` | unmapped entirely |
| `ITEM_UNAVAILABLE` + `'menu_item_id'` | unmapped entirely |

**Kotlin design requirement:** emit a real JSON error envelope
(`{"code": "...", "params": {...}}`) with an HTTP status, decoded by a generated
client type. Do not reproduce "Postgres `DETAIL` blob scraped by regex." The server
already knows the payload; the transport is what loses it. Every parameterised Russian
string in `errorDescription` (`SupabaseService.swift:70-82`) is a placeholder waiting for
data the decoder threw away.

One more contradiction worth carrying over: `uploadDeliveryProof` enforces
`jpegData.count <= 500 * 1024` and throws `ServiceError.imageTooLarge`
(`SupabaseService.swift:620`), whose message is `"Изображение слишком большое (макс. 5 МБ)"`
(`:57`). A 1 MB photo is rejected with a message stating a 5 MB limit — 10× off.

---

## 3. The decline-button loop (report §2a): yes, it needs an RPC that does not exist

**Verified, exactly as reported.** `Views/Delivery/OrderOfferView.swift:168-178`:

```swift
private func declineOffer() {
    timer?.invalidate()
    Task {
        dashState = .lookingForOrders
        try? await Task.sleep(for: .seconds(3))
        let orders = try? await SupabaseService.shared.fetchAvailableOrders()
        if let next = orders?.first { dashState = .offerShown(next) }
    }
}
```

No server call. `fetchNextOffer()` at `:180-188` is byte-identical minus the sleep. The
30 s auto-expire (`:127-137`, `timeRemaining` initialised to `30` at `:9`) calls
`declineOffer()`. Since the feed is `ORDER BY created_at ASC` and selection is `.first`,
**the same order is re-offered indefinitely.**

**Does the server RPC exist? No.** Exhaustive enumeration of every
`CREATE [OR REPLACE] FUNCTION` across migrations 01–19 yields 34 function definitions
(some re-created across files). There is **no `courier_decline_order`** and nothing
equivalent. Confirmed against the orchestrator's 21-RPC Swift list too.

**The server mechanism exists but has no entry point.** `orders.excluded_courier_ids`
(added mig11) is:
- **appended** by `cancel_order_by_courier` (`mig13:543`) and by
  `reassign_ghosted_order` (`mig13:698-702`);
- **read** by `fetch_available_orders` (`mig13:730`) and by `claim_order` (`mig13:201-204`,
  raising `COURIER_EXCLUDED_FROM_ORDER`).

So a decline cannot write it, and the read path that would honour it is never called.
The report's compound-loop case is real and verifiable from these four sites:
self-cancel → exclusion appended → feed ignores exclusion → same order re-offered →
`claim_order` raises `COURIER_EXCLUDED_FROM_ORDER` → toast → re-offer.

**Kotlin requirement (Phase 1, non-negotiable):** decline must be a server-side, durable,
*per-courier-per-order* fact with a TTL. `excluded_courier_ids uuid[]` on `orders` is the
wrong shape for it — an unbounded array column mutated concurrently by competing couriers
is a write-contention hotspot and cannot express "re-offer after 10 minutes" or
"declined 3× → deprioritise this courier." A dispatch service wants an
`offer(order_id, courier_id, offered_at, responded_at, outcome)` table, which also gives
you the accept-rate signal the report notes is being thrown away.

---

## 4. RPC reachability from this client today (report §2g)

Report's matrix re-verified method-by-method against
`Sources/RavonCore/Services/SupabaseService.swift` and the courier call-site grep.
The 26 core methods the courier app calls are:

```
cancelOrderByCourier  claimOrder  clearCurrentOrder  courierArrivedAtCustomer
courierArrivedAtRestaurant  deliverOrder  explainDelay  fetchActiveOrder
fetchAvailableOrders  fetchCancellationCooldownStatus  fetchCourierStatus
fetchEarnings  fetchMessages  fetchOrder  fetchProfile  fetchUnreadCount
goOffline  goOnline  markMessagesAsRead  pickUpOrder  reportCustomerNoShow
reportProblemPostPickup  reportRestaurantDelay  sendMessage  startDelivering
uploadDeliveryProof
```

**RPCs reachable from the courier client today — 12:**

| RPC | Core wrapper | Courier entry point |
|---|---|---|
| `claim_order` | `SupabaseService.swift:763` | `OrderService.swift:83` ← `OrderOfferView.swift:144` |
| `courier_arrived_restaurant` | `:453` | `OrderService.swift:97` |
| `courier_pickup_order` | `:458` | `OrderService.swift:106` |
| `courier_start_delivering` | `:465` | `OrderService.swift:113` |
| `courier_arrived_at_customer` | `:470` | `OrderService.swift:123` |
| `courier_deliver_order` | `:488` | `OrderService.swift:133` (code) and `:143` (proof) |
| `cancel_order_by_courier` | `:503` | `OrderService.swift:154` |
| `report_problem_post_pickup` | `:521` | `OrderService.swift:163` |
| `courier_explain_delay` | `:538` | `OrderService.swift:172` |
| `courier_report_customer_no_show` | `:547` | `OrderService.swift:182` |
| `courier_report_restaurant_delay` | `:558` | `OrderService.swift:188` |
| `update_courier_heartbeat` | `:580` | **indirect only** — `CourierLocationStreamer.swift:71`, never named in courier source |

**Not reachable — 2:**
- `fetch_available_orders` — wrapper exists (`:784-799`), zero call sites. §1.
- `reassign_ghosted_order` — **no Swift wrapper at all**, yet
  `GRANT EXECUTE ... TO authenticated` (`mig13:751`). Any courier can POST it against any
  order id. Confirmed; the report is right to flag it beside `compute_eta_minutes`
  (also granted to `authenticated`, `mig13:739`).

Also explicitly granted to `authenticated` and callable by any courier, not in the
report's matrix: `mark_no_show_deliveries()` and `run_courier_escalation_ladder()` — the
mig14 **cron** functions. Plus, via default `PUBLIC EXECUTE`, everything ungranted (§0).

**Extraction reading:** the 12 reachable RPCs are already a clean command surface — each
is a single named verb with typed params and a typed error. They port to Kotlin endpoints
almost mechanically. The 15 direct table ops (§0) are the part with no contract. Phase 1
should invert this: the 12 stay verbs, the 15 become server-owned.

---

## 5. Earnings timezone — ledger correctness (report §5)

The report's §5(a) is correct and I can make it exact.
`Sources/RavonCore/Services/SupabaseService.swift:844-871`:

```swift
var query = client.from("courier_earnings").select().eq("courier_id", value: uid.uuidString)
let formatter = ISO8601DateFormatter()
switch period {
case .today: let startOfDay = Calendar.current.startOfDay(for: Date())       // :855
             query = query.gte("created_at", value: formatter.string(from: startOfDay))
case .week:  let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!   // :858
case .month: let monthAgo = Calendar.current.date(byAdding: .month, value: -1, to: Date())! // :861
case .all:   break
}
```

**Precise statement of the defect.** `ISO8601DateFormatter()` defaults to GMT, so the
*instant* is serialised correctly; nothing is lost in transport. The bug is solely that
`Calendar.current` resolves the **device's** timezone when computing which instant is
midnight. Dushanbe is UTC+5 with no DST. With the device in America/Los_Angeles (PDT,
UTC−7) the offset is exactly 12 h:

- Correct "today" window for Dushanbe day *D*: `[D 19:00 UTC−1day, now]`.
- Actual window sent: `[D 07:00 UTC, now]`.
- **The first 12 hours of the Dushanbe business day (00:00–12:00 local) are silently
  excluded from "Сегодня".**

The report's §5(a) point that `.week`/`.month` are **rolling offsets from `now`**, not
calendar boundaries, is verified — `byAdding:` on an instant is timezone-invariant, so
pinning the calendar to `Asia/Dushanbe` changes lines 858/861 by exactly zero, and
Dushanbe's lack of DST means even the `.month` arithmetic is unaffected. A diff that pins
all three looks complete and fixes one bug. Correct. `Calendar.firstWeekday` also matters
if 858/861 are converted to real boundaries (TJ = Monday).

**Additional ledger constraints I verified that the report does not state.** These matter
more for a Kotlin extraction than the timezone itself:

1. **The period boundary is entirely client-determined.** There is no server-side
   aggregation anywhere. `fetchEarnings` is a PostgREST `GET /courier_earnings` with a
   **client-supplied `gte` timestamp**, and the summary is computed in Swift. Two
   independent summations exist: core's `fetchEarningsSummary`
   (`SupabaseService.swift:873-881`) and courier's `EarningsService.computeSummary`
   (`Services/EarningsService.swift:47-56`), which shadows core because core omits
   `totalClawbacks`. **Any client, or anyone with the anon key and a JWT, chooses its own
   period boundaries.** Move the boundary server-side or the ledger has no canonical day.

2. **`courier_earnings` is not append-only — it is one mutable row per order.**
   `insert_courier_earning_for_cancel`
   (`12_tiered_earnings_columns_and_helpers.sql:84-98`) ends with
   `ON CONFLICT (order_id) DO UPDATE SET earning_type=…, tier_pct=…, total_earned=…,
   cancellation_reason_code=…, status_at_event=…`. A clawback therefore **overwrites** the
   prior partial-pay row in place rather than posting a compensating entry. History is
   destroyed; there is no way to reconstruct what the courier was told they earned. For a
   ledger extraction this is the headline constraint: **the existing table is current-state,
   not a journal.** A Kotlin ledger needs append-only entries with a derived balance.

3. **Money is `Double` end to end.** `CourierEarning.deliveryFee`, `.tipAmount`,
   `.totalEarned` are all `Double` (`Sources/RavonCore/Models/CourierEarning.swift:30-32`)
   and both summaries are float reductions. The server stores `numeric` and rounds to
   2 dp (`mig12:81`: `round((v_delivery_fee * v_tier / 100.0)::numeric, 2)`). Kotlin should
   use minor units (integer dirams) or `BigDecimal`.

4. **`totalDeliveries` over-counts.** Both summaries use row count
   (`SupabaseService.swift:876` and `EarningsService.swift:50`). A clawback row, a
   `no_show_compensation` row, and a `manual_adjustment` row each increment "Доставки."
   The `ON CONFLICT` in #2 masks this within one order, but `courier_deliver_order`'s own
   trigger-inserted row and a manual adjustment on a different order will both count.

5. **`totalDeliveryFees` double-counts on partial tiers.** `insert_courier_earning_for_cancel`
   writes `delivery_fee = v_delivery_fee` — the **full** fee — while
   `total_earned = fee × tier/100` (mig12:80-90). Summing `deliveryFee` across a
   25%-tier cancellation therefore reports 100% of the fee under "fees earned."
   Tier table (`mig12:35-45`): `assigned`→25, `courier_arrived_restaurant`→50,
   `picked_up`/`delivering`/`courier_arrived_customer`→100, else 0.

6. **`.all` is an unbounded query with no pagination** (`SupabaseService.swift:863-864`
   `break`, then `:867-870` unbounded `.order().execute()`). PostgREST silently truncates
   at the project's `max-rows` setting. Actual value → UNKNOWN — needs live introspection.
   A lifetime-earnings screen that silently caps is a ledger defect.

**Device-timezone renderings that will disagree with a fixed boundary** — all verified,
all report line numbers correct:

| Site | Code | Renders |
|---|---|---|
| `Views/Earnings/EarningsView.swift:138` | `Text(earning.createdAt, style: .time)` | per-row delivery time, device TZ |
| `Views/Delivery/ActiveDeliveryView.swift:887-891` | bare `DateFormatter`, `dateFormat = "HH:mm"`, no `timeZone` | cancel-cooldown expiry |
| `Views/Profile/SuspensionBlocker.swift:42-47` | `DateFormatter`, `locale = ru_RU`, **no `timeZone`** | suspension end |
| `Sources/RavonCore/Services/SupabaseService.swift:72-74` | inside `ServiceError.courierSuspended`, `dateFormat = "HH:mm"`, no `timeZone` | **core's own string** — report missed this one |

The report's recommendation (export a `Asia/Dushanbe` `Calendar` + formatter from core,
noting `RestaurantHours.swift:57` and `CartValidation.swift:86` already build one inline)
is sound, but the fourth row above means core must consume it too, exactly as with currency.

`EarningsView` itself does **no** client-side bucketing — verified: no `Calendar`, no
`startOfDay`, no grouping; it renders server order and reduces. So a server-side boundary
will not fight client arithmetic. Confirmed.

Finally, the report's non-timezone trap is real: `HomeView.swift:156-164`
(`todayEarningsCard`) reads `earningsService.summary` — the **same singleton**
`EarningsView` mutates via `setPeriod` (`EarningsService.swift:29-34`). Switch the
Earnings tab to "Месяц", return Home, and the "today" card shows the month total with no
label. Will be misdiagnosed as a timezone bug.

---

## 6. Currency: exact rendering and rounding (report §7)

**LOUD CORRECTION #7 — 15 sites, not 14.** The report's `сом.` table lists 9; there are
**10**. It misses `Views/Orders/OrderRowView.swift:114`
(`Text("\(item.totalPrice, specifier: "%.0f") сом.")`, the per-line-item price in
`OrderDetailSheet`). Full re-verified enumeration:

**Shape everywhere:** integer, zero decimals, unit *after* the number, one ASCII space,
no currency symbol. Three mechanisms, two spellings.

`сомони` (full word) — **5 sites**:

| file:line | expression |
|---|---|
| `Views/Home/HomeView.swift:159` + `:162` | `Text(String(format: "%.0f", …totalEarned))` over `Text("сомони")` — two stacked `Text`s (`.title`.bold / `.caption`.secondary); the only site where the unit is not inline |
| `Views/Delivery/ActiveDeliveryView.swift:145` | `"Заработано: \(String(format: "%.0f", order.deliveryFee)) сомони"` |
| `Views/Delivery/ActiveDeliveryView.swift:149` | `"Чаевые: \(String(format: "%.0f", tip)) сомони"` |
| `Views/Delivery/OrderOfferView.swift:81` | `"\(String(format: "%.0f", order.deliveryFee)) сомони"` |
| `Views/Onboarding/OnboardingView.swift:127` | hardcoded literal `"50 сомони"` (mock offer card) |

`сом.` (abbreviated, trailing period) — **10 sites**:

| file:line | mechanism |
|---|---|
| `Views/Earnings/EarningsView.swift:63` | `String(format: "%.0f сом.", summary.totalEarned)` |
| `Views/Earnings/EarningsView.swift:80` | `specifier: "%.0f"` (`totalClawbacks`, rendered positive with a minus-circle icon) |
| `Views/Earnings/EarningsView.swift:125` | `specifier: "%.0f"` (`tipAmount`) |
| `Views/Earnings/EarningsView.swift:155` | `.formatted(.number.precision(.fractionLength(0)))`, prefixed `+` when `>= 0` |
| `Views/Delivery/ActiveDeliveryView.swift:262` | `specifier: "%.0f"` |
| `Views/Orders/OrderRowView.swift:37, 60, 114, 139, 145` | `specifier: "%.0f"` — dead file, but see the `itemsRu` trap below |

Zero `₽` and zero `руб` in the courier app — verified. The rouble is core-side only
(orchestrator already established `CartValidation.swift:79` and `SupabaseService.swift:60`;
`:60` is `ServiceError.minOrderNotMet`, a shared user-facing string).

### Rounding — measured, not assumed

All three mechanisms round **half-to-even**, not half-up. `String(format: "%.0f", …)` and
SwiftUI `specifier: "%.0f"` both go through libc `printf`; `.formatted(.number
.precision(.fractionLength(0)))` uses Foundation's default `.toNearestOrEven`. Measured on
this machine:

```
$ printf '%.0f %.0f %.0f %.0f %.0f\n' 0.5 1.5 2.5 12.5 13.5
0 2 2 12 14
```

So the *rounding rule* is already uniform. Two things are not:

1. **Grouping.** `EarningsView.swift:155` is the only site using `.formatted(.number)`,
   which applies **locale grouping**. A 1,500-somoni day renders `+1 500 сом.` in the row
   and `1500 сом.` in the summary card two inches above (`:63`, `String(format:)`), from
   the same underlying number. Russian locale uses a narrow no-break space (U+202F/U+00A0),
   which is also a string-comparison hazard in tests.
2. **Round-then-sum vs sum-then-round.** The server stores 2-dp `numeric`
   (`mig12:81` `round(…, 2)`); every client site renders 0 dp. Three 12.50 rows display
   `12 12 12` (half-even) while the summary displays `round(37.50) = 38`. **The total never
   equals the sum of the visible rows.** Concrete, reproducible, and a ledger-trust problem
   the moment a courier adds up their own screen.

**Negative shape is undefined.** `EarningsView.swift:153-156` prefixes `+` only when
`>= 0`, letting `-` fall out of the number, while `:80` renders the same magnitudes as a
*positive* `"Удержания: N сом."` with a minus icon. Two renderings of one sign convention.

**Kotlin/format requirement:** one formatter, explicit grouping decision, explicit signed
/`.clawback` style, integer minor units so display rounding is a pure presentation
concern, and one of `сомони`/`сом.` chosen (`ActiveDeliveryView` currently uses *both* for
`order.deliveryFee` on the same flow — `:145` full word, `:262` abbreviated).

---

## 7. Location streaming: cadence, gating, table, and what Kotlin needs instead

### Client side — verified in full

`Services/LocationService.swift` (76 lines, the entire location stack):

- `desiredAccuracy = kCLLocationAccuracyBest`, **`distanceFilter = 10`** (`:20-21`).
- `requestWhenInUseAuthorization()` only (`:25`). **No `AlwaysAndWhenInUse`.**
- `submit(...)` is called from **exactly one place**: the
  `didUpdateLocations` delegate (`:54-67`), gated by `guard isOnline else { return }`
  at **`:57`**.
- Fields forwarded: `accuracyMeters` (nil if `horizontalAccuracy < 0`), `heading` (nil if
  `course < 0`), `speed` (nil if `speed < 0`) — `:62-64`.
- `setOnline(false)` calls `CourierLocationStreamer.shared.reset()` (`:39`).

**LOUD CORRECTION #8 — the `isOnline` guard is in the app, not in core.** The report says
"`CourierLocationStreamer.submit` early-returns on `guard isOnline`." It does **not**.
`Sources/RavonCore/Services/CourierLocationStreamer.swift` has no `isOnline` concept
anywhere (verified, all 127 lines). The guard is `LocationService.swift:57`, in the
courier app. The net effect the report describes is identical — `submit` is never reached —
but anyone fixing "core's guard" will find nothing there.

**There is no timer.** `submit` fires only on a CoreLocation callback, and callbacks only
arrive after ≥10 m of movement (`distanceFilter = 10`). **A stationary courier emits no
heartbeat at all.** The report is right, and this is the most consequential fact in this
section.

### Core side — `CourierLocationStreamer` (all verified)

The documented cadence table (`:11-17`) matches the code:

| `OrderStatus` | interval (`cadence(for:)` `:94-103`) | movement filter (`movementFilterMeters(for:)` `:106-113`) |
|---|---|---|
| `nil` (online, no order) | 30 s | skip < 50 m |
| `assigned` | 10 s | skip < 25 m |
| `courierArrivedRestaurant` | 30 s | none |
| `pickedUp`, `delivering` | 5 s | skip < 15 m |
| `courierArrivedCustomer` | 10 s | none |
| any other | 30 s | none |

These are **rate limits on incoming fixes**, not schedulers. Confirmed.

Order of checks in `submit` (`:55-81`) — subtle and worth porting deliberately:

1. `:59` — if `now - lastSentAt < interval`, return.
2. `:60-67` — if moved less than the filter (hand-rolled haversine, `:117-126`, R = 6,371,000 m),
   **set `lastSentAt = now`** and return. `lastSentLatitude/Longitude` are *not* updated,
   so drift accumulates against the last actually-sent point (correct).
3. `:68` — if `accuracyMeters > 200`, return ("server would reject").
4. `:71-77` — send; on success update all three `lastSent*`.

**Consequence of step 2 that the report does not state:** because the skip branch
refreshes `lastSentAt`, the cadence clock measures the last *attempt*, not the last *send*.
A courier moving slowly — walking a corridor, crawling in traffic — under 15 m per 5 s
refreshes the timestamp on every fix and **never transmits**. The 200 m accuracy gate at
step 3 is also *after* the movement filter, so a good fix can be dropped by movement
before accuracy is ever considered.

Accuracy gating exists in **two places** with the same threshold:
client `CourierLocationStreamer.swift:68` (`> 200` → silent drop) and server
`update_courier_heartbeat` (`mig13:101-104`, `> 200` → `RAISE … ACCURACY_TOO_LOW` with
`'accuracy'` in the payload). Client drops silently so the typed error never surfaces.

### Table and server-side semantics

Target table: **`courier_locations`**, one row per courier, written by
`update_courier_heartbeat` (`mig13:72-140`), `SECURITY DEFINER`,
`SET search_path = public, extensions`. Verified behaviour:

- Rejects when `auth.uid()` is null (`NOT_AUTHENTICATED`) or the profile is suspended
  (`COURIER_SUSPENDED` + `until`).
- **Soft rate limit:** `IF last_heartbeat_at > now() - interval '1 second' THEN RETURN` —
  silent skip, no error (`mig13:111`).
- Writes `latitude, longitude, heading, speed, accuracy_meters, last_updated,
  last_heartbeat_at`, and `last_moved_at = CASE WHEN ST_Distance(old.geog, new.geog) > 25
  THEN now() ELSE old.last_moved_at END` (`mig13:115-125`). **The 25 m movement threshold
  exists server-side too**, independent of the client's 15/25/50 m filters.
- **Sets `is_online = true` unconditionally**, on both the UPDATE and the INSERT branch
  (`mig13:125`, `:132`). There is no way to heartbeat while offline.
- Recomputes `orders.eta_minutes` and bumps `orders.updated_at` for the active order
  (`mig13:137-140`).

**Two dispatch-state consequences, neither in the report:**

1. **Online-ness is a side effect of sending a location.** The courier's dispatchable
   state (`is_online`) has no independent authority — it is set by `goOnline()`'s upsert
   (write #1, §0), cleared by `goOffline()`'s update (write #2), and **resurrected by any
   heartbeat**. A single in-flight fix arriving after `goOffline()` flips the courier back
   online server-side. This makes the report's "Пауза is a UI dimmer"
   (`HomeView.swift:249`, sets `dashState = .paused` and nothing else — verified) worse
   than described: there is no server representation of "available but paused" at all.
2. **A stationary courier freezes the consumer's ETA**, not just the map. No heartbeat →
   no `compute_eta_minutes` call → `orders.eta_minutes` stale for the whole stop.

### §2c — state restoration kills streaming. Verified, with exact lines

`Views/Home/HomeView.swift:375-410`, `restoreState()`. Three branches under
`if courierLocation.isOnline`:

| Branch | `requestPermission()` | `startUpdating()` | `setOnline(true)` |
|---|---|---|---|
| active order found (`:380-384`) | **no** | **no** | **no** |
| `currentOrderId != nil`, no active order (`:385-392`) | `:387` | `:388` | `:389` |
| neither (`:393-402`) | `:394` | `:395` | `:396` |

The report's "`:379-383`" is one line off; the branch is `:380-384`. The defect is exactly
as described: restore mid-delivery → `dashState = .activeDelivery`, full UI, working
buttons, but `LocationService.isOnline == false` and `startUpdating()` never called, so
the `:57` guard blocks every fix for the remainder of the delivery. Silent.

**It does not self-heal.** `handleForegroundReconnect()` (`:412-427`) calls
`startUpdating()` at `:422` but **not** `setOnline(true)`, and is anyway gated on
`dashState.isLookingForOrders` (`:92`), which an active delivery is not. Only
`handleDeliveryComplete()` (`:429-438`) restores both (`:433-434`) — i.e. after the
delivery is over.

### Everything else that stops the stream

- **No `UIBackgroundModes`.** `RavonCourier.xcodeproj/project.pbxproj` has exactly two
  *privacy/usage* keys: `INFOPLIST_KEY_NSCameraUsageDescription` (`:266`) and
  `INFOPLIST_KEY_NSLocationWhenInUseUsageDescription` (`:267`). (Minor imprecision in the
  report: there are 12 `INFOPLIST_KEY_*` entries total — scene manifest, orientations,
  status bar — but only those two are privacy strings, and there is no `UIBackgroundModes`,
  no `NSLocationAlwaysAndWhenInUseUsageDescription`, no `remote-notification`, no
  entitlements file.)
- **No push at all.** Zero hits for `UNUserNotification`, `registerForRemoteNotifications`,
  `APNs`, `UIApplicationDelegate`. Verified.
- So streaming stops the moment the app backgrounds — including when the courier follows
  the app's own instruction and taps navigate, which calls
  `LocationService.openInMaps` → `mapItem.openInMaps(directionsMode: driving)`
  (`LocationService.swift:43-50`). **The app stops tracking during the drive it exists to
  track.** Report is correct.
- `IPHONEOS_DEPLOYMENT_TARGET = 26.2` (`pbxproj:278`), vs RavonCore's `.iOS(.v17)`.

### What a Kotlin dispatch service needs instead

1. **Time-driven ingestion, not movement-driven.** Cadence must be a timer the client
   cannot skip, with an explicit "stationary" heartbeat so `last_heartbeat_at` stays fresh
   at a standstill. Everything the migration-20 plan wants to gate on
   (`last_heartbeat_at > now() - 60s` in `claim_order`, `ST_DWithin` on
   `courier_deliver_order`) is unshippable until this changes — and the report's framing is
   right: such a gate would reject legitimate deliveries from couriers standing at the door,
   because standing at the door is precisely when the button gets pressed.
2. **`is_online` as first-class state, not a heartbeat side effect.** Explicit
   go-online / go-offline / pause commands, server-owned, with a heartbeat-expiry sweeper.
   That also removes writes #1 and #2 from §0.
3. **Position as an append-only track**, not a single mutable row. `courier_locations` has
   one row per courier; there is no history, so no way to audit a disputed delivery, no
   speed/route reconstruction, and no training data for ETA. Same shape problem as
   `courier_earnings` (§5.2).
4. **One movement threshold.** Currently three: client 15/25/50 m by status, client
   `distanceFilter = 10` m, server `last_moved_at` 25 m.
5. **One accuracy policy.** Currently duplicated at 200 m (client silent drop / server
   typed raise). Pick where it lives; if the server, surface the typed error.
6. **A wake channel that survives the lock screen.** Until push exists, "offers arrive
   automatically" (promised on onboarding screen 2) and the 30 s accept window (screen 3)
   are both false with the screen off. Dispatch cannot assume a reachable courier.

---

## 8. Testability (report §3) — what it says is testable vs not

I did not re-run the simulator; I verified every *code-level* premise the section rests on.

**Report says testable (and it is right):**

- **GPS spoofing is free** — `xcrun simctl location <udid> set 38.5598,68.7870`, Xcode
  Debug → Simulate Location, `.gpx` route replay, device simulation over USB. No
  `DEV_BYPASS_PROXIMITY` flag needed. Not a code claim; nothing to verify, and it is
  plainly correct.
- **A proximity gate would change nothing today** — verified twice over: the app never
  calls the coordinate-taking RPC (§1), and the arrival RPCs take no coordinates
  (`courier_arrived_restaurant(p_order_id)` `mig13:226`,
  `courier_arrived_at_customer(p_order_id)` `mig13:340`). A gate would have to read
  `courier_locations.geog`, which §7 shows is untrustworthy.
- **Strict `delivery_proof_url` storage validation costs nothing — promote it out of the
  deferred list.** Verified: there is no fake path. `OrderService.deliverOrderLeaveAtDoor`
  (`:140-147`) *always* calls `uploadDeliveryProof` then passes the returned path to
  `courier_deliver_order`. Every leave-at-door test already does a real upload. And it is
  simulator-testable: `DeliveryCompletion.swift:68` —
  `p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary`.
  **One correction that is load-bearing for whoever writes the check:** the path is
  `"<orderId>/<uid>-<timestamp>.jpg"` (`SupabaseService.swift:621-622`) inside bucket
  `delivery-proofs`. The report writes it as `delivery-proofs/<order_id>/`. A validator
  must test `bucket_id = 'delivery-proofs' AND name LIKE p_order_id || '/%'`, not a
  `delivery-proofs/`-prefixed name.
- **The 3-in-24h cancel cooldown is already shipped both ends — delete the deferred row.**
  Verified: server counts `courier_cancellation_log` over `now() - interval '24 hours'`
  and raises `courier_cancel_cooldown`; client consumes it via
  `OrderService.refreshCancellationCooldown()` (`:196-205`) →
  `isCancelOnCooldown` (`:207-209`, `recentCancels >= 3 && cooldownUntil > now`) →
  disabled button + "Восстановится в HH:mm" at `ActiveDeliveryView.swift:681`.
- **Heartbeat-freshness gate in `claim_order` becomes trivially testable once the
  heartbeat is timer-driven** (`simctl location` accepts a moving `--speed` track), but
  must not ship before that — it would fail for real parked couriers, not just test
  accounts. Mechanism verified in §7.

**Report says NOT testable, ranked (verified where verifiable):**

1. **Anything at all, until the Supabase host resolves.** Dominates everything. Already
   established by the orchestrator: no Ravon project exists.
2. **Two couriers racing `claim_order`** — needs a second account and a second device.
   Cheap, never done. Note §2's Correction #6: the race-loss *message* is dead code, which
   is exactly the bug this untested path hides.
3. **The full 6-step happy path** — needs a merchant moving an order
   `accepted`→`ready` in lockstep. Verified: no seed script and no synthetic-order RPC
   exists anywhere in migrations 01–19. The report's proposed
   `dev_seed_order(p_restaurant_id, p_status)` is called "the single highest-value piece
   of dev infrastructure missing from the fleet" and I agree — with the §0 caveat that
   adding another `SECURITY DEFINER` function to a schema with **zero `REVOKE` statements**
   means writing the `REVOKE ALL … FROM PUBLIC` in the same migration.
4. **Realtime under a dropping network** — verified: `RealtimeService.swift` contains
   **zero** occurrences of `retry`, `backoff`, `reconnect`, or `Task.sleep`. There is no
   reconnect logic to test. Resubscription happens only on `scenePhase == .active`
   (`HomeView.swift:90-96`), i.e. poll-on-reopen.
5. **Background location and push** — untestable because unimplemented (§7).
6. **Real-camera proof and a genuine two-geofence drive** — the only items that actually
   require being in Dushanbe. EXIF-GPS validation genuinely does break on the simulator
   (library photos have no GPS or wrong GPS); keep deferred.

**Observability, which is a testability constraint in disguise.** Verified: **zero**
`os.Logger`, `import OSLog`, or `Sentry` in the courier app. And the swallow sites the
report names are all real: `EarningsService.fetchEarnings` `catch {}` with a comment
(`:23-25`), `ProfileService.fetchProfile` `try?` (`:17`), `OrderService.fetchActiveOrder`
(`:34-36`), `refreshActiveOrder` (`:51-53`), `refreshCancellationCooldown` (`:201-204`),
`HomeView.restoreState` (`:404-406` "No courier status row — stay offline"). A dead
backend and an empty day render identically. For extraction: **there is currently no
telemetry that could tell you whether a cutover worked.** A Kotlin service needs to ship
with structured client logging on day one, or the first migration will be debugged the
same way this audit was — by `nslookup`.

---

## 9. Residual UNKNOWNs (need live introspection; blocked — no project exists)

- RLS policies on `orders` and `courier_locations` (none in files).
- Whether `PUBLIC EXECUTE` is in force on the ungranted `SECURITY DEFINER` functions,
  notably `insert_courier_earning_for_cancel`.
- PostgREST `max-rows` (bounds the `.all` earnings query).
- Baseline schema: `courier_locations` and `courier_earnings` are `ALTER`ed by migrations
  08/11/12 but never `CREATE`d in 01–19, so their full column lists, constraints, and the
  `courier_earnings` unique key on `order_id` (implied by `ON CONFLICT (order_id)`) are
  not in the repo.
- Whether realtime `postgres_changes` on the unfiltered `orders` channel enforces RLS per
  subscriber (determines whether the fanout in §1 also leaks rows).

---

## 10. Corrections to the STATE-REPORT, consolidated

| # | Report claim | Verified reality |
|---|---|---|
| 1 | §6 direct writes = 3, all `courier_locations` | **6** — plus `chat_messages` INSERT (`SupabaseService.swift:1060`) and UPDATE (`:1084`), and Storage PUT (`:623`) |
| 2 | `fetchAvailableOrders()` called in **6** places | **9** — `HomeView.swift:95,303,349,399,423,435`; `OrderOfferView.swift:173,183`; `OrderService.swift:63` |
| 3 | "The 50 km `ST_DWithin` default" | 50 km is the SQL default (`mig13:718`); the Swift wrapper overrides to **10 km** (`SupabaseService.swift:787`) |
| 4 | Moving to the RPC "closes the every-customer-address SELECT" | It narrows to a radius. `RETURNS SETOF orders` still returns `delivery_address_snapshot`, `verification_code` **and** `delivery_verification_code` for unclaimed orders |
| 5 | "24-case `ServiceError`" | **33** cases (`SupabaseService.swift:5-38`); `from()` maps **18** of **29** server reason codes; 11 unmapped, incl. courier-reachable `INVALID_EXTRA_MINUTES` |
| 6 | (not stated) | `.orderAlreadyClaimed` is unreachable from `from()`; the race-loss branches at `OrderOfferView.swift:147,157` are dead even after the `callRPC` fix |
| 7 | 14 currency sites (9 `сом.`) | **15** (10 `сом.`) — misses `OrderRowView.swift:114` |
| 8 | "`CourierLocationStreamer.submit` early-returns on `guard isOnline`" | No `isOnline` anywhere in `CourierLocationStreamer.swift`. The guard is `LocationService.swift:57`, in the app |
| 9 | `restoreState()` active branch at `:379-383` | `:380-384`. Defect itself confirmed |
| 10 | `delivery-proofs/<order_id>/` path prefix | Path is `<orderId>/<uid>-<ts>.jpg`; `delivery-proofs` is the bucket, not a path segment (`SupabaseService.swift:621-624`) |
| 11 | "exactly two Info.plist keys" | Two **privacy** keys; 12 `INFOPLIST_KEY_*` total. Conclusion (no background modes, no push) unchanged |

Everything else in the STATE-REPORT that I checked held up, including the entire §2a
decline analysis, §2c restoration defect, §2d pickup-code defect, §5(a) rolling-offset
insight, §3's four deferral-list corrections, and the `itemsRu` deletion trap
(`OrderRowView.swift:5` defines `Int.itemsRu`, used by live `ActiveDeliveryView.swift:258`
— deleting the otherwise-dead file breaks the build; verified, only two references exist).
