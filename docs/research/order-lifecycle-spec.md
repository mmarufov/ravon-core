# Order Lifecycle — Portable Specification

Extracted from:
- `/Users/mmarufov/conductor/workspaces/ravon-core/bucharest/Sources/RavonCore/Models/OrderLifecycle.swift` (429 lines)
- `/Users/mmarufov/conductor/workspaces/ravon-core/bucharest/Sources/RavonCore/Models/Order.swift` (`OrderStatus`, lines 3-117)
- `/Users/mmarufov/conductor/workspaces/ravon-core/bucharest/Tests/RavonCoreTests/OrderLifecycleInvariantTests.swift` (340 lines)

Ground-truthed against the SQL in `/Users/mmarufov/conductor/workspaces/ravon-core/bucharest/.context/migrations/` (migrations 01-19) and against the Swift service layer in `Sources/RavonCore/Services/SupabaseService.swift`.

Every number below was produced by compiling and executing the real source, not by reading. Method: `sed`-extracted `OrderStatus` (Order.swift:1-117) concatenated verbatim with the whole of `OrderLifecycle.swift`, compiled with `swiftc -O`, and a probe printed every derived set. The 17-test suite was run with `swift test --filter OrderLifecycleInvariantTests` → **17 executed, 0 failures, 0.024s**.

---

## 0. Corrections to the brief — READ FIRST

| Brief claim | Reality | Evidence |
|---|---|---|
| 17 states | **CORRECT — 17** | `OrderStatus.allCases.count == 17`, Order.swift:4-19 |
| 4 actors | **CORRECT — 4** | `OrderActor.allCases.count == 4`, OrderLifecycle.swift:17-20 |
| **38 edges** | **WRONG — there are 36** | `OrderLifecycle.transitions.count == 36`. Per-actor: consumer 7, merchant 8, courier 13, system 8 = 36. Table spans OrderLifecycle.swift:110-183 |
| **"Two entries are marked `missingServerSide`"** | **WRONG twice over.** (a) There is no `missingServerSide` symbol anywhere in the repo — the string appears only in that one doc comment. (b) The real gap is **5 RPCs across 8 edges**, not two. | `grep -rn missingServerSide Sources Tests scripts` → single hit at OrderLifecycle.swift:103. `unimplementedRPCs` evaluates to 5 names; 8 edges carry them |
| 17 property invariants | **CORRECT — 17** | `grep -c 'func test_'` → 17; suite runs 17 |

Three further corrections found while verifying, all material to the port:

1. **The file's own header comment is half wrong.** OrderLifecycle.swift:11-13 says "Visibility and obligations are *derived* from it rather than restated." Visibility **is** derived. **Obligations are not** — they are a hand-written 11-arm `switch` at OrderLifecycle.swift:243-269 that never consults `transitions`. See §5.
2. **`OrderTransition.rpc`'s doc comment is false against the shipped client.** OrderLifecycle.swift:78-80 asserts "There is no other legal way to move an order: `orders` carries no client UPDATE policy." But `SupabaseService` moves orders by **direct table UPDATE** in five places — `acceptOrder` (:393), `startPreparing` (:408), `rejectOrder` (:418), `markOrderReady` (:437), `assignCourier` (:641). Each uses a compare-and-swap `.eq("status", …)` / `.in("status", …)` filter as its guard. `assignCourier` additionally duplicates `claim_order`'s three edges with `.is("courier_id", nil)`.
3. **`OrderLifecycle` has zero production callers.** `grep -rn OrderLifecycle Sources | grep -v Models/OrderLifecycle.swift` → empty. `grep -rln OrderLifecycle` across all three app repos → empty. It is a **specification-only artifact exercised solely by its test suite**. Nothing in the fleet currently obeys it. That is good news for the port (no behaviour to preserve) and bad news for the claim that the merchant hand-off bug is fixed (it is fixed *in the model*, not in any shipping screen).

And the largest finding, which has its own section: **the declared table disagrees with the actual SQL on 8 system/courier edges.** See §9. The Kotlin service must implement the reconciled graph, not the Swift table verbatim.

---

## 1. States — 17 total, 7 terminal, 10 non-terminal

`OrderStatus` is a `String`-backed enum, `Codable, CaseIterable, Sendable`, at Order.swift:3-117. Declaration order is significant: `allCases` order is used by `visibleStatuses` iteration, and `stepIndex` is a separate hand-assigned ordering used by the liveness test.

| # | Swift case | wire value (`rawValue`) | terminal? | `stepIndex` | `displayName` (ru) |
|---|---|---|---|---|---|
| 1 | `scheduled` | `scheduled` | no | **-2** | Запланирован |
| 2 | `created` | `created` | no | 0 | Создан |
| 3 | `accepted` | `accepted` | no | 1 | Принят |
| 4 | `preparing` | `preparing` | no | 2 | Готовится |
| 5 | `ready` | `ready` | no | 3 | Готов |
| 6 | `assigned` | `assigned` | no | 4 | Назначен курьер |
| 7 | `courierArrivedRestaurant` | `courier_arrived_restaurant` | no | 5 | Курьер у ресторана |
| 8 | `pickedUp` | `picked_up` | no | 6 | Забран курьером |
| 9 | `delivering` | `delivering` | no | 7 | В пути |
| 10 | `courierArrivedCustomer` | `courier_arrived_customer` | no | 8 | Курьер у клиента |
| 11 | `delivered` | `delivered` | **YES** | 9 | Доставлен |
| 12 | `cancelled` | `cancelled` | **YES** | -1 | Отменён |
| 13 | `rejected` | `rejected` | **YES** | -1 | Отклонён |
| 14 | `cancelledByCustomer` | `cancelled_by_customer` | **YES** | -1 | Отменён клиентом |
| 15 | `cancelledByRestaurant` | `cancelled_by_restaurant` | **YES** | -1 | Отменён рестораном |
| 16 | `cancelledBySystem` | `cancelled_by_system` | **YES** | -1 | Отменён системой |
| 17 | `cancelledByCourier` | `cancelled_by_courier` | **YES** | -1 | Отменён курьером |

Note the wire-value irregularity a Kotlin port must reproduce exactly: only cases 7, 8, 10, 14, 15, 16, 17 carry an explicit snake_case `rawValue`; the other ten use the Swift case name verbatim. `scheduled` and `delivering` are single words and therefore identical either way, but `courierArrivedRestaurant` → `courier_arrived_restaurant` is an explicit override. Do **not** auto-derive; transcribe the column.

### Entry points

`create_order` (migration 04, line 204) sets
`status_value := CASE WHEN p_scheduled_for IS NOT NULL THEN 'scheduled' ELSE 'created' END`.
So exactly two entry statuses: `scheduled` and `created`. This is what `test_everyStatusIsReachableFromAnEntryPoint` quantifies over.

### Derived predicates on `OrderStatus` (Order.swift:43-116)

All are hand-written switches, and two of them are cross-checked against the transition table by tests 9 and 10.

| Predicate | True for | Source |
|---|---|---|
| `isTerminal` | delivered, cancelled, rejected, cancelledByCustomer, cancelledByRestaurant, cancelledBySystem, cancelledByCourier (7) | Order.swift:45-54 |
| `isActive` | `!isTerminal` — the 10 non-terminal states | Order.swift:43 |
| `isCancelled` | cancelled, cancelledByCustomer, cancelledByRestaurant, cancelledBySystem, cancelledByCourier (5 — **excludes `rejected` and `delivered`**) | Order.swift:56-63 |
| `isChatActive` | assigned, courierArrivedRestaurant, pickedUp, delivering, courierArrivedCustomer (5) | Order.swift:68-76 |
| `consumerCanCancel` | scheduled, created, accepted, preparing, ready, assigned, courierArrivedRestaurant (7) | Order.swift:79-86 |
| `courierCanCancel` | assigned, courierArrivedRestaurant (2) | Order.swift:89-91 |
| `isScheduled` | scheduled | Order.swift:93 |

`stepIndex` is a **partial** order only: every terminal-cancel state and `rejected` collapse to `-1`, and `scheduled` is `-2`. It exists for exactly one purpose — the "goes backwards" test in invariant 15. Comparing `stepIndex` between two cancel states is meaningless.

---

## 2. Actors — 4 total

`OrderActor`, `String`-backed, `Codable, Sendable, CaseIterable`, OrderLifecycle.swift:16-30.

| Swift case | wire value | `displayName` (ru) | meaning |
|---|---|---|---|
| `consumer` | `consumer` | Клиент | the ordering customer |
| `merchant` | `merchant` | Ресторан | the restaurant |
| `courier` | `courier` | Курьер | the delivery courier |
| `system` | `system` | Система | "covers pg_cron jobs and triggers" (OrderLifecycle.swift:15) |

`allCases` order is `consumer, merchant, courier, system`. Tests 6 and 7 iterate it, so a Kotlin `enum class` must enumerate in the same order for failure messages to line up (not semantically required).

Note `OrderActor` is a distinct type from `UserRole` (`Sources/RavonCore/Models/UserRole.swift`). They share three names but `system` has no `UserRole` counterpart. Do not conflate them in the port.

---

## 3. Complete transition table — all 36 rows

`OrderTransition` is a `Sendable, Hashable` struct (OrderLifecycle.swift:74-96) with fields `from: OrderStatus`, `to: OrderStatus`, `actor: OrderActor`, `rpc: String`, `guards: Set<TransitionGuard>` (defaulting to `[]`).

Rows are in **declaration order**, which matters: `transitions(from:)` preserves it, and invariant 5's random walk picks uniformly from the filtered list, so reordering changes which walks are generated (not whether they terminate).

`⚠` in the last column flags a row that disagrees with the SQL — detailed in §9.

| # | from | to | actor | rpc | guards | src | |
|---|---|---|---|---|---|---|---|
| 1 | `scheduled` | `created` | system | `activate_scheduled_orders` | — | :110 | |
| 2 | `created` | `accepted` | merchant | `merchant_accept_order` | — | :113 | ⚠ no such RPC |
| 3 | `created` | `rejected` | merchant | `merchant_reject_order` | — | :114 | ⚠ no such RPC |
| 4 | `accepted` | `preparing` | merchant | `merchant_start_preparing` | — | :115 | ⚠ no such RPC |
| 5 | `accepted` | `ready` | merchant | `merchant_mark_order_ready` | — | :116 | ⚠ no such RPC |
| 6 | `preparing` | `ready` | merchant | `merchant_mark_order_ready` | — | :117 | ⚠ no such RPC |
| 7 | `accepted` | `assigned` | courier | `claim_order` | `courierOnline`, `courierNotBusy`, `courierNotSuspended` | :122 | ⚠ missing 2 guards |
| 8 | `preparing` | `assigned` | courier | `claim_order` | same three | :124 | ⚠ missing 2 guards |
| 9 | `ready` | `assigned` | courier | `claim_order` | same three | :126 | ⚠ missing 2 guards |
| 10 | `assigned` | `courier_arrived_restaurant` | courier | `courier_arrived_restaurant` | — | :130 | |
| 11 | `courier_arrived_restaurant` | `picked_up` | courier | `courier_pickup_order` | `pickupCode` | :132 | |
| 12 | `picked_up` | `delivering` | courier | `courier_start_delivering` | — | :134 | |
| 13 | `delivering` | `courier_arrived_customer` | courier | `courier_arrived_at_customer` | — | :136 | |
| 14 | `courier_arrived_customer` | `delivered` | courier | `courier_deliver_order` | `deliveryCode` | :139 | |
| 15 | `courier_arrived_customer` | `delivered` | courier | `courier_deliver_order` | `proofImage` | :141 | |
| 16 | `assigned` | `ready` | courier | `cancel_order_by_courier` | `notOnCancelCooldown`, `reassignableReason` | :151 | |
| 17 | `courier_arrived_restaurant` | `ready` | courier | `cancel_order_by_courier` | `notOnCancelCooldown`, `reassignableReason` | :153 | |
| 18 | `assigned` | `cancelled_by_courier` | courier | `cancel_order_by_courier` | `notOnCancelCooldown`, `nonReassignableReason` | :155 | |
| 19 | `courier_arrived_restaurant` | `cancelled_by_courier` | courier | `cancel_order_by_courier` | `notOnCancelCooldown`, `nonReassignableReason` | :157 | |
| 20 | `scheduled` | `cancelled_by_customer` | consumer | `cancel_order_by_consumer` | — | :162 | |
| 21 | `created` | `cancelled_by_customer` | consumer | `cancel_order_by_consumer` | — | :163 | |
| 22 | `accepted` | `cancelled_by_customer` | consumer | `cancel_order_by_consumer` | — | :164 | |
| 23 | `preparing` | `cancelled_by_customer` | consumer | `cancel_order_by_consumer` | — | :165 | |
| 24 | `ready` | `cancelled_by_customer` | consumer | `cancel_order_by_consumer` | — | :166 | |
| 25 | `assigned` | `cancelled_by_customer` | consumer | `cancel_order_by_consumer` | — | :167 | |
| 26 | `courier_arrived_restaurant` | `cancelled_by_customer` | consumer | `cancel_order_by_consumer` | — | :168 | |
| 27 | `accepted` | `cancelled_by_restaurant` | merchant | `merchant_cancel_order` | — | :172 | ⚠ no such RPC |
| 28 | `preparing` | `cancelled_by_restaurant` | merchant | `merchant_cancel_order` | — | :173 | ⚠ no such RPC |
| 29 | `ready` | `cancelled_by_restaurant` | merchant | `merchant_cancel_order` | — | :174 | ⚠ no such RPC |
| 30 | `created` | `cancelled_by_system` | system | `run_courier_escalation_ladder` | — | :177 | ⚠ **phantom** |
| 31 | `accepted` | `cancelled_by_system` | system | `run_courier_escalation_ladder` | — | :178 | ⚠ **phantom** |
| 32 | `preparing` | `cancelled_by_system` | system | `run_courier_escalation_ladder` | — | :179 | ⚠ **phantom** |
| 33 | `ready` | `cancelled_by_system` | system | `run_courier_escalation_ladder` | — | :180 | ⚠ **phantom** |
| 34 | `assigned` | `cancelled_by_system` | system | `run_courier_escalation_ladder` | — | :181 | |
| 35 | `courier_arrived_restaurant` | `cancelled_by_system` | system | `run_courier_escalation_ladder` | — | :182 | |
| 36 | `courier_arrived_customer` | `cancelled_by_system` | system | `mark_no_show_deliveries` | — | :183 | ⚠ **wrong target** |

**Rows 14 and 15 are the only pair sharing `(from, to, actor, rpc)`.** They differ only in `guards`, which is why `Set(transitions)` has 36 members but the distinct `(from, to, actor)` triple count is **35**. Consequence for the port: `canTransition(from:to:by:)` (OrderLifecycle.swift:227-229) ignores `rpc` and `guards` entirely, so it cannot distinguish them, and any Kotlin `Map<Triple<From,To,Actor>, Transition>` keying **will silently drop one row**. Key on the whole row, or better, collapse 14/15 into one edge with a mode-dependent guard (see §4 note).

### Per-RPC edge fan-out

| RPC | edges | actor |
|---|---|---|
| `cancel_order_by_consumer` | 7 | consumer |
| `run_courier_escalation_ladder` | 6 | system |
| `cancel_order_by_courier` | 4 | courier |
| `claim_order` | 3 | courier |
| `merchant_cancel_order` | 3 | merchant |
| `courier_deliver_order` | 2 | courier |
| `merchant_mark_order_ready` | 2 | merchant |
| `activate_scheduled_orders`, `courier_arrived_restaurant`, `courier_pickup_order`, `courier_start_delivering`, `courier_arrived_at_customer`, `mark_no_show_deliveries`, `merchant_accept_order`, `merchant_reject_order`, `merchant_start_preparing` | 1 each | — |

16 distinct RPC names, 36 edges.

### Derived query API (must be reproduced)

| Swift | OrderLifecycle.swift | semantics |
|---|---|---|
| `transitions(from:)` | :219-221 | filter on `from`, declaration order preserved |
| `transitions(from:by:)` | :223-225 | filter on `from` **and** `actor` |
| `canTransition(from:to:by:)` | :227-229 | existence of any row matching the triple; **ignores rpc and guards** |
| `actionableStatuses(for:)` | :232-234 | `Set` of `from` over the actor's rows |
| `obligations(for:at:)` | :243-269 | see §5 |
| `visibleStatuses(for:)` | :274-280 | see §6 |
| `isVisible(_:to:)` | :282-284 | membership in the above |
| `reachableStatuses(from:)` | :289-299 | DFS (LIFO `popLast`), start included in the result |
| `stronglyConnectedComponents()` | :323-390 | iterative Tarjan, see §8 invariant 14 |
| `cyclicTransitions()` | :394-399 | rows with **both** endpoints in one SCC |
| `minimumSteps(from:to:)` | :410-428 | BFS, returns `0` if `start == goal`, `nil` if unreachable |

`reachableStatuses(from:)` includes `start` itself even with no self-loop — so `reachableStatuses(from: .delivered) == {delivered}`. `minimumSteps` by contrast returns `0` for the identity case but otherwise requires a real path, so `minimumSteps(from: .delivered, to: .delivered) == 0` while `minimumSteps(from: .ready, to: .ready) == nil`… actually no: `ready → assigned → ready` exists, so it returns 2. The asymmetry only bites for terminal states.

### Constants

`implementedRPCs` (OrderLifecycle.swift:197-209) — 11 names, verified below to exist in migrations 01-19:
`activate_scheduled_orders`, `claim_order`, `courier_arrived_restaurant`, `courier_pickup_order`, `courier_start_delivering`, `courier_arrived_at_customer`, `courier_deliver_order`, `cancel_order_by_courier`, `cancel_order_by_consumer`, `run_courier_escalation_ladder`, `mark_no_show_deliveries`.

`unimplementedRPCs` (OrderLifecycle.swift:213-215) is **computed**, not declared: `Set(transitions.map(\.rpc)).subtracting(implementedRPCs)`.

`orphanedLegacyStatuses` (OrderLifecycle.swift:194) = `[.cancelled]`.

`boundingGuards` (OrderLifecycle.swift:403) = `[.notOnCancelCooldown]`.

---

## 4. `TransitionGuard` — all 9 cases

`String`-backed, `Codable, Sendable, Hashable, CaseIterable`, OrderLifecycle.swift:35-53. Declared intent (OrderLifecycle.swift:32-34): these "mirror the `RAISE EXCEPTION` guards in the SECURITY DEFINER RPCs — declaring them here lets the client predict a refusal instead of discovering it as an opaque error."

| Case | wire value | Meaning (from doc comment) | Server realisation | Verified |
|---|---|---|---|---|
| `pickupCode` | `pickupCode` | "Courier must present the restaurant's 4-digit handoff code." | `courier_pickup_order`: `IF v_code IS DISTINCT FROM p_verification_code THEN RAISE 'invalid_verification_code'`, compared against `orders.verification_code` | mig 13:284-286 |
| `deliveryCode` | `deliveryCode` | "Courier must present the consumer's delivery code." | `courier_deliver_order`, **only when `orders.delivery_mode = 'hand_to_me'`**: compares `p_delivery_code` to `orders.delivery_verification_code`, else `RAISE 'wrong_delivery_code'` | mig 13:406-410 |
| `proofImage` | `proofImage` | "Leave-at-door requires an uploaded proof photo instead of a code." | `courier_deliver_order`, **only when `delivery_mode <> 'hand_to_me'`**: `IF p_delivery_proof_url IS NULL OR length(p_delivery_proof_url) < 4 THEN RAISE 'missing_proof_image'` | mig 13:411-415 |
| `courierOnline` | `courierOnline` | (no doc comment) | `claim_order`: `SELECT is_online FROM courier_locations…; IF v_is_online IS DISTINCT FROM true THEN RAISE 'courier_must_be_online'` | mig 13:174-178 |
| `courierNotBusy` | `courierNotBusy` | (no doc comment) | `claim_order`: courier must have no other order in a non-terminal status, else `RAISE 'courier_busy'` | mig 13:180-188 |
| `courierNotSuspended` | `courierNotSuspended` | (no doc comment) | `claim_order`: `SELECT is_suspended_until FROM profiles…; RAISE 'courier_suspended'`. Same check also fronts `update_courier_heartbeat` | mig 13:168-172, :95-100 |
| `notOnCancelCooldown` | `notOnCancelCooldown` | (no doc comment) | `cancel_order_by_courier`: `SELECT count(*) FROM courier_cancellation_log WHERE courier_id = v_uid AND created_at > now() - interval '24 hours'; IF v_recent >= 3 THEN RAISE 'courier_cancel_cooldown'` | mig 13:502-509 |
| `reassignableReason` | `reassignableReason` | "Courier cancel reason is one of the reassignable set — the restaurant is at fault (`COURIER_RESTAURANT_CLOSED`, `COURIER_ITEMS_UNAVAILABLE`, `RESTAURANT_TOO_LONG_WAIT`), so the order returns to the pool." | `cancel_order_by_courier`: `IF p_reason_code IN ('COURIER_RESTAURANT_CLOSED','COURIER_ITEMS_UNAVAILABLE','RESTAURANT_TOO_LONG_WAIT') THEN … status='ready'` | mig 13:536-546 — **exact match, all three codes** |
| `nonReassignableReason` | `nonReassignableReason` | "Courier cancel reason is not reassignable — the courier is at fault, so the order terminates rather than being re-offered." | the `ELSE` branch → `status='cancelled_by_courier'`. Complement within the whitelist = `COURIER_VEHICLE_ISSUE`, `COURIER_SAFETY_ISSUE` | mig 13:550-555 |

### Reason-code whitelist (needed to evaluate the last two guards)

`cancel_order_by_courier` rejects anything outside this set up front (mig 13:494-500), and `CancellationReason.courierAllowed` (`Sources/RavonCore/Models/CancellationReason.swift:46-53`) is an **exact match** — 5 codes:

| code | branch |
|---|---|
| `COURIER_RESTAURANT_CLOSED` | reassignable → `ready` |
| `COURIER_ITEMS_UNAVAILABLE` | reassignable → `ready` |
| `RESTAURANT_TOO_LONG_WAIT` | reassignable → `ready` |
| `COURIER_VEHICLE_ISSUE` | non-reassignable → `cancelled_by_courier` |
| `COURIER_SAFETY_ISSUE` | non-reassignable → `cancelled_by_courier` |

`reassignableReason` and `nonReassignableReason` therefore **partition** the whitelist and are mutually exclusive. No edge carries both. A Kotlin port should express this as a sealed discriminator on the reason code rather than two independent boolean guards, so the exclusivity is a type property.

### Guards the server enforces but the model omits

| Server check | RPC | Source | Model coverage |
|---|---|---|---|
| `courier_id IS NULL` — order not already claimed | `claim_order` | mig 13:197 | **none** |
| `v_uid = ANY(excluded_courier_ids)` → `RAISE 'courier_excluded'` (set by `reassign_ghosted_order` on requeue) | `claim_order` | mig 13:201-204 | **none** |
| `v_courier IS DISTINCT FROM v_uid` → `RAISE 'unauthorized'` — caller owns the order | all six courier run RPCs | mig 13:276-278, :397-399, :517-519, … | **none** (implicit in `actor`, but not expressible) |
| `accuracy_meters` floor → `RAISE 'accuracy_too_low'` | `update_courier_heartbeat` | mig 13:102-105 | n/a (not a status transition) |

The `excluded_courier_ids` gap is the important one: without it, a ghosted courier can be modelled as re-claiming the very order they were just excluded from. A Kotlin port needs a 10th guard, `courierNotExcluded`, and an 11th, `orderUnclaimed`.

### The `deliveryCode` / `proofImage` encoding is lossy

The Swift table represents these as **two alternative edges** (rows 14, 15), implying the courier chooses. The SQL chooses for them: the branch is on `orders.delivery_mode`, a column set at order creation and synced from the address (`sync_order_delivery_mode_from_address`, mig 10). `DeliveryMode` (`Sources/RavonCore/Models/DeliveryMode.swift`) already models this correctly with `requiresDeliveryCode` / `requiresProofImage`. Recommended Kotlin shape: **one** `courierArrivedCustomer → delivered` edge whose guard is `DeliveryProof(mode)`, resolving to code-or-photo. This also fixes the 36-vs-35 keying hazard in §3.

---

## 5. `OrderObligation` — all 5 cases, and the full matrix

`String`-backed, `Codable, Sendable, Hashable, CaseIterable`, OrderLifecycle.swift:60-71.

| Case | wire value | Meaning (doc comment) |
|---|---|---|
| `showPickupCode` | `showPickupCode` | "Merchant must display the pickup code so the courier can collect." |
| `showDeliveryCode` | `showDeliveryCode` | "Consumer must be able to read their delivery code to the courier." |
| `showNavigation` | `showNavigation` | "Courier must be shown where to go next." |
| `trackProgress` | `trackProgress` | "Party is waiting on someone else and must see live progress." |
| `startCooking` | `startCooking` | "Merchant must be told the kitchen has to start cooking." |

### DECLARED, NOT DERIVED — this is the single most important fact for the port

`obligations(for:at:)` (OrderLifecycle.swift:243-269) is a hand-written `switch` over `(actor, status)`. **It never reads `transitions`.** The file header's claim that obligations are "derived" (OrderLifecycle.swift:11-12) is false; only visibility is.

Two consequences:

1. **Port it as data, not as logic.** Transcribe the table below into a `Map<Pair<OrderActor, OrderStatus>, Set<OrderObligation>>` with a default of the empty set. There is no rule to re-derive it from, and attempting to invent one will produce a different matrix.
2. **Pattern-match order is load-bearing.** The arm `case (.consumer, _) where status.isActive` (OrderLifecycle.swift:263) is a catch-all that sits *after* `case (.consumer, .courierArrivedCustomer)` (:261). Swift takes the first match. A Kotlin `when` preserves this if written in the same order; a `Map` lookup must pre-expand the consumer wildcard into its 10 concrete rows (done for you below). Getting this backwards silently drops `showDeliveryCode` and is precisely the class of bug the file exists to prevent.

### Full `(actor, status) → obligations` matrix

Machine-generated from the compiled source. 20 non-empty cells out of 68 (4 actors × 17 statuses); all 48 others are `[]`.

| status | consumer | merchant | courier | system |
|---|---|---|---|---|
| `scheduled` | `trackProgress` | — | — | — |
| `created` | `trackProgress` | `startCooking` | — | — |
| `accepted` | `trackProgress` | `startCooking`, `trackProgress` | — | — |
| `preparing` | `trackProgress` | `startCooking`, `trackProgress` | — | — |
| `ready` | `trackProgress` | `trackProgress` | — | — |
| `assigned` | `trackProgress` | **`showPickupCode`**, `trackProgress` | `showNavigation` | — |
| `courier_arrived_restaurant` | `trackProgress` | **`showPickupCode`**, `trackProgress` | `showNavigation`, `trackProgress` | — |
| `picked_up` | `trackProgress` | — | `showNavigation` | — |
| `delivering` | `trackProgress` | — | `showNavigation` | — |
| `courier_arrived_customer` | **`showDeliveryCode`**, `trackProgress` | — | — | — |
| `delivered` | — | — | — | — |
| `cancelled` | — | — | — | — |
| `rejected` | — | — | — | — |
| `cancelled_by_customer` | — | — | — | — |
| `cancelled_by_restaurant` | — | — | — | — |
| `cancelled_by_system` | — | — | — | — |
| `cancelled_by_courier` | — | — | — | — |

Observations a porter should not "fix" without a decision:

- **`system` has zero obligations at every status.** The `default: return []` arm (OrderLifecycle.swift:266-267) catches it entirely. Intentional — a cron job has nothing to be shown.
- **`merchant` at `ready` loses `startCooking` but keeps `trackProgress`**; the merchant gets no obligation at all once the food is `picked_up`.
- **`courier` gets no obligation at `courier_arrived_customer`** — the one state where the courier is actively taking the delivery code. `showNavigation` stops at `delivering`. Arguably a gap (the courier still needs the proof-capture UI), but it is what the model says, and the state stays visible via `actionableStatuses`.
- **`courier` at `courier_arrived_restaurant` uniquely gets `trackProgress`** on top of `showNavigation` (:258-259) — the courier is waiting on the kitchen there.
- **No actor carries any obligation at any of the 7 terminal states.** This is what makes the visibility result in §6 surprising.
- `startCooking` at `.accepted` **and** `.preparing` (:247) is deliberate per the doc comment, even though the kitchen has already started by `.preparing`.

---

## 6. The visibility derivation rule

Two functions, OrderLifecycle.swift:274-284:

```
visibleStatuses(for actor) =
    actionableStatuses(for: actor)                         // any status the actor can move OUT of
  ∪ { s ∈ OrderStatus.allCases : obligations(actor, s) ≠ ∅ }  // any status the actor is shown something at

isVisible(status, to: actor) = status ∈ visibleStatuses(for: actor)
```

Stated in prose (OrderLifecycle.swift:272-273): "anything it can act on, plus anything it carries an obligation at. Apps should filter their lists with this rather than hand-rolling a status array per screen."

This is a genuine union of two *independently computed* sets — one from the edge table, one from the hand-written obligation switch. That is exactly why invariants 6 and 7 are non-trivial: they assert the union actually covers each input.

### Computed result for all four actors

| actor | actionable | has-obligation | **visible** | NOT visible |
|---|---|---|---|---|
| **consumer** | 7: `scheduled`, `created`, `accepted`, `preparing`, `ready`, `assigned`, `courier_arrived_restaurant` | 10: all non-terminal | **10** — all non-terminal states | **7** — all terminal states, **including `delivered`** |
| **merchant** | 4: `created`, `accepted`, `preparing`, `ready` | 6: + `assigned`, `courier_arrived_restaurant` | **6** | **11** — `scheduled`, `picked_up`, `delivering`, `courier_arrived_customer`, `delivered`, and all 6 cancel/reject states |
| **courier** | 8: `accepted`, `preparing`, `ready`, `assigned`, `courier_arrived_restaurant`, `picked_up`, `delivering`, `courier_arrived_customer` | 4: `assigned`, `courier_arrived_restaurant`, `picked_up`, `delivering` | **8** (obligation set is a strict subset of actionable) | **9** — `scheduled`, `created`, `delivered`, and all 6 cancel/reject states |
| **system** | 8: `scheduled`, `created`, `accepted`, `preparing`, `ready`, `assigned`, `courier_arrived_restaurant`, `courier_arrived_customer` | 0 | **8** (= actionable) | **9** |

### The derivation has a real hole: no actor can see any terminal state

Because obligations are empty at every terminal status and terminal statuses are absorbing (so they are never any row's `from`), **`visibleStatuses` is empty of terminal states for all four actors.** In particular **no actor can see `delivered`.**

Taken literally this means: no order history screen, no courier earnings list, no merchant completed-orders tab, no consumer receipt. That is not what any of the three apps do or should do.

This is not caught by any of the 17 invariants, because every one is phrased as an implication *into* visibility (`obligation ⇒ visible`, `actionable ⇒ visible`) and never the converse. Nothing asserts a lower bound on the visible set.

**Port decision required.** The clean fix is a third term:

```
visibleStatuses(actor) = actionable(actor) ∪ obligated(actor) ∪ historical(actor)
```

…where `historical` is a declared per-actor set of terminal statuses (consumer: all 7; merchant: `rejected`, `delivered`, `cancelled_by_*`; courier: `delivered`, `cancelled_by_courier`, `cancelled_by_system`). Add an invariant that every terminal state is visible to at least one actor. Do **not** just widen `obligations` to cover terminal states — that would make invariant 6 vacuous and would assert the UI must actively *show* something there.

---

## 7. Transitions with no server-side RPC

The brief says two. **It is 5 RPC names across 8 of the 36 edges.** Verified two ways.

### Verification 1 — the model's own computation

`unimplementedRPCs` = `Set(transitions.map(\.rpc)) - implementedRPCs`, evaluated by running the real code:

```
["merchant_accept_order", "merchant_cancel_order", "merchant_mark_order_ready",
 "merchant_reject_order", "merchant_start_preparing"]
```

The test suite hard-codes the same five as `knownMissing` (OrderLifecycleInvariantTests.swift:215-217) and asserts set equality (:229-232), so the gap is pinned.

### Verification 2 — against the actual SQL

Every `CREATE [OR REPLACE] FUNCTION` across `.context/migrations/*.sql` was enumerated (33 functions). Result:

| RPC | defining migration |
|---|---|
| `activate_scheduled_orders` | `06_scheduled_orders.sql` ✓ |
| `claim_order` | `13_courier_status_transition_rpcs_v2.sql` ✓ |
| `courier_arrived_restaurant` | `13_…` ✓ |
| `courier_pickup_order` | `13_…` ✓ |
| `courier_start_delivering` | `13_…` ✓ |
| `courier_arrived_at_customer` | `13_…` ✓ |
| `courier_deliver_order` | `13_…` ✓ |
| `cancel_order_by_courier` | `13_…` ✓ |
| `cancel_order_by_consumer` | `13_…` ✓ |
| `run_courier_escalation_ladder` | `14_…`, redefined in `17_…` ✓ |
| `mark_no_show_deliveries` | `16_no_show_and_restaurant_delay.sql` ✓ |
| `merchant_accept_order` | **NOT DEFINED IN ANY MIGRATION** |
| `merchant_reject_order` | **NOT DEFINED IN ANY MIGRATION** |
| `merchant_start_preparing` | **NOT DEFINED IN ANY MIGRATION** |
| `merchant_mark_order_ready` | **NOT DEFINED IN ANY MIGRATION** |
| `merchant_cancel_order` | **NOT DEFINED IN ANY MIGRATION** |

`implementedRPCs` is therefore **exactly right** — all 11 exist, none is a typo.

### The 8 affected edges

Rows 2, 3, 4, 5, 6 (the four merchant kitchen ops) and rows 27, 28, 29 (merchant cancel). Every merchant edge in the table — all 8 of them — names a non-existent function. The merchant is the **only** actor with zero working RPCs.

### What the merchant actually does today

Confirmed cross-check against migrations: **no migration ever writes `'accepted'`, `'preparing'`, or `'rejected'`.** Those three statuses have no server-side producer at all. The client writes them by direct table UPDATE:

| Model row | Real implementation | Guard actually used |
|---|---|---|
| 2: `created → accepted` | `SupabaseService.acceptOrder` (SupabaseService.swift:393-406) | `.eq("status", "created")` + `.select("id")`, empty result → `ServiceError.invalidStatusTransition` |
| 3: `created → rejected` | `SupabaseService.rejectOrder` (:418-435) | `.eq("status", "created")` |
| 4: `accepted → preparing` | `SupabaseService.startPreparing` (:408-416) | `.eq("status", "accepted")` |
| 5, 6: `accepted|preparing → ready` | `SupabaseService.markOrderReady` (:437-448) | `.in("status", ["accepted","preparing"])` |
| 27, 28, 29: `* → cancelled_by_restaurant` | **nothing.** No `cancelled_by_restaurant` writer exists in Swift or SQL | — |

This is a **legitimate compare-and-swap** pattern — the `.eq("status", …)` predicate plus checking the returned row count is a correct optimistic-concurrency guard, and the `from`/`to` pairs match the model exactly. But it depends on an UPDATE policy on `orders` existing, which the model explicitly claims does not (OrderLifecycle.swift:79-80). One of those two statements is wrong. Which one is **UNKNOWN — needs live introspection** (no Ravon Supabase project exists to query).

Also parallel to the model: `SupabaseService.assignCourier` (:641-657) performs `accepted|preparing|ready → assigned` by direct UPDATE with `.is("courier_id", nil)` — a hand-rolled duplicate of `claim_order`'s rows 7-9, bypassing all three courier guards. The model does not mention it.

`cancelled_by_restaurant` is reachable only via rows 27-29, all of which name a non-existent RPC and have no client fallback. In practice **the merchant cannot cancel an order at all** — the state is model-reachable but operationally dead. The header comment (OrderLifecycle.swift:106) says "merchant currently calls the *consumer's* cancel RPC"; I could not verify that from the merchant app source (the `ravon-merchant` checkout at `/Users/mmarufov/conductor/repos/ravon-merchant` contains only 2 Swift files and no cancel call site), and `SupabaseService.cancelOrder` (:632-637) is the only `cancel_order_by_consumer` call in RavonCore. **UNKNOWN — needs the full merchant app source.**

---

## 8. The 17 property invariants

All in `Tests/RavonCoreTests/OrderLifecycleInvariantTests.swift`, an `XCTestCase`. Suite runs **17 tests, 0 failures**. Stated purpose (:4-8): "These are not example tests — they quantify over *every* status, actor and randomized path. Each one corresponds to a class of bug found during the 2026-09-15 fleet audit."

Shared fixture: `SeededRNG` (:13-22), a **SplitMix64** generator — `state &+= 0x9E3779B97F4A7C15`, then xor-shift-multiply by `0xBF58476D1CE4E5B9` and `0x94D049BB133111EB`, final `z ^ (z >> 31)`. Used only by invariant 5, for reproducibility from a printed seed. Kotlin has no `RandomNumberGenerator` protocol; use `kotlin.random.Random(seed)` — the specific bit-mixer is not load-bearing, only determinism is.

---

**1. `test_everyNonTerminalStatusHasAnExit`** (:31-38)

*Property:* For every status `s` with `!s.isTerminal`, `transitions(from: s)` is non-empty.

*Algorithm:* none — universal quantification over 10 states.

*Why:* "If a future status is added with no outgoing edge, an order can strand in it forever and no screen will explain why."

*Kotlin:*
```kotlin
@Test fun everyNonTerminalStatusHasAnExit() {
  OrderStatus.entries.filterNot { it.isTerminal }.forEach { s ->
    assertTrue(OrderLifecycle.transitionsFrom(s).isNotEmpty(),
      "${s.wire} is non-terminal but has no outgoing transition")
  }
}
```

---

**2. `test_terminalStatusesAreAbsorbing`** (:41-48)

*Property:* For every status `s` with `s.isTerminal`, `transitions(from: s)` is **empty**.

*Algorithm:* none — the exact converse of invariant 1, over the other 7 states. Together, 1 and 2 make `isTerminal` ⟺ zero out-degree, so the hand-written `isTerminal` predicate and the edge table cannot drift.

*Kotlin:* mirror of 1 with `filter { it.isTerminal }` and `assertTrue(…isEmpty())`.

---

**3. `test_everyStatusIsReachableFromAnEntryPoint`** (:52-70)

*Property:* Let `R = reachableStatuses(.scheduled) ∪ reachableStatuses(.created)`. Then for every status `s`: if `s ∈ orphanedLegacyStatuses` then `s ∉ R`, **else** `s ∈ R`.

*Algorithm:* DFS (`reachableStatuses`, OrderLifecycle.swift:289-299).

*Verified result:* `|R| = 16` — all 17 statuses except `cancelled`. So both directions of the assertion are exercised: 16 positive, 1 negative.

*The negative case is the interesting half.* `orphanedLegacyStatuses = [.cancelled]` and the test asserts `cancelled` **stays** unreachable: "assert it stays dead rather than silently acquiring a producer." I confirmed this against SQL — an exhaustive grep for `status = '<literal>'` across all 19 migrations found 21 status writes and **not one writes `'cancelled'`.** The doc comment's claim (OrderLifecycle.swift:186-193) that `cancelled` "appears only inside `status NOT IN (...)` terminal lists" is correct.

*Kotlin:*
```kotlin
@Test fun everyStatusIsReachableFromAnEntryPoint() {
  val r = OrderLifecycle.reachableFrom(SCHEDULED) + OrderLifecycle.reachableFrom(CREATED)
  OrderStatus.entries.forEach { s ->
    if (s in OrderLifecycle.orphanedLegacyStatuses)
      assertFalse(s in r, "${s.wire} is documented orphaned but now has a producer")
    else
      assertTrue(s in r, "${s.wire} is unreachable from scheduled or created")
  }
}
```

---

**4. `test_courierCancelBranchesOnReasonCode`** (:75-93)

*Property:* For each `s ∈ {assigned, courierArrivedRestaurant}`, the rows in `transitions(from: s, by: .courier)` with `rpc == "cancel_order_by_courier"` number **exactly 2**, their `to` set is exactly `{ready, cancelledByCourier}`, and each carries at least one of `reassignableReason` / `nonReassignableReason`.

*Algorithm:* none — three assertions per state.

*Why:* the header note at OrderLifecycle.swift:147-150 records that the original model had this as one edge, "which left `.cancelledByCourier` unreachable" — invariant 3 caught it.

*Kotlin:*
```kotlin
@ParameterizedTest @EnumSource(names = ["ASSIGNED", "COURIER_ARRIVED_RESTAURANT"])
fun courierCancelBranchesOnReasonCode(s: OrderStatus) {
  val edges = OrderLifecycle.transitionsFrom(s, COURIER).filter { it.rpc == "cancel_order_by_courier" }
  assertEquals(2, edges.size)
  assertEquals(setOf(READY, CANCELLED_BY_COURIER), edges.map { it.to }.toSet())
  edges.forEach { assertTrue(REASSIGNABLE_REASON in it.guards || NON_REASSIGNABLE_REASON in it.guards) }
}
```

---

**5. `test_allRandomWalksTerminate`** (:102-125)

*Property:* For each seed in `0..<5000`, a uniform random walk from `created` (even seeds) or `scheduled` (odd seeds), choosing uniformly among **all** outgoing edges of the current state, reaches a terminal status within **500** steps.

*Algorithm:* 5,000 seeded random walks, `maxSteps = 500`. On failure it prints the seed and the whole path.

*What it does and does not establish.* This is a **statistical** termination check, not a proof — it samples 5,000 of infinitely many schedules. It is strong here only because escape probability from the one cycle is high: at `ready` 3 of 5 outgoing edges exit the SCC, at `assigned` 4 of 6 do, at `courier_arrived_restaurant` 4 of 6 do. The probability of 500 consecutive in-cycle choices is astronomically small. Note also that the walk **ignores guards entirely** — it is a property of the graph, not of any reachable server state. The real termination argument is invariant 15.

*Kotlin:* keep the structure verbatim — it is cheap and catches dead ends that invariant 1 would miss if a *set* of states mutually trapped an order.
```kotlin
@Test fun allRandomWalksTerminate() {
  repeat(5_000) { seed ->
    val rng = Random(seed + 1)
    var cur = if (seed % 2 == 0) CREATED else SCHEDULED
    val path = mutableListOf(cur.wire)
    var steps = 0
    while (!cur.isTerminal) {
      check(++steps <= 500) { "walk did not terminate (seed $seed): ${path.joinToString(" -> ")}" }
      val opts = OrderLifecycle.transitionsFrom(cur)
      check(opts.isNotEmpty()) { "non-terminal ${cur.wire} had no exit (seed $seed)" }
      cur = opts[rng.nextInt(opts.size)].to
      path += cur.wire
    }
  }
}
```

---

**6. `test_anyObligationImpliesVisibility`** (:137-148)

*Property:* For every `(actor, status)` pair (all 68), if `obligations(actor, status) ≠ ∅` then `isVisible(status, actor)`.

*Algorithm:* none — exhaustive 4 × 17.

*Why (:128-136):* this is the merchant hand-off bug as a law. "Merchant's order list filtered out `.assigned`, while the merchant was simultaneously the only party able to read out the pickup code — so the order vanished from the tablet exactly when the courier reached the counter."

*Note:* given `visibleStatuses`'s definition (§6), this invariant is **tautological** — the second term of the union *is* "has a non-empty obligation set." It cannot fail while `visibleStatuses` is written that way. Its value is as a **guard against the derivation being replaced**: if someone reverts `visibleStatuses` to a hand-written array, this starts failing. Worth porting, worth knowing it proves nothing about the current code.

*Kotlin:*
```kotlin
@Test fun anyObligationImpliesVisibility() {
  for (a in OrderActor.entries) for (s in OrderStatus.entries) {
    val o = OrderLifecycle.obligations(a, s)
    if (o.isNotEmpty()) assertTrue(OrderLifecycle.isVisible(s, a),
      "${a.wire} has $o at ${s.wire} but cannot see that status")
  }
}
```

---

**7. `test_anyActionableStatusIsVisible`** (:151-160)

*Property:* For every actor and every `s ∈ actionableStatuses(actor)`, `isVisible(s, actor)`.

*Algorithm:* none.

*Note:* tautological for the same reason as 6 — this is the *first* term of the union. Same rationale for keeping it.

*Kotlin:* trivial loop mirroring 6.

---

**8. `test_merchantSeesEntireHandoffWindow`** (:164-175)

*Property:* For each `s ∈ {assigned, courierArrivedRestaurant}`: `isVisible(s, .merchant)` **and** `showPickupCode ∈ obligations(.merchant, s)`.

*Algorithm:* none — the explicit named regression test for the reported production bug.

*Not tautological*, unlike 6 and 7: it pins the specific obligation content, which no derivation supplies. If someone deletes the `showPickupCode` arm, invariant 6 still passes (the arm also yields `trackProgress`) but this one fails. This is the one obligation assertion with real teeth.

*Kotlin:*
```kotlin
@ParameterizedTest @EnumSource(names = ["ASSIGNED", "COURIER_ARRIVED_RESTAURANT"])
fun merchantSeesEntireHandoffWindow(s: OrderStatus) {
  assertTrue(OrderLifecycle.isVisible(s, MERCHANT), "merchant blind at ${s.wire}")
  assertTrue(SHOW_PICKUP_CODE in OrderLifecycle.obligations(MERCHANT, s))
}
```

---

**9. `test_consumerCancelPredicateMatchesTransitionTable`** (:181-191)

*Property:* For every status `s`, `s.consumerCanCancel == canTransition(from: s, to: .cancelledByCustomer, by: .consumer)`.

*Algorithm:* none — differential test between a hand-written predicate and the table, over all 17 states.

*Why:* "`consumerCanCancel` was written by hand before the table existed. Proving the two agree is what makes replacing the predicate safe." Both sides evaluate to the same 7 states (rows 20-26), and I independently confirmed the SQL agrees: `cancel_order_by_consumer` accepts `status NOT IN ('created','accepted','preparing','ready','assigned','courier_arrived_restaurant','scheduled')` → error (mig 13:457-460). **All three representations match.** This is the one place in the whole file where model, client predicate, and server are provably in sync.

*Kotlin:* keep as a differential test if you port `consumerCanCancel`; **better**, delete the predicate and make it a derived property, which retires the invariant.
```kotlin
@Test fun consumerCancelPredicateMatchesTransitionTable() {
  OrderStatus.entries.forEach { s ->
    assertEquals(s.consumerCanCancel,
      OrderLifecycle.canTransition(s, CANCELLED_BY_CUSTOMER, CONSUMER), "disagree at ${s.wire}")
  }
}
```

---

**10. `test_courierCancelPredicateMatchesTransitionTable`** (:194-204)

*Property:* For every status `s`, `s.courierCanCancel == transitions(from: s, by: .courier).any { $0.rpc == "cancel_order_by_courier" }`.

*Algorithm:* none. Note the asymmetry with 9: because the courier cancel branches to two different targets, this checks for *any edge via that RPC* rather than a specific `to`. Both sides = `{assigned, courierArrivedRestaurant}`, matching mig 13:521-524.

*Kotlin:* as 9, matching on rpc rather than target.

---

**11. `test_transitionRPCsAreNamedAndKnown`** (:213-233)

*Property:* Three parts. (a) Every row's `rpc` is non-empty. (b) Every row's `rpc` is in `implementedRPCs ∪ knownMissing`, where `knownMissing` is the hard-coded 5-name allowlist at :215-217. (c) `unimplementedRPCs == knownMissing` exactly.

*Algorithm:* none.

*Why:* "The audit found the merchant app calling `cancel_order_by_consumer` — the *consumer's* RPC — which failed silently in production. Pinning each edge to a named function turns that class of mistake into a test failure." Part (c) is a ratchet: ":229-232 — if someone implements these, this fails and the allowlist must shrink."

*The weakness:* `implementedRPCs` is a **hand-maintained literal set** (OrderLifecycle.swift:197-209), not read from the migrations. Nothing stops it drifting from SQL. I verified it against the 33 actual `CREATE FUNCTION`s and it is currently correct, but that is luck, not enforcement. **The Kotlin port should generate this set from the migration directory** (the repo already has `scripts/schema_drift.py` doing analogous work for tables) so part (b) becomes a real check instead of a self-consistency check.

*Kotlin:*
```kotlin
@Test fun transitionRpcsAreNamedAndKnown() {
  val knownMissing = setOf("merchant_accept_order", "merchant_start_preparing",
    "merchant_reject_order", "merchant_mark_order_ready", "merchant_cancel_order")
  OrderLifecycle.transitions.forEach { t ->
    assertTrue(t.rpc.isNotEmpty())
    assertTrue(t.rpc in OrderLifecycle.implementedRpcs || t.rpc in knownMissing,
      "${t.from.wire} -> ${t.to.wire} names unknown RPC '${t.rpc}'")
  }
  assertEquals(knownMissing, OrderLifecycle.unimplementedRpcs)
}
// and, new, the check Swift lacks:
@Test fun implementedRpcsMatchMigrations() =
  assertEquals(OrderLifecycle.implementedRpcs, MigrationScanner.scanFunctionNames()
    .intersect(OrderLifecycle.transitions.map { it.rpc }.toSet()))
```

---

**12. `test_courierCancelReturnsOrderToPool`** (:237-249)

*Property:* `canTransition(from: s, to: .ready, by: .courier)` for `s ∈ {assigned, courierArrivedRestaurant}`, **and** `canTransition(from: .ready, to: .assigned, by: .courier)`.

*Algorithm:* none, but this is the pair of facts that **creates** the cycle analysed in 14 and 15. The final assertion's message names the hazard: "`.ready` must be re-claimable or a courier cancel strands the order."

*Kotlin:* three `assertTrue`s.

---

**13. `test_deliveryAlwaysRequiresProof`** (:253-263)

*Property:* `transitions.filter { $0.to == .delivered }` is non-empty, and **every** such row's guards contain `deliveryCode` or `proofImage`.

*Algorithm:* none.

*Why:* "a courier could mark it delivered from the road."

**⚠ This invariant is FALSE against the real server, and passes only because of a bug in the table.** Two server paths reach `delivered`:

1. `courier_deliver_order` — requires code or photo. ✓ But it accepts `v_status IN ('delivering','courier_arrived_customer')` (mig 13:401-404), so there is a real `delivering → delivered` edge that the table omits. Harmless for *this* invariant (proof is still required) but see §9.
2. **`mark_no_show_deliveries` — sets `status = 'delivered'` with NO code and NO photo** (mig 16:60-72: `WHERE status = 'courier_arrived_customer' AND no_show_started_at + interval '5 minutes' <= now()` → `UPDATE orders SET status = 'delivered', no_show = true, cancellation_reason_code = 'CUSTOMER_NO_SHOW'`).

The table records that edge as `courier_arrived_customer → cancelled_by_system` (row 36). Because the recorded target is not `delivered`, the filter never sees it and the test passes. **Correct the target and this invariant fails immediately.** The Kotlin port must either add a third proof guard (`customerNoShowTimer` — arguably a legitimate proof of attempted delivery) or restate the invariant as "every *courier-initiated* delivery requires proof."

*Kotlin (restated correctly):*
```kotlin
@Test fun deliveryAlwaysRequiresProof() {
  val edges = OrderLifecycle.transitions.filter { it.to == DELIVERED }
  assertTrue(edges.isNotEmpty())
  edges.filter { it.actor == COURIER }.forEach {
    assertTrue(DELIVERY_CODE in it.guards || PROOF_IMAGE in it.guards,
      "${it.from.wire} -> delivered via ${it.rpc} requires no proof")
  }
  // system no-show completion is proof-exempt by design — pin it explicitly
  assertEquals(setOf(NO_SHOW_TIMER_ELAPSED),
    edges.single { it.actor == SYSTEM }.guards)
}
```

---

**14. `test_theOnlyCycleIsTheCourierRequeueLoop`** (:273-281)

*Property:* `stronglyConnectedComponents()` has exactly **1** element, and that element equals `{ready, assigned, courierArrivedRestaurant}`.

*Algorithm:* **Tarjan's strongly-connected-components algorithm**, iterative form, OrderLifecycle.swift:323-390.

*What the SCC computation actually is.* Standard Tarjan: a single DFS assigning each node a monotonically increasing `index` and a `lowlink` (the smallest index reachable from its subtree via at most one back-edge to a node still on the stack). A node with `lowlink == index` is a component root; the component is everything above it on the stack. Recursion is replaced by an explicit `callStack` of `(status, successors, next)` frames — the comment at :331-332 explains why ("the recursive form is fine at 17 nodes, but an explicit stack keeps it safe if the status set grows"). The lowlink back-propagation to the parent frame is done manually at :378-382 (which contains a harmless no-op, `parent.next = parent.next`, at :379).

**Crucially, it is not plain Tarjan: the filter at :372-375 drops singleton components without a self-loop.** So a non-empty result means *real cycles exist*, and `components.count` is a cycle count, not a component count. Plain Tarjan on this graph would return 17 components.

*I differential-tested this implementation.* I transliterated it verbatim into a generic `Int`-node version and compared against a brute-force mutual-reachability SCC (with the same singleton filter) on **20,000 random digraphs** (2-8 nodes, ~28% edge density): **0 mismatches.** The hand-rolled iterative Tarjan is correct, so the liveness argument in invariant 15 rests on sound footing.

*Verified result on the real graph:* exactly one SCC, `{ready, assigned, courier_arrived_restaurant}` — matching the assertion. The four edges with both endpoints inside it (`cyclicTransitions()`):

| edge | rpc | guards |
|---|---|---|
| `ready → assigned` | `claim_order` | `courierOnline`, `courierNotBusy`, `courierNotSuspended` |
| `assigned → courier_arrived_restaurant` | `courier_arrived_restaurant` | — |
| `assigned → ready` | `cancel_order_by_courier` | `notOnCancelCooldown`, `reassignableReason` |
| `courier_arrived_restaurant → ready` | `cancel_order_by_courier` | `notOnCancelCooldown`, `reassignableReason` |

*Kotlin:* do **not** transliterate the iterative Tarjan. Use a library SCC (JGraphT `KosarajuStrongConnectivityInspector`, or a 20-line recursive Tarjan — 17 nodes will never overflow a JVM stack), then apply the singleton filter as a separate step so the "non-empty means cycles" semantics stays explicit.
```kotlin
@Test fun theOnlyCycleIsTheCourierRequeueLoop() {
  val cycles = OrderLifecycle.stronglyConnectedComponents()  // singleton-filtered
  assertEquals(1, cycles.size, "expected exactly one cycle, found $cycles")
  assertEquals(setOf(READY, ASSIGNED, COURIER_ARRIVED_RESTAURANT), cycles.single())
}
```

---

**15. `test_everyCycleIsBoundedByAGuard`** — **the liveness proof** (:292-308)

*Property:* For every edge `e` in `cyclicTransitions()` (both endpoints in one SCC), if `e.to.stepIndex < e.from.stepIndex` then `e.guards ∩ boundingGuards ≠ ∅`.

*Algorithm:* Tarjan SCC (invariant 14) → `cyclicTransitions()` filter → a `stepIndex` comparison to classify backward edges → a disjointness check against `boundingGuards = {notOnCancelCooldown}`.

### What this proves, exactly

The argument has four steps, and the doc comments at OrderLifecycle.swift:306-322 and the test at :283-291 spell out the logic:

1. **Acyclicity is unavailable.** A naive reading says orders only move forward, so termination is structural. That is false: `cancel_order_by_courier` with a restaurant-fault reason sends `assigned → ready`, and `ready` is claimable again. Invariant 14 proves this is a genuine SCC. So termination **cannot** be proved by showing the graph is a DAG, and a standard cycle check would reject a correct design.

2. **Termination is therefore not a graph property at all** — it is a property of the graph *plus* the server's rate limits. The comment states it plainly: "Termination therefore is *not* a structural property of the graph and cannot be proved by acyclicity."

3. **What actually bounds it** is SQL state outside the graph: `cancel_order_by_courier` refuses a courier with ≥3 cancels in 24 h (`courier_cancellation_log`, mig 13:502-509), and `reassign_count` is incremented on every requeue.

4. **The invariant is the graph-side half of that argument.** It proves: *every* edge that moves an order backwards *within* a cycle carries a guard the server rate-limits. Hence every cycle traversal must consume a bounded resource, hence no order can circulate forever.

**Therefore this test is not itself a termination proof — it is a proof obligation discharged against a side condition.** It proves the graph admits no *unbounded* cycle traversal *given* that `notOnCancelCooldown` is genuinely finite. It cannot see whether the SQL actually enforces the limit. The two halves must be verified separately, and the Kotlin port owns both.

*Verified result:* of the four cyclic edges, two go backwards by `stepIndex` — `assigned(4) → ready(3)` and `courier_arrived_restaurant(5) → ready(3)` — and both carry `notOnCancelCooldown`. The other two go forward and are skipped. Test passes.

*Fragility to flag:* `stepIndex` is the only reason "backwards" is decidable, and it is a hand-assigned integer with 7 states sharing `-1`. If a future cyclic edge touched a cancel state, the comparison would be nonsense. Also `boundingGuards` is a one-element set; the reconciled graph in §9 adds a backward edge (`assigned → ready` via the escalation ladder) bounded by `reassign_count >= 3` instead, which needs a **second** bounding guard.

*Kotlin:*
```kotlin
@Test fun everyCycleIsBoundedByAGuard() {
  val cycles = OrderLifecycle.stronglyConnectedComponents()
  if (cycles.isEmpty()) return  // acyclic terminates trivially
  OrderLifecycle.cyclicTransitions()
    .filter { it.to.stepIndex < it.from.stepIndex }   // backward edges only
    .forEach { e ->
      assertTrue(e.guards.any { it in OrderLifecycle.boundingGuards },
        "${e.from.wire} -> ${e.to.wire} via ${e.rpc} moves backwards inside a cycle " +
        "with no bounding guard — an order can circulate forever")
    }
}
```

---

**16. `test_everyStatusCanReachATerminalState`** (:312-321)

*Property:* For every non-terminal status `s`, there exists a terminal status `t` with `minimumSteps(from: s, to: t) != nil`.

*Algorithm:* BFS (`minimumSteps`, OrderLifecycle.swift:410-428) from each of the 10 non-terminal states to each of the 7 terminals.

*Why:* "Stronger than 'has an exit': an exit into a closed cycle would still strand the order." Invariant 1 forbids dead-end *nodes*; this forbids dead-end *regions*.

*Verified distances to nearest terminal:*

| status | steps |
|---|---|
| `scheduled`, `created`, `accepted`, `preparing`, `ready`, `assigned`, `courier_arrived_restaurant` | 1 |
| `courier_arrived_customer` | 1 |
| `delivering` | 2 |
| `picked_up` | 3 |

Note what this exposes: in the **declared** table, `picked_up` and `delivering` have *no cancel edge at all*. Their only route to a terminal state is completing the delivery (`picked_up → delivering → courier_arrived_customer → delivered`). The real server does have post-pickup force-cancel via the escalation ladder — see §9 drift 3.

*Kotlin:*
```kotlin
@Test fun everyStatusCanReachATerminalState() {
  val terminals = OrderStatus.entries.filter { it.isTerminal }
  OrderStatus.entries.filterNot { it.isTerminal }.forEach { s ->
    assertTrue(terminals.any { OrderLifecycle.minimumSteps(s, it) != null },
      "${s.wire} cannot reach any terminal state")
  }
}
```

---

**17. `test_happyPathLengthIsStable`** (:326-339)

*Property:* `minimumSteps(.created, .delivered)` and `minimumSteps(.scheduled, .delivered)` are both non-nil; the scheduled distance is exactly `created + 1`; and the created distance is exactly **7**.

*Algorithm:* BFS.

*Verified:* `created → delivered = 7`, `scheduled → delivered = 8`. The 7-step path is named in the comment (:336-337): `created → accepted → assigned → arrived_restaurant → picked_up → delivering → arrived_customer → delivered`. Note it routes `accepted → assigned` directly (row 7), skipping `preparing` and `ready` — the courier may claim before the food is ready, per OrderLifecycle.swift:120-121.

*This is a characterization test, not an invariant* — the `== 7` is a tripwire ("shortest path to delivery changed; confirm this is intended"). It is the test most likely to need updating during the port: adding the real `delivering → delivered` edge (§9 drift 1) would shorten the path to **6** and this test would fail. That failure is correct and informative.

*Kotlin:*
```kotlin
@Test fun happyPathLengthIsStable() {
  val fromCreated = assertNotNull(OrderLifecycle.minimumSteps(CREATED, DELIVERED))
  val fromScheduled = assertNotNull(OrderLifecycle.minimumSteps(SCHEDULED, DELIVERED))
  assertEquals(fromCreated + 1, fromScheduled,
    "a scheduled order should be exactly one activation step further from delivery")
  assertEquals(7, fromCreated, "shortest path to delivery changed; confirm this is intended")
}
```

### Coverage gaps — invariants that are absent and should be added

| Missing property | Why it matters |
|---|---|
| Every terminal status is visible to ≥1 actor | §6: nobody can see `delivered`; no invariant catches it |
| `implementedRPCs` matches the migration directory | Invariant 11 is self-consistent, not server-consistent |
| The declared table matches the SQL edge set | §9: 8 drifts, all invisible to the suite |
| `reassignableReason` and `nonReassignableReason` never co-occur on one edge | Their exclusivity is documented but unasserted |
| Every non-terminal status has ≥1 *cancel* path | `picked_up`/`delivering` currently have none |
| Every `(from, to, actor)` triple is unique, or `canTransition` is guard-aware | Rows 14/15 collide; naive map-keying drops one |

---

## 9. The declared table vs. the actual SQL — 8 drifts

The header says the table is "Derived from migration 13's RPC guards, the four merchant operations, and the pg_cron jobs" (OrderLifecycle.swift:100-101). Migration 13 it gets right. **The pg_cron jobs it gets substantially wrong.** I enumerated every `status = '<literal>'` write across all 19 migrations (21 writes total) and reconciled them against the 36 declared rows.

### Drift 1 — missing `delivering → delivered`

`courier_deliver_order` accepts **`v_status IN ('delivering','courier_arrived_customer')`** (mig 13:401-404). The table declares only the `courier_arrived_customer` source. So a courier can legally deliver without ever marking arrival. Proof is still required, so this is not a security hole — but it shortens the happy path to 6 and breaks invariant 17.

### Drift 2 — missing `scheduled → cancelled_by_system`

`activate_scheduled_order` (mig 06:21-83, driven by the `activate_scheduled_orders` sweep at :85-104) has **four** cancel exits in addition to `scheduled → created`:

| condition | reason code | line |
|---|---|---|
| restaurant missing / not `active` / outside hours | `RESTAURANT_NOT_OPEN_AT_SCHEDULED_TIME` | mig 06:41 |
| `order_items.menu_item_id IS NULL` | `ITEM_DELETED` | mig 06:55 |
| item deleted / unavailable | `ITEM_UNAVAILABLE` | mig 06:63 |
| `stock_count < quantity` | `INSUFFICIENT_STOCK` | mig 06:70 |

So `scheduled → cancelled_by_system` via `activate_scheduled_orders` is a real system edge, entirely absent from the table. (All four reason codes do exist in `CancellationReason`, lines 30-33.)

### Drift 3 — the escalation ladder's from-set is wrong in both directions

Both ladder definitions (mig 14:33-110 and its redefinition at mig 17:18-110) filter on
`status IN ('assigned','courier_arrived_restaurant','picked_up','delivering','courier_arrived_customer')`
in all three passes. Pass 3 then branches (mig 14:83-96):

- `assigned` / `courier_arrived_restaurant` → `PERFORM reassign_ghosted_order(id)`
- everything else (`picked_up`, `delivering`, `courier_arrived_customer`) → `status = 'cancelled_by_system'`, reason `COURIER_NON_RESPONSIVE`, with a −100% earnings clawback

And `reassign_ghosted_order` (mig 13:651-709) itself branches on the requeue budget:

- `reassign_count + 1 >= 3` → `status = 'cancelled_by_system'`, reason `RESTAURANT_TOO_LONG_WAIT`
- otherwise → `status = 'ready'`, clearing `courier_id`, `claimed_at`, `arrived_at_restaurant_at`, `expected_action_by`, and **appending the ghosted courier to `excluded_courier_ids`**

Reconciliation:

| declared row | verdict |
|---|---|
| 30: `created → cancelled_by_system` | **PHANTOM** — ladder never touches `created` |
| 31: `accepted → cancelled_by_system` | **PHANTOM** |
| 32: `preparing → cancelled_by_system` | **PHANTOM** |
| 33: `ready → cancelled_by_system` | **PHANTOM** |
| 34: `assigned → cancelled_by_system` | real, but only when `reassign_count+1 >= 3` |
| 35: `courier_arrived_restaurant → cancelled_by_system` | real, same condition |

| real edge | declared? |
|---|---|
| `assigned → ready` via ladder | **MISSING** |
| `courier_arrived_restaurant → ready` via ladder | **MISSING** |
| `picked_up → cancelled_by_system` via ladder | **MISSING** |
| `delivering → cancelled_by_system` via ladder | **MISSING** |
| `courier_arrived_customer → cancelled_by_system` via ladder | **MISSING** (row 36 attributes this pair to the wrong RPC — see drift 4) |

The two missing `→ ready` edges are the dangerous ones: they are **system-actor backward edges inside the SCC**, and they carry **no `notOnCancelCooldown` guard** (that guard is per-courier and the ladder is not a courier action). Add them to the table as-is and **invariant 15 fails** — correctly, because the bound is a different mechanism (`reassign_count >= 3`, checked inside `reassign_ghosted_order`). The port needs a second bounding guard, e.g. `reassignBudgetRemaining`, added to `boundingGuards`.

### Drift 4 — `mark_no_show_deliveries` has the wrong target

Declared row 36: `courier_arrived_customer → cancelled_by_system`.
Actual (mig 16:49-74): `courier_arrived_customer → **delivered**`, with `no_show = true`, `delivered_at = now()`, `cancellation_reason_code = 'CUSTOMER_NO_SHOW'`, and the comment "Earnings = full." Precondition: `no_show_started_at IS NOT NULL AND no_show_started_at + interval '5 minutes' <= now()`, where `no_show_started_at` is stamped by `courier_report_customer_no_show` (mig 16:14-44).

A customer no-show is treated as a **successful delivery**, not a cancellation. That is a deliberate, defensible product decision — and the table records the exact opposite. As noted in invariant 13, this single error is what lets `test_deliveryAlwaysRequiresProof` pass.

### Drift 5 — missing `courier_arrived_restaurant → cancelled_by_system` via `courier_report_restaurant_delay`

`courier_report_restaurant_delay` (mig 16:78-135, redefined mig 17:227-…) requires `v_status = 'courier_arrived_restaurant'`, accumulates `restaurant_delay_min`, and when the total exceeds 30 sets `status = 'cancelled_by_system'` with reason `RESTAURANT_TOO_LONG_WAIT` and a 50% courier earning. Actor is **courier** (it is `auth.uid()`-gated and authorization-checked against `orders.courier_id`), RPC is `courier_report_restaurant_delay`. Neither the edge nor the RPC appears anywhere in the table or in `implementedRPCs`.

### Drift 6 — `claim_order` is missing two guards

Covered in §4: `courier_id IS NULL` (mig 13:197) and `courier_excluded` (mig 13:201-204).

### Drift 7 — `accepted`, `preparing`, `rejected` have no server producer

Covered in §7. No migration writes any of the three. They are produced exclusively by client-side compare-and-swap UPDATEs.

### Drift 8 — `assignCourier` is an undeclared duplicate of `claim_order`

`SupabaseService.assignCourier` (SupabaseService.swift:641-657) writes `status = 'assigned'` for `status IN ('accepted','preparing','ready') AND courier_id IS NULL` by direct UPDATE, bypassing `claim_order` and all its guards. Same three edges as rows 7-9, different mechanism, not in the model.

### Reconciled system/courier edge set for the Kotlin port

Replace declared rows 30-36 with:

| from | to | actor | rpc | guards |
|---|---|---|---|---|
| `scheduled` | `created` | system | `activate_scheduled_orders` | `restaurantOpenAtScheduledTime`, `itemsStillAvailable` |
| `scheduled` | `cancelled_by_system` | system | `activate_scheduled_orders` | (negation of the above) |
| `assigned` | `ready` | system | `run_courier_escalation_ladder` | `courierGhosted`, **`reassignBudgetRemaining`** |
| `courier_arrived_restaurant` | `ready` | system | `run_courier_escalation_ladder` | `courierGhosted`, **`reassignBudgetRemaining`** |
| `assigned` | `cancelled_by_system` | system | `run_courier_escalation_ladder` | `courierGhosted`, `reassignBudgetExhausted` |
| `courier_arrived_restaurant` | `cancelled_by_system` | system | `run_courier_escalation_ladder` | `courierGhosted`, `reassignBudgetExhausted` |
| `picked_up` | `cancelled_by_system` | system | `run_courier_escalation_ladder` | `courierGhosted` |
| `delivering` | `cancelled_by_system` | system | `run_courier_escalation_ladder` | `courierGhosted` |
| `courier_arrived_customer` | `cancelled_by_system` | system | `run_courier_escalation_ladder` | `courierGhosted` |
| `courier_arrived_customer` | `delivered` | system | `mark_no_show_deliveries` | `noShowTimerElapsed` |
| `courier_arrived_restaurant` | `cancelled_by_system` | courier | `courier_report_restaurant_delay` | `restaurantDelayCapExceeded` |
| `delivering` | `delivered` | courier | `courier_deliver_order` | `deliveryProof(mode)` |

That is 12 rows replacing 7, plus the `delivering → delivered` addition, giving **41 edges** in the reconciled graph. Guard count rises from 9 to roughly 17.

---

## 10. Port checklist

1. **Transcribe, don't infer.** States (§1, note the seven explicit `rawValue` overrides), actors (§2), guards (§4), obligations (§5). All four are hand-declared data with no generating rule.
2. **Decide the drift question before writing code.** Port the declared 36-edge table (faithful to Swift, wrong about the server) or the reconciled 41-edge graph (§9)? Only the second can be the basis of a real service. Recommend the second, with a test asserting the Kotlin table matches a migration-scraped edge set.
3. **Preserve obligation match order** — the consumer wildcard at OrderLifecycle.swift:263 comes after the `courierArrivedCustomer` arm. Pre-expanded for you in §5.
4. **Collapse rows 14/15** into one edge with a `DeliveryMode`-dependent proof guard. Fixes the 36-vs-35 keying hazard and matches the SQL, which branches on the column not on courier choice.
5. **Add the third visibility term** (§6) or ship an app where no screen can display a completed order.
6. **Use a library SCC.** The hand-rolled iterative Tarjan is verified correct (20,000 random graphs, 0 mismatches) but there is no reason to re-derive it. Keep the singleton-without-self-loop filter as an explicit post-step so "non-empty means cycles exist" stays legible.
7. **Two bounding guards, not one.** `notOnCancelCooldown` (per-courier, 3/24 h) and `reassignBudgetRemaining` (per-order, `reassign_count < 3`) bound the two different backward mechanisms into `ready`.
8. **Port all 17 invariants, fixing 13 and expecting 17 to change.** Add the six missing invariants in §8.
9. **Nothing depends on this file today** (§0 correction 3), so there is no migration risk and no compatibility surface — but equally, do not assume any current app behaviour matches it.
