# Consumer app (DuDash) — constraints on the Kotlin backend extraction plan

Source: `/Users/mmarufov/conductor/workspaces/ravon-consumer/kolkata/.context/STATE-REPORT.md`
(32,822 bytes, read in full) + that repo's `CLAUDE.md`.

Repo state at time of reading: branch `mmarufov/kolkata-v1`, HEAD `1ffcb1a feat: integrate
shared RavonAuthFlow (#4)`.

Every claim below was re-verified against the actual source file unless marked
`UNKNOWN` or `report-only`. Citations are `file:line` in the consumer repo unless the path
begins `Sources/` (= RavonCore, this repo) or `.context/` (= this repo).

**Bottom line for the plan:** the consumer app is a *small* blast radius. It touches only
22 RavonCore methods and exactly 4 RPCs. There is exactly **one** direct `orders` write and
**zero** direct writes to `order_items` / `order_status_history`. But three things in the
brief chain are wrong or incomplete, and two of them are load-bearing:

1. `ServiceError.from(serverError:)` is **not** unused in production — it has 7 production
   call sites. The orchestrator's "ZERO production call sites" and PROMPT §9's "every
   structured `P0001`/`DETAIL` payload is currently discarded" are both **wrong**.
2. Adding `p_delivery_mode` to `create_order` is **not sufficient** — the migration-10
   `BEFORE INSERT` trigger unconditionally stomps it. Nobody has noticed this.
3. Dropping the client `orders` UPDATE policy does **not** produce an error the client
   could surface even if it wanted to. RLS turns it into a silent 0-row no-op, so the
   STATE-REPORT's "it's `try?`, so the failure is swallowed" understates it — removing the
   `try?` would not help.

---

## 1. Direct writes to `orders` / `order_items` / `order_status_history`

### The complete direct-write surface (verified by exhaustive grep)

`grep -rn '\.from(' --include='*.swift'` over the whole consumer repo returns **exactly 3
hits**:

| hit | what it is | blocking? |
|---|---|---|
| `DuDash/ViewModels/ConfirmOrderViewModel.swift:121` | `AuthService.shared.supabaseClient.from("orders").update(...)` | **YES — the only one** |
| `DuDash/Views/Orders/OrderDetailView.swift:598` | `ServiceError.from(serverError:)` — unrelated static method, name collision | no |
| `DuDash/Views/Orders/OrderDetailView.swift:787` | `.storage.from("delivery-proofs")` — signed-URL read for the leave-at-door photo | no |

`grep -rn '\.rpc('` over the consumer repo returns **0 hits** — every RPC goes through
RavonCore. `grep -rln 'import Supabase'` returns exactly 2 files
(`ConfirmOrderViewModel.swift`, `OrderDetailView.swift`), consistent with the
orchestrator's established fact.

**`order_items`: zero direct writes. `order_status_history`: zero direct writes.** Both are
read-only from this app:
- `order_items` is only ever read as a PostgREST *embed*:
  `Sources/RavonCore/Services/SupabaseService.swift:277` and `:285` —
  `.select("*, restaurants(*), order_items(*)")`.
- `order_status_history` is read by `fetchOrderStatusHistory` —
  `Sources/RavonCore/Services/SupabaseService.swift:293`, a plain `.from(...).select()`.

So `orders`, `order_items` and `order_status_history` all still need **SELECT** reachability
for this app. Only `orders` needs a write path removed.

### The one blocking write, verbatim

`DuDash/ViewModels/ConfirmOrderViewModel.swift:109-131`:

```swift
let id = try await SupabaseService.shared.createOrder(
    restaurantId: restaurant.id,
    addressId: address.id,
    items: items,
    notes: notes.isEmpty ? nil : notes,
    scheduledFor: scheduledFor
)
// 5) If the user overrode the per-address default mode on the checkout sheet,
//    UPDATE the row directly. Best-effort — failure here does not invalidate
//    the placed order; the address's default mode remains in force.
if let override = deliveryModeOverride, override != address.defaultDeliveryMode {
    try? await AuthService.shared.supabaseClient.from("orders")
        .update(["delivery_mode": AnyJSON.string(override.rawValue)])
        .eq("id", value: id.uuidString)
        .execute()
}
```

Confirmed: `createOrder` in RavonCore
(`Sources/RavonCore/Services/SupabaseService.swift:343-365`) has **no** `deliveryMode`
parameter. `CreateOrderParams` (`:314-329`) carries only
`p_restaurant_id, p_address_id, p_items, p_notes, p_scheduled_for`.

### Correction / amplification the STATE-REPORT gets wrong

The report says (§5): *"It is `try?`. After migration 20 this fails and is **swallowed
silently**."* The `try?` is real, but it is not what makes the failure silent.

Migration 20's plan §1
(`.context/plans/migration-20-lock-orders-to-rpc-only-writes-closes.md`) drops all
client UPDATE/INSERT/DELETE **policies** on `orders`, keeping SELECT. With RLS enabled and
no UPDATE policy, the `USING` clause is effectively `false` → Postgres matches **0 rows** →
PostgREST returns success with an empty result. **No error is raised.** `delivery_mode` is
also *not* in the column allow-list trigger's block list (that trigger checks
`subtotal, total, delivery_fee, tip_amount, courier_id, status, user_id` — plan §4, lines
78-85), so there is no `42501` fallback either.

Consequence for the plan: **deleting the `try?` would not surface this.** The only fix is to
remove the second round trip entirely. Any migration/extraction step that drops the policy
without simultaneously landing a server-side `delivery_mode` input ships a silent
correctness bug — leave-at-door orders become hand-to-me with zero signal, and the courier
then demands a verification code the consumer was never shown.

### And the fix the report asks for does not work as stated

The report's §3 item 2 asks for `p_delivery_mode` on `create_order` and says "then the §5
hit disappears." **Verified incomplete.** `.context/migrations/10_dual_verification_codes_and_delivery_mode.sql:55-73`:

```sql
CREATE OR REPLACE FUNCTION sync_order_delivery_mode_from_address()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_default text;
BEGIN
  IF NEW.address_id IS NOT NULL THEN
    SELECT default_delivery_mode INTO v_default FROM addresses WHERE id = NEW.address_id;
    IF v_default IS NOT NULL THEN
      NEW.delivery_mode := v_default;     -- ← unconditional overwrite
    END IF;
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER orders_sync_delivery_mode BEFORE INSERT ON orders FOR EACH ROW ...
```

The assignment is unconditional — there is no `IF NEW.delivery_mode IS NULL` guard. So a
`create_order` that sets `delivery_mode` explicitly on INSERT gets **stomped by the
trigger**. Worse, the column is declared `NOT NULL DEFAULT 'hand_to_me'` (migration 10:25),
so inside a `BEFORE INSERT` trigger "caller explicitly asked for `hand_to_me`" is
**indistinguishable** from "caller supplied nothing." There is no sentinel available.

Required work, whichever architecture wins:
- Rewrite the trigger to `IF NEW.delivery_mode IS NULL THEN ... END IF` **and** drop the
  column default (or make it nullable) so the sentinel exists; **or**
- Move the "default from address" resolution into the caller (`create_order`, or the Kotlin
  order service) and delete the trigger.

For the Kotlin plan the second is correct: this is exactly the "business logic lives in SQL"
problem PROMPT §3 cites. But note the trigger is an *implicit contract the consumer app
currently depends on* — `ConfirmOrderViewModel.swift:34-36` documents it in a comment
(`"nil = honour the BEFORE INSERT trigger that copies address.default_delivery_mode"`), so
deleting the trigger without moving the defaulting logic breaks the no-override path too.

### Other client write policies the consumer needs (not `orders`, but same Phase-0 blast radius)

All via RavonCore, all direct table writes, none RPC-backed:

| table | op | RavonCore site | consumer call sites |
|---|---|---|---|
| `addresses` | INSERT | `Sources/RavonCore/Services/SupabaseService.swift:258` | `DuDash/Views/Cart/AddAddressView.swift:144`, `DuDash/Views/Onboarding/Steps/AddressStep.swift:74` |
| `addresses` | DELETE | `Sources/RavonCore/Services/SupabaseService.swift:267` | `DuDash/Views/Profile/AddressListView.swift:130` |
| `chat_messages` | INSERT | `Sources/RavonCore/Services/SupabaseService.swift:1060` | `DuDash/ViewModels/ChatViewModel.swift:69`, `DuDash/Views/Orders/OrderDetailView.swift:716` |
| `chat_messages` | UPDATE `read_at` | `Sources/RavonCore/Services/SupabaseService.swift:1084` | `DuDash/ViewModels/ChatViewModel.swift:45`, `:55` |

**Security constraint for the plan:** `deleteAddress` (`:267-271`) filters on `id` only — no
`user_id` predicate. `markMessagesAsRead` (`:1084-1090`) filters on `order_id` + `sender_id
!= me` — no order-ownership predicate. Both are **entirely dependent on RLS for
authorization**. PROMPT §3 proposes demoting RLS to "defence-in-depth, not the primary
gate." If that demotion is interpreted as relaxing these policies, both become
`DELETE any address by id` and `mark any order's messages read`. The plan must state that
these two stay RLS-primary, or move them behind RPCs/gRPC too.

### The consumer's complete RPC surface — 4 of the fleet's 21

Derived from `grep -rn 'SupabaseService\.shared\.'` (34 call sites, 22 distinct methods):

- `validate_cart` — `DuDash/ViewModels/ConfirmOrderViewModel.swift:55`
- `create_order` — `DuDash/ViewModels/ConfirmOrderViewModel.swift:110`
- `cancel_order_by_consumer` — via `cancelOrder`, `DuDash/Views/Orders/OrderDetailView.swift:593`
  (RavonCore `Sources/RavonCore/Services/SupabaseService.swift:632-635`)
- `add_tip` — `DuDash/Views/Orders/OrderDetailView.swift:620`
  (RavonCore `Sources/RavonCore/Services/SupabaseService.swift:660-666`)

Everything else the consumer does is a PostgREST read or one of the 4 writes above. **Phase 3
(`services/order`) is the only phase that touches this app's write path at all.** Phase 1
(dispatch) and Phase 2 (ledger) are invisible to it.

---

## 2. Tipping — the exact contract `add_tip` must honour

### Current client behaviour (all verified)

| aspect | fact | evidence |
|---|---|---|
| Entry point | order detail screen only; no Orders-list, no post-checkout prompt | `DuDash/Views/Orders/OrderDetailView.swift:459-487` |
| Gate | `order.status == .delivered, order.tipAmount == nil` | `:460` |
| Amounts | fixed absolute chips `[5.0, 10.0, 20.0, 50.0]`; no custom, no % | `:466` |
| Label | `Text("+\(Int(amount))")` — bare integer, **no currency unit**, bypasses `formatPrice` | `:470` |
| Semantics | add-once; chips vanish once `tipAmount != nil` | `:460` |
| Time window | none client-side; chips render on a delivered order forever | `:460` (no date predicate) |
| Write | `SupabaseService.addTip` → `rpc("add_tip", p_order_id, p_amount)` | `Sources/RavonCore/Services/SupabaseService.swift:660-666` |
| Total display | `formatPrice(order.total + (order.tipAmount ?? 0))` | `:406` |
| Tip row | rendered when tip > 0, `formatPrice(tip)` | `:397` |
| Error handling | `catch { self.error = error.localizedDescription }` | `:617-626`, specifically `:623` |

### Why tip failures are invisible — verified exactly as the report claims

`OrderDetailView.swift:45`:

```swift
} else if let error, order == nil {
```

That is the **only** render site for `error`. In the tip path `order` is non-nil (you are
looking at the order), so the branch is unreachable. The screen's three alerts bind to
`cancelError` (`:514-520`), `showPostPickupCancelAlert` (`:522`) and `supportInfoMessage`
(`:534-540`) — **never** `error`. Confirmed by grep: `error` is assigned at `:583`
(`loadOrder`) and `:623` (`addTip`) and rendered only at `:45`/`:50`.

So a rejected tip today produces: spinner flicker, chips unchanged, **no message at all**.

### There is also a silent no-op inside RavonCore

`Sources/RavonCore/Services/SupabaseService.swift:660-666`:

```swift
public func addTip(orderId: UUID, amount: Double) async throws {
    guard amount >= 0 else { return }     // ← silent success, RPC never called
    ...
}
```

Negative amounts return **without throwing and without calling the RPC**. Unreachable from
the current chips (all positive), but it is a latent "success that did nothing" that the
gRPC port must not reproduce. Note this contradicts migration 20's verification plan step 5,
which expects `p_amount = -1 → INVALID_TIP_AMOUNT` — the client short-circuits before the
server ever sees it, so that test can never fire through the Swift path.

### The proposed contract, from the actual plan document

`.context/plans/migration-20-lock-orders-to-rpc-only-writes-closes.md` §3:

- **Allowed when** `status IN ('delivered','courier_arrived_customer')` AND
  `delivered_at > now() - interval '24 hours'` (or `delivered_at IS NULL` for
  `courier_arrived_customer`).
- **Caller** `auth.uid() = orders.user_id` only.
- **Bounds** `0 ≤ p_amount ≤ LEAST(0.50 * subtotal, 200)`. **Reject** with
  `INVALID_TIP_AMOUNT`.
- **Semantics** replace, not additive. `orders.tip_amount = p_amount`. Idempotent.
- **Earnings sync** `UPDATE courier_earnings SET tip_amount = p_amount,
  total_earned = base + p_amount WHERE order_id = p_order_id`.
- Reason codes named in plan §5: `INVALID_TIP_AMOUNT`, `TIP_WINDOW_CLOSED`, plus
  `UNAUTHORIZED` in the verification list (step 5).

### Precise breakages, and the contract required to avoid them

**B1 — The cap rejects taps the UI offers. Confirmed arithmetic.**
Chips are absolute (`[5,10,20,50]`, `:466`); the cap is subtotal-relative. Subtotal 80 →
cap `LEAST(40, 200) = 40` → the **50 chip is rejected**. Subtotal 20 → cap 10 → the **20 and
50 chips are both rejected**. There is no client-side clamp and no cap knowledge anywhere in
the app.
*Required:* either (a) the RPC **clamps** to the cap and returns the applied value, or (b)
the app gains cap awareness. The report prefers (a) plus defensive chip-hiding; (a) is also
what survives a stale-`subtotal` race. **The plan as written does neither — it rejects.** If
you keep rejection, the cap formula and the definition of `subtotal` must be published to
the client, and the app must gate chips on it before the RPC ships.

**B2 — `subtotal` is ambiguous and the client's number differs from the server's.**
The report assumes `orders.subtotal` (excl. delivery fee). Unresolved, but worse than
ambiguous: the client's cart subtotal **includes modifier prices**
(`DuDash/Models/CartItem.swift:17-23` — `totalPrice = (menuItem.price + modifierTotal) *
quantity`; `DuDash/Services/CartService.swift:17` sums `totalPrice`), while `create_order`
persists no modifiers at all (`OrderItemParam` is `{menu_item_id, quantity}` —
`Sources/RavonCore/Services/SupabaseService.swift:331-339`). So `orders.subtotal` is
systematically **lower** than what the user was shown for any modified order, which makes
the cap systematically tighter than the user would expect. *The plan must define `subtotal`
as a named field on the tip response/error, not leave the client to infer it.*

**B3 — Reason-code names in the plan do not match what the client can decode, and the
request for "the cap value" is unsatisfiable with the current decoder.**
`ServiceError.from(serverError:)` (`Sources/RavonCore/Services/SupabaseService.swift:90-127`)
regex-extracts **only** `"reason":"([A-Z_]+)"` and switch-maps 18 hard-coded kinds. Facts:
- The regex is `[A-Z_]+`, so the report's requested lowercase codes (`tip_exceeds_cap`,
  `tip_window_expired`, `tip_already_set`) would **not match**. Codes must be
  SCREAMING_SNAKE.
- None of the 18 mapped kinds (`:107-124`) is tip-related, so `INVALID_TIP_AMOUNT` /
  `TIP_WINDOW_CLOSED` currently fall to `default: return nil` (`:125`).
- The decoder **discards every sibling key** in the DETAIL payload. Look at the placeholder
  values it fabricates: `courierCancelCooldown(recentCancels: 3)` (`:114`),
  `invalidReasonCode("")` (`:117`), `accuracyTooLow(meters: 0)` (`:118`),
  `courierSuspended(until: nil)` (`:112`). **The cap value cannot travel through this
  channel.** The report's ask ("return `tip_exceeds_cap` with the cap value ... through the
  same DETAIL-JSON channel the cancel flow uses") is not implementable without rewriting
  the decoder to parse the full JSON object.
- `tip_already_set` has **no server counterpart** — replace semantics means there is nothing
  to reject. Do not add it.

*Required contract:* typed error carrying **structured fields**, not just a kind string —
`{reason: "INVALID_TIP_AMOUNT", max: 40.0, subtotal: 80.0}` — plus a rewritten Swift
decoder. This is a clean argument for proto-typed errors in the gRPC design: the existing
regex-over-`String(describing:)` decoder is the exact anti-pattern to retire.

**B4 — The client's status gate is narrower than the server's.**
The RPC allows `courier_arrived_customer`; the app's chips require `== .delivered`
(`:460`). Not a break, but the "tip before the door closes" window the plan opens is
**unreachable** from the consumer app. Not mentioned in the STATE-REPORT.

**B5 — "Edit your tip" is unreachable.**
The plan says replace semantics "supports 'edit your tip' UX." The app's
`order.tipAmount == nil` gate (`:460`) hides the chips the moment a tip exists. The
capability exists server-side and is dead client-side. Not a break; flag it so nobody
counts it as shipped.

**B6 — `orders.total` double-count risk: RESOLVED, and the answer is "do not fold."**
The app renders `order.total + (order.tipAmount ?? 0)` (`:406`). Migration 20 §3 sets
`orders.tip_amount = p_amount` and **does not touch `total`**. So the current display stays
correct. *Contract requirement: `total` must continue to EXCLUDE tip.* If the Kotlin order
service ever folds tip into `total`, `OrderDetailView.swift:406` double-counts and shows the
tip twice with no other symptom. Pin this in the proto comment.

**B7 — Sequencing is a hard constraint, not a preference.**
Because of B3 + the `:45` gating bug, the day a *rejecting* `add_tip` ships the user sees
absolutely nothing. The client fix (bind `error` to an alert, or route through
`ServiceError.from` like the cancel flow at `:598-613`) must land **before** any rejection
path. A clamping RPC removes this ordering constraint entirely — another argument for clamp
over reject.

---

## 3. Currency and rounding — exact

**Verified 100%. Zero stragglers.** `grep -rn 'сомони'` returns exactly 3 hits;
`grep -rn '₽\|сум\b\|руб'` returns exactly 1 hit and it is the Russian word for "amount"
(`DuDash/Views/Cart/ConfirmOrderView.swift:139` — `"Минимальная сумма не достигнута"`), not
a currency.

The single formatter, `DuDash/ViewModels/CheckoutViewModel.swift:100-105` — a **free global
function** parked at file scope below the class:

```swift
func formatPrice(_ price: Double) -> String {
    if price.truncatingRemainder(dividingBy: 1) == 0 {
        return "\(Int(price)) сомони"
    }
    return String(format: "%.2f сомони", price)
}
```

Behaviour to port verbatim:
- **Conditional precision.** Whole → integer, no decimal point. Fractional → exactly 2 dp.
- Unit always **suffixed**, space-separated, lowercase, always the full word `сомони` —
  never abbreviated, never a symbol, never prefixed.
- Storage/compute type is `Double` throughout (`Restaurant.deliveryFee`,
  `CartItem.totalPrice`, `Order.total`, `Order.tipAmount` — all `Double`). Rounding happens
  **only at display**.
- Edge case the report does not mention: the "is it whole" test runs on the **unrounded**
  double, but the fractional branch rounds. So `12.999` renders `"13.00 сомони"` — not
  `"13"`, not `"13.00"`-after-a-whole-test. Any Kotlin/`BigDecimal` reimplementation that
  rounds first and *then* tests for wholeness will render `"13 сомони"` and diverge.

Counts: 30 textual occurrences of `formatPrice`, of which 1 is the definition → **27
call-site lines**. (Report says "30 call sites" — it counted occurrences, not sites. Minor.)

Third `сомони` literal: `DuDash/Views/Home/PromoBannerCarousel.swift:8`, a hardcoded fake
promo string, not routed through the formatter.

### Known divergences inside the consumer app (decide fleet-wide)

1. **Tip chips bypass the formatter.** `DuDash/Views/Orders/OrderDetailView.swift:470` —
   `Text("+\(Int(amount))")`. Bare integer, no unit. App's own bug; owner acknowledges it.
2. **Zero delivery fee renders three different ways.** Report says two; it is worse:
   - `DuDash/Views/Restaurant/RestaurantRowView.swift:111` — ternary →
     `"Бесплатно"` when fee == 0.
   - `DuDash/Views/Home/FeaturedSection.swift:54-55` — badge `"Бесплатная доставка"` when
     fee == 0, **and** `:116` renders `"Доставка \(formatPrice(restaurant.deliveryFee))"`
     **ungated**. So a free-delivery card on Home shows the badge *and* the words
     "Доставка 0 сомони" simultaneously.
   - `DuDash/Views/Restaurant/RestaurantDetailView.swift:112` (`InfoPill`) and
     `DuDash/Views/Cart/CartView.swift:224` (breakdown) — plain `"0 сомони"`.
   *Required:* one `formatPrice(_:freeLabel:)` in core, plus a decision on whether zero
   renders as a word or a number.
3. **RavonCore itself still renders `₽`.** `Sources/RavonCore/Services/SupabaseService.swift:60`:
   `case .minOrderNotMet(let need): return "Минимальная сумма заказа: \(Int(need)) ₽"`.
   Two defects in one line — wrong currency, and `Int(need)` **truncates** (so 99.9 → "99").
   Currently *latent* in the consumer app: `minOrderNotMet` is reached via
   `validation.reason` → the app's own `.minOrderUnmet` copy
   (`DuDash/ViewModels/ConfirmOrderViewModel.swift:99-101`), and
   `ServiceError.from(serverError:)` has no `MIN_ORDER_NOT_MET` case, so the `₽` string is
   unreachable from this app today. It *is* reachable via
   `cancelError = typed.localizedDescription` (`OrderDetailView.swift:604`) for other cases.
   **Three rounding behaviours across the fleet is confirmed at least twice inside these two
   files alone:** `Int()` truncation at `SupabaseService.swift:60`, `%.2f` rounding at
   `CheckoutViewModel.swift:104`, and `Int()` truncation again at `OrderDetailView.swift:470`.

**Recommendation to the plan:** port the conditional formatter verbatim into RavonCore as the
single fleet formatter, and make the Kotlin/proto money representation minor-unit integers
(dirams) with the formatting decision left entirely on the client. That kills the three
rounding behaviours by construction rather than by convention.

---

## 4. Credentials — three live places (four copies of the URL), all verified

Phase 0 must consolidate these. A key rotation today needs edits in **5 locations across
2 file types, 4 of which are inert.**

| # | location | content | read by anything? |
|---|---|---|---|
| 1 | `DuDash/Config/AppConfig.swift:4` | `supabaseURL = URL(string: "https://<dead-ravon-project-ref>.supabase.co")!` | **YES** — the only live one |
| 1 | `DuDash/Config/AppConfig.swift:7` | `supabaseAnonKey = "eyJhbGciOiJIUzI1NiIs..."` (full JWT inline) | **YES** |
| 2 | `DuDash/Services/APIClient.swift:24` | `init(baseURL: URL = URL(string: "https://<dead-ravon-project-ref>.supabase.co")!` — 4th copy of the URL as a default parameter | **NO** — dead file |
| 3 | `DuDash.xcodeproj/project.pbxproj:272` | `INFOPLIST_KEY_API_BASE_URL = "http://localhost:8000"` (Debug) | **NO** |
| 3 | `DuDash.xcodeproj/project.pbxproj:273` | `INFOPLIST_KEY_SUPABASE_ANON_KEY = <full JWT>` (Debug) | **NO** |
| 3 | `DuDash.xcodeproj/project.pbxproj:274` | `INFOPLIST_KEY_SUPABASE_URL = "https://<dead-ravon-project-ref>.supabase.co"` (Debug) | **NO** |
| 3 | `DuDash.xcodeproj/project.pbxproj:307` | `INFOPLIST_KEY_API_BASE_URL = "http://localhost:8000"` (**Release**) | **NO** |
| 3 | `DuDash.xcodeproj/project.pbxproj:308` | `INFOPLIST_KEY_SUPABASE_ANON_KEY = <full JWT>` (**Release**) | **NO** |
| 3 | `DuDash.xcodeproj/project.pbxproj:309` | `INFOPLIST_KEY_SUPABASE_URL = ...` (**Release**) | **NO** |

Verified inert: `grep -rn 'Bundle.main\|forInfoDictionaryKey' --include='*.swift'` over the
whole consumer repo returns **0 hits**. Nothing in Swift ever reads an Info.plist key.

Verified dead: `grep -rn 'APIClient'` returns 3 hits, all inside `APIClient.swift` itself
(`:2` comment, `:19` declaration, `:20` `static let shared`). 86 lines, 0 external
references.

Notes for Phase 0:
- **`INFOPLIST_KEY_API_BASE_URL = "http://localhost:8000"` ships in Release.** It points at
  the orphaned `backend/` FastAPI subsystem (`CLAUDE.md` documents `backend/` as
  "FastAPI backend (Fly.io)"; grep confirms the app never calls it). This is the single
  clearest precedent for "the plan must specify how the Kotlin service endpoint is
  configured per-build" — the last time someone added a second transport to this app, the
  Release build shipped pointing at localhost.
- **The anon key's own JWT header is `{"alg":"HS256","typ":"JWT"}`.** Do **not** infer the
  *user-token* signing algorithm from it. The orchestrator verified live that Supabase
  projects now serve **ES256 (P-256 EC)** JWKS for user access tokens. The legacy static
  `anon` API key being an HS256 JWT is a separate, older mechanism. The interceptor design
  must verify the user access token against JWKS/ES256, and must not accept the `anon` key
  as an identity at all.
- `CLAUDE.md` documents only location #1 (`Config/AppConfig.swift  # Supabase URL & anon
  key`). The docs are a fourth source of the "there is one place" misconception.

---

## 5. RavonCore workarounds — what a gRPC service resolves, and what it does not

The report's §3 lists 11, ranked. Re-classified against the actual extraction phases.

### Resolved by moving to a Kotlin/gRPC service

| # | workaround | evidence | which phase |
|---|---|---|---|
| 1 | **Modifiers cannot be persisted.** `createOrder` takes `[(menuItemId, quantity)]`; `OrderItemParam` is `{menu_item_id, quantity}`. User is charged for modifiers and they are discarded. | `Sources/RavonCore/Services/SupabaseService.swift:331-339`, `:346`; `DuDash/ViewModels/ConfirmOrderViewModel.swift:50`; `DuDash/Models/CartItem.swift:17-23` | Phase 3 — needs `repeated modifier_option_id` on the order-item message in **both** `PlaceOrder` and `ValidateCart` |
| 2 | **`delivery_mode` cannot be set at creation** → the one direct `orders` write | `DuDash/ViewModels/ConfirmOrderViewModel.swift:121`; `Sources/RavonCore/Services/SupabaseService.swift:314-329` | Phase 3 — **plus the trigger rewrite in §1 above** |
| 7 | **Orderability is per-restaurant only**, so the list screen reimplements the whole open/closed derivation client-side. Comment at `:35` literally reads `"UI hint only — server is the truth."` Two implementations that can disagree. | `DuDash/ViewModels/RestaurantListViewModel.swift:34-67`; core's `getRestaurantOrderability(restaurantId:)` called at `DuDash/ViewModels/RestaurantDetailViewModel.swift:100` | Phase 3 (or a batch read) — a single `GetOrderability(repeated restaurant_id)` collapses both the N+1 and the duplicate logic |
| 6 | **No batch/embedded restaurant hours → N+1.** `fetchRestaurantHours` is per-restaurant, fanned out in a task group; 3 screens each own a `RestaurantListViewModel` and each call `load()` on `.task`. | `DuDash/ViewModels/RestaurantListViewModel.swift:103` (inside the group), 4 call sites total: `RestaurantListViewModel.swift:103`, `RestaurantDetailViewModel.swift:83`, `CartView.swift:320`, `ConfirmOrderView.swift:64` | any phase — trivially a batched RPC |
| — | **`ServiceError.from` cannot carry payload values** (see §2 B3) | `Sources/RavonCore/Services/SupabaseService.swift:90-127` | all phases — proto-typed errors with fields |

### NOT resolved by a gRPC service — these are client-side or RavonCore-shape problems

| # | workaround | evidence | why gRPC doesn't help |
|---|---|---|---|
| 3 | **No shared price formatter.** Free global function at the bottom of a view-model file; 27 call sites. | `DuDash/ViewModels/CheckoutViewModel.swift:100-105` | Presentation. Needs a RavonCore utility, not a service. A service can standardise the *money type*; it cannot standardise `"30 сомони"` vs `"30.00 сомони"`. |
| 4 | **No `updateAddress`, no `setDefaultAddress`.** Core has only fetch/create/delete. So there is no address editing and `isDefault` is settable only at creation — picking the wrong default means delete-and-recreate. | `Sources/RavonCore/Services/SupabaseService.swift:257-271`; `DuDash/Views/Profile/AddressListView.swift:130` | Addresses stay on Supabase/PostgREST per PROMPT §3. This is missing CRUD, not a missing service. Does need a plan decision: if `addresses` stays client-written, RLS must stay primary for it (see §1). |
| 5 | **`AddressInsert` takes coords but nothing produces them.** `latitude`/`longitude` are `Double?` params; no consumer code ever passes them. | `Sources/RavonCore/Models/Address.swift:70-71, 78`; `grep latitude/longitude` in consumer → 14 hits, **all** in `CourierTrackingMapView.swift`, zero in `AddAddressView`/`AddressStep` | Needs a shared map picker / CoreLocation / geocoder in core's UI layer. Pure client work. **But it silently degrades Phase 1:** dispatch cost models consume coordinates, and every consumer address in this system has none. |
| 8 | **Realtime unsubscribes are global.** See §6 — a two-transport design makes this worse, not better. | `Sources/RavonCore/Services/RealtimeService.swift:86-97, 485-536` | Supabase Realtime stays per PROMPT §3, so this bug survives the whole extraction untouched. |
| 9 | **`Calendar.current` / `DateFormatter` leak.** `RestaurantHours.swift:57` pins `Asia/Dushanbe` correctly in core, but views build their own. Report says "6 places"; **actual count is 11 sites across 9 files** — `RestaurantDetailViewModel.swift:147`, `RestaurantListViewModel.swift:157`, `RestaurantDetailView.swift:48`, `SchedulePickerSheet.swift:171,178`, `ConfirmOrderView.swift:263,267`, `CartView.swift:394,398`, `OrdersView.swift:138`, `OrderDetailView.swift:646`. | grep `Asia/Dushanbe` | Needs `RavonCore.dushanbeCalendar` + shared formatters. Client-side. The plan should still care: any gRPC timestamp must be UTC-instant-typed, because there are 11 independent places that could reinterpret it. |
| 10 | **`OnboardingProgress` exists in core and is ignored**; `OnboardingService` uses `UserDefaults`, so onboarding is device-local and repeats on reinstall. | report-only, not re-verified | App's own choice. |
| 11 | **Cyrillic pluralisation hand-rolled 3×.** Verified one: `unreadWord` at `DuDash/Views/Orders/OrderDetailView.swift:650-656`. | `:650-656` | Needs `RavonCore.pluralize`. Client-side. |

### One more, not in the report: `removeCartItem(id:)` is dead

`DuDash/Services/CartService.swift:62-71` defines the correct id-keyed mutation.
`grep -rn 'removeCartItem'` returns **1 hit — the definition only**. Meanwhile
`DuDash/Views/Cart/CartView.swift:362` calls `cart.removeItem(item.menuItem)` (decrements
the *first* line with that menu item, not the tapped row) and `:372` calls
`cart.addItem(item.menuItem, restaurant: cart.restaurant!)` with **no modifiers**, spawning
a separate modifier-less line. Verified against `CartService.addItem` `:31-48`, which keys
no-modifier items by `menuItem.id` (`CartItem(id: menuItem.id, ...)`, `:36`) but
modifier-bearing items by a fresh `UUID()` (`:46`). Purely client-side; blocks nothing in
the plan, but it means **the cart the user sees is not a faithful input to any order
service**, which will muddy any Phase-3 end-to-end verification.

---

## 6. Realtime lifecycle — a two-transport architecture makes this strictly worse

PROMPT §3 keeps "Realtime websockets: order status, chat" on Supabase while order *writes*
move to Kotlin. That splits one causal chain across two transports. The existing
subscription machinery cannot absorb that.

### Verified structural facts (RavonCore `Sources/RavonCore/Services/RealtimeService.swift`)

- **One channel slot per kind, six slots total** (`:86-97`): `orderChannel`, `menuChannel`,
  `courierLocationChannel`, `chatChannel`, `availableOrdersChannel`,
  `restaurantStatusChannel`.
- **Three different order subscriptions share one slot.** `subscribeToOrder` (`:111`, sets
  `orderChannel` at `:121`), `subscribeToRestaurantOrders` (`:147`, `:157`) and
  `subscribeToCourierOrders` (`:202`, `:212`) all write `orderChannel`. Each begins with
  `await unsubscribeFromOrders()` (`:112`), so subscribing to one **tears down** whichever
  was live.
- **Unsubscribes are global, not per-subscriber** (`:485-528`). No tokens, no reference
  counting. Any screen can kill any other screen's subscription.

### The two live consumer-side failures — both verified

**F1 — Cart stock/availability warnings stop permanently after visiting a restaurant page.**
`DuDash/Views/Restaurant/RestaurantDetailView.swift:354-356` — `onDisappear` fires
`unsubscribeFromMenu()`. `DuDash/ViewModels/CheckoutViewModel.swift:47-52` subscribes to the
*same* menu channel for cart warnings, guarded by:

```swift
guard let restaurant = cart.restaurant, subscribedRestaurantId != restaurant.id else { return }
subscribedRestaurantId = restaurant.id
```

Once `subscribedRestaurantId` is set, the guard returns early forever. So after the menu
channel is torn down by a sibling screen, the checkout screen **never re-subscribes** and
its `applyMenuEvent` path goes permanently silent. No error, no UI change.

**F2 — Chat/order teardown races chat setup.**
`DuDash/Views/Orders/OrderDetailView.swift:556-561` — `onDisappear` launches an unawaited
`Task` doing `unsubscribeFromOrders()` + `unsubscribeFromChat()`. Pushing into
`ChatView` triggers `ChatViewModel.swift:56` `subscribeToChat(orderId:)` (which itself
begins by tearing down the chat channel). Ordering between the two detached `Task`s is not
guaranteed. `ChatView.swift:116` `onDisappear { vm.unsubscribe() }` →
`ChatViewModel.swift:81` global `unsubscribeFromChat()`, which also kills the parent
screen's chat subscription when you pop back. Report flags this as unverified-on-device;
the code shape is confirmed.

### Two defects the STATE-REPORT does not mention — found while verifying

**F3 — `unsubscribeAll()` omits restaurant-status.**
`Sources/RavonCore/Services/RealtimeService.swift:530-536`:

```swift
public func unsubscribeAll() async {
    await unsubscribeFromOrders()
    await unsubscribeFromMenu()
    await unsubscribeFromCourierLocation()
    await unsubscribeFromAvailableOrders()
    await unsubscribeFromChat()
}
```

`unsubscribeFromRestaurantStatus()` (defined at `:287`) is **not** in the list — 5 of 6
kinds covered. Fleet-wide grep: the only caller of `unsubscribeFromRestaurantStatus` outside
core is `ravon-merchant/.../ViewModels/DashboardViewModel.swift:33`. The consumer app
subscribes to it twice (`RestaurantDetailViewModel.swift:89`, `CheckoutViewModel.swift:52`)
and **never** unsubscribes. That websocket channel leaks for the app's lifetime.

**F4 — `unsubscribeAll()` is never called, anywhere in the fleet.**
Grep across all four repos: 1 hit, the definition. The consumer app calls `auth.signOut()`
in three places (`ContentView.swift:69`, `ProfileView.swift:188`,
`SetupWizardView.swift:72`) and **none of them tears down realtime**. So subscriptions
authenticated as user A survive into user B's session.

**F5 — Inconsistent teardown semantics.**
`unsubscribeFromRestaurantStatus` uses `await channel.unsubscribe()` (`:291`); every other
unsubscribe uses `await client.removeChannel(channel)` (`:489, 498, 507, 516, 525`). The
former leaves the channel registered in the client's channel map; the latter removes it. Two
different lifecycle contracts in one file.

### Why two transports makes all of this worse

1. **Ordering across transports is unspecified.** Today `OrderDetailView.swift:565-568`
   reacts to a realtime `orders` UPDATE by calling `loadOrder()` — a full PostgREST refetch.
   Both the notification and the refetch go through the same database, so the refetch is
   always at-or-after the event. Under two transports the gRPC write-ack and the Supabase
   Realtime notification arrive on **independent paths with independent latency**. The
   client can ack "delivered" over gRPC and then re-render stale state, or receive the
   realtime event and refetch through PostgREST before the Kotlin service's transaction is
   visible to the replica the read hits. The plan needs an explicit rule — e.g. every gRPC
   mutation response carries the full post-state and monotonic version, and realtime is
   treated as a pure "refetch now" hint that is never trusted for content.
2. **Two reconnect/backoff/auth-refresh state machines.** One JWT, two transports, two
   independent expiry reactions. The 20-minute JWKS revocation lag the orchestrator measured
   (10 min Supabase edge + up to 10 min client cache) applies to the gRPC interceptor but
   **not** to the Supabase Realtime path, so a revoked session can keep one transport alive
   and not the other, in either direction.
3. **F4 becomes a security problem, not a leak.** Today there is no realtime teardown on
   sign-out. Add a second authenticated transport and "sign out" has two things to close,
   neither of which anything currently closes.
4. **F1/F2 get a second way to fire.** The single-slot-per-kind design already means any
   screen can kill another's subscription. A gRPC streaming RPC (if `Assign` or order
   updates ever stream) adds a *third* lifecycle with no shared teardown discipline.

**Concrete ask for the plan:** Phase 0 should replace `RealtimeService`'s six mutable slots
with token/reference-counted subscriptions keyed by `(kind, id)` and add
`unsubscribeAll()`-on-sign-out **before** any second transport exists. Doing it after means
debugging two interleaved lifecycles instead of one. This is an addition to Phase 0's
"restructure only, zero new behaviour" scope, and it is worth arguing for explicitly rather
than smuggling in.

---

## 7. Contradictions with the other briefs

### 7.1 `ServiceError.from(serverError:)` — the orchestrator's "established fact" is WRONG

Established fact as given to me:
> `ServiceError.from(serverError:)` at `Sources/RavonCore/Services/SupabaseService.swift:90`
> has THREE call sites, all in `Tests/RavonCoreTests/CourierCancellationTests.swift:55,65,74`.
> It has **ZERO production call sites**.

`PROMPT-kotlin-backend.md` §9 states it more strongly:
> `ServiceError.from(serverError:)` ... **has zero call sites** — so every structured
> `P0001`/`DETAIL` payload the SQL functions raise is currently discarded.

**Both are wrong.** Fleet-wide grep for `ServiceError.from` in `*.swift` finds **7
production call sites**:

| repo | file:line |
|---|---|
| consumer | `DuDash/Views/Orders/OrderDetailView.swift:598` |
| courier | `RavonCourier/RavonCourier/Views/Delivery/OrderOfferView.swift:156` |
| courier | `RavonCourier/RavonCourier/Views/Delivery/ActiveDeliveryView.swift:737` |
| courier | `RavonCourier/RavonCourier/Views/Delivery/ActiveDeliveryView.swift:745` |
| courier | `RavonCourier/RavonCourier/Views/Delivery/ActiveDeliveryView.swift:779` |
| courier | `RavonCourier/RavonCourier/Views/Delivery/ActiveDeliveryView.swift:810` |
| courier | `RavonCourier/RavonCourier/Views/Orders/OrderRowView.swift:203` |
| merchant | none |

The consumer site is the pre-pickup cancel flow, `OrderDetailView.swift:596-613` — it
decodes the typed reason and routes `CANCEL_AFTER_PICKUP_NOT_ALLOWED` /
`CANNOT_CANCEL_POST_PICKUP` to a dedicated alert and everything else to `cancelError`.

The **true** precise defect is narrower and more useful: the decoder is *opt-in per call
site* rather than wired into `SupabaseService`'s throw path, so coverage is patchy. The
cancel flow uses it; the tip flow (`OrderDetailView.swift:617-626`) does not. Merchant uses
it nowhere. And when it *is* used, it discards every payload field except `reason`
(`:107-124`). The plan's §9 requirement ("every RPC must return a typed error, do not
reproduce this bug") is still right — but the justification must be rewritten, because a
reviewer who checks will find the claim false and discount the rest.

### 7.2 Migration-20 plan's tip reason codes contradict the consumer STATE-REPORT's ask

- Plan (`.context/plans/migration-20-...closes.md` §3, §5): `INVALID_TIP_AMOUNT`,
  `TIP_WINDOW_CLOSED`.
- STATE-REPORT §6: `tip_exceeds_cap`, `tip_window_expired`, `tip_already_set`.
- Decoder reality (`Sources/RavonCore/Services/SupabaseService.swift:98`): regex is
  `"reason"\s*:\s*"([A-Z_]+)"` — **lowercase codes do not match**, and `tip_already_set` has
  no server counterpart under replace semantics.

Three documents, three vocabularies, one of which cannot be parsed. The plan must pin a
single normative list. See §2 B3.

### 7.3 Plan says "reject"; consumer asks for "clamp"; nobody has reconciled it

Migration 20 §3 rejects out-of-bound amounts. The consumer owner explicitly prefers clamping
("I mildly prefer (b) clamp ... so a race can't produce a hard error"). The plan's
verification step 5 hard-codes rejection expectations. This is an unresolved product
decision sitting in the middle of a "verified" plan. It also interacts with the invisible-
error bug (§2 B7): reject + `:45` gating = user sees nothing.

### 7.4 Migration 20's own `add_tip` verification step is unreachable through Swift

Plan verification step 5 expects `p_amount = -1 → INVALID_TIP_AMOUNT`. `SupabaseService.swift:661`
`guard amount >= 0 else { return }` short-circuits before the RPC is called. The test can
only be exercised by raw HTTP, not through the client. Worth noting because the plan treats
its verification list as sufficient.

### 7.5 STATE-REPORT contradicts the consumer repo's own `CLAUDE.md` on iOS version

`CLAUDE.md` says "iOS 17+". `DuDash.xcodeproj/project.pbxproj:194` and `:252` both say
`IPHONEOS_DEPLOYMENT_TARGET = 26.2`. STATE-REPORT is right and `CLAUDE.md` is wrong. This
agrees with the orchestrator (all three apps at 26.2) and with `PROMPT-kotlin-backend.md`
§7's flag. RavonCore's `Package.swift` declaring `.iOS(.v17)` is consistent with
`CLAUDE.md` and inconsistent with every consumer. **Relevance:** the gRPC-Swift-2 vs
Connect-Swift decision in PROMPT §7 turns partly on minimum iOS version; at 26.2 the
minimum-version argument against gRPC Swift 2 disappears entirely, so the decision must rest
on the `protoc`/SwiftPM-plugin build-pipeline argument alone.

### 7.6 The RavonCore pin is a *branch requirement*, not a revision pin

`PROMPT-kotlin-backend.md` §10 says "All three apps pin RavonCore to commit `a1e9d6c8`."
Precisely: `DuDash.xcodeproj/project.pbxproj:364-371` declares
`requirement = { kind = branch; branch = "mmarufov/auth-overhaul"; }` — **branch tracking**.
The commit appears only in
`DuDash.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
(`"branch": "mmarufov/auth-overhaul", "revision": "a1e9d6c814436c82dd93388158768e6720c2b18e"`).
Practical difference: `File > Packages > Update to Latest` moves the app to the branch tip,
not to the recorded commit. So the fleet is *simultaneously* exposed to (a) branch deletion
breaking resolution and (b) a branch push silently moving all three apps. Fixing this in
Phase 0 means adding a tag **and** changing `kind = branch` → `kind = exactVersion`/`upToNextMajor`
in the pbxproj, not just cutting a tag.

Confirms the orchestrator on supabase-swift: consumer resolves **2.41.1** (revision
`0f8bf83b...`), plus `swift-crypto 4.2.0`, `swift-asn1 1.5.1`, `swift-http-types 1.5.1`,
`xctest-dynamic-overlay 1.9.0`, `swift-clocks 1.0.6`, `swift-concurrency-extras 1.3.2` —
matching the STATE-REPORT's list exactly.

### 7.7 Agrees with the orchestrator (no contradiction) — recorded for completeness

- Consumer has exactly **2** `import Supabase` files. ✅
- Currency: consumer is clean `сомони`; the `₽` lives in RavonCore
  (`SupabaseService.swift:60`, and per the orchestrator also `CartValidation.swift:79`). ✅
- `<dead-ravon-project-ref>` is the dead project ref, and it is hardcoded in 4 places in this
  repo. ✅

---

## 8. Claims in the STATE-REPORT I found to be imprecise (none materially wrong)

Ranked by how likely they are to mislead the plan.

1. **"It is `try?`. After migration 20 this fails and is swallowed silently"** (§5) —
   understates it. RLS with no UPDATE policy yields a **0-row success**, not an error.
   Removing the `try?` would not surface it. *Should be verified on a Supabase branch before
   the plan relies on either reading.*
2. **"Add `p_delivery_mode` to `create_order` and the §5 hit disappears"** (§3 item 2) —
   incomplete. The migration-10 `BEFORE INSERT` trigger unconditionally overwrites it, and
   the column's `NOT NULL DEFAULT 'hand_to_me'` leaves no sentinel. See §1.
3. **"return typed reasons ... through the same `ServiceError.from(serverError:)` DETAIL-JSON
   channel the cancel flow uses"** (§6.3) — the channel exists but **cannot carry the cap
   value**; the decoder extracts only `reason` and fabricates placeholder payloads
   (`SupabaseService.swift:112, 114, 117, 118`). Also: the requested lowercase code names
   fail the `[A-Z_]+` regex.
4. **"I pinned `Asia/Dushanbe` by hand in 6 places"** (§3 item 9) — actual count is **11
   sites across 9 files**. The parenthetical file list in the report has 9 entries, so the
   "6" looks like a stale number.
5. **"30 call sites" for `formatPrice`** (§4) — 30 textual *occurrences*, 27 call-site lines
   (1 is the definition).
6. **"I render a zero delivery fee as `Бесплатно` in `RestaurantCardView:111` and
   `FeaturedSection`"** (§4) — `FeaturedSection` renders a *badge* `"Бесплатная доставка"`
   (`:54-55`) and, ungated, also `"Доставка 0 сомони"` (`:116`). So it is three renderings,
   not two, and one card shows two of them at once. Sharper than the report, same direction.
7. **Citation style hazard:** the report cites *type* names where the *file* name differs.
   `RestaurantCardView` is `struct RestaurantCardView` inside
   `DuDash/Views/Restaurant/RestaurantRowView.swift:6` — there is no
   `RestaurantCardView.swift`. Same for `OrderItemSnapshotRow:~845` and `unreadWord:~655`
   (the latter is really `OrderDetailView.swift:650`). Not errors, but a `file:line`
   consumer will bounce.
8. **`createOrder` signature** (§2 P0 table) — quoted as
   `OrderItemParam(menu_item_id:, quantity:)`, correct, but the report's §3 item 2 omits
   that `createOrder` already has `scheduledFor:`
   (`Sources/RavonCore/Services/SupabaseService.swift:348`). Only matters when writing the
   proto: the existing RPC has 5 params, not 4.

### Claims I verified as exactly right (spot-checks, so the plan can trust the rest)

`ConfirmOrderViewModel.swift:120-125` verbatim ✅ · only one `orders` write, 3 total `.from(`
hits ✅ · `formatPrice` body verbatim at `CheckoutViewModel.swift:100-105` ✅ · 3 `сомони`
hits, 0 `₽`, the one `сум` is "сумма" ✅ · tip chips `[5,10,20,50]` at `:466`, bare `Int` at
`:470`, gate at `:460` ✅ · `addTip` at `:617-626` setting unrendered `error` at `:623` ✅ ·
error render site gated on `order == nil` at `:45` ✅ · alerts bound only to `cancelError` /
`showPostPickupCancelAlert` / `supportInfoMessage` (`:514, :522, :534`) ✅ ·
`order.total + (order.tipAmount ?? 0)` at `:406` ✅ · credentials in exactly those 9
locations, zero `Bundle.main` reads ✅ · `APIClient.swift` 86 lines, 0 external refs, URL
default at `:24` ✅ · `IPHONEOS_DEPLOYMENT_TARGET = 26.2` at `:194` and `:252` ✅ ·
`CheckoutViewModel` guard-blocked re-subscribe at `:48` ✅ ·
`RestaurantDetailView.onDisappear → unsubscribeFromMenu()` at `:354-356` ✅ ·
`OrderDetailView.onDisappear` double fire-and-forget unsubscribe at `:556-561` ✅ ·
`CartView:362` / `:372` stepper bug ✅ · `removeCartItem(id:)` dead ✅ ·
`RestaurantListViewModel.availability(for:)` at `:36-67` with the "UI hint only" comment at
`:35` ✅ · `CheckoutViewModel.loadAddresses` `catch { // non-blocking }` at `:42-44` ✅ ·
no consumer code passes `latitude`/`longitude` to `AddressInsert` ✅ ·
`AddressInsert` does expose them (`Sources/RavonCore/Models/Address.swift:70-71`) ✅ ·
supabase-swift 2.41.1 in `Package.resolved` ✅

### Not verified (report-only, or needs a live system)

- Build succeeds / 3 warnings / 2 real ones at `ConfirmOrderViewModel.swift:121` — did not
  run `xcodebuild`. The `try?` at `:121` is consistent with "result of `try?` is unused".
- Simulator observations (onboarding tour, `RavonAuthFlow` render, `promo_banner` English
  text) — report-only.
- F2 chat/order teardown race — code shape confirmed, behaviour needs a live order.
- The 4 phantom `FoodCategory.browse` keys vs real `cuisine_type` values — **UNKNOWN, needs
  live introspection.** Permanently unknowable now: the project is gone. Treat the enum as
  the only surviving record when reconstructing the schema.
- Whether `orders` had a baseline INSERT/DELETE policy in addition to the two UPDATE
  policies — **UNKNOWN, needs live introspection**, and the migration-20 plan's own §6.1
  says to enumerate `pg_policy` first. That enumeration can no longer be done. The plan must
  therefore treat "no client write policies on `orders`" as a **greenfield construction
  requirement**, not a migration, which is exactly PROMPT §10's framing and is the right
  call.

---

## 9. Net constraints on the Kotlin plan, condensed

1. **Phase 3 must land `delivery_mode` and `modifier_option_ids` together with the removal
   of the `orders` client write policy** — and must also own the address-default resolution
   currently in the migration-10 trigger. Shipping the policy removal first produces a
   silent, unloggable correctness bug in the primary conversion flow.
2. **`orders.total` must never include tip.** Pin it in the proto comment.
   `OrderDetailView.swift:406` adds them client-side.
3. **`add_tip` should clamp, not reject** — or the client-side cap logic and the error-render
   fix must both land first. Pin one SCREAMING_SNAKE reason-code vocabulary and carry the
   cap/subtotal as **structured fields**, which the current Swift decoder cannot do.
4. **Money crosses the wire as minor units.** Formatting stays on the client, ported verbatim
   from `CheckoutViewModel.swift:100-105` (conditional integer-or-2dp, suffixed `сомони`,
   wholeness tested on the *unrounded* value). Fix `SupabaseService.swift:60`'s `₽` +
   `Int()` truncation in Phase 0.
5. **Phase 0 credential consolidation is 9 edits in 3 files**, and must also decide how the
   Kotlin endpoint is configured per-build — the precedent
   (`INFOPLIST_KEY_API_BASE_URL = http://localhost:8000` shipping in Release) is right there.
6. **`addresses` and `chat_messages` stay client-written and RLS-primary.** Two of their
   RavonCore queries have no ownership predicate at all
   (`SupabaseService.swift:267`, `:1084`). "RLS becomes defence-in-depth" must be scoped to
   `orders`, explicitly, or those become open endpoints.
7. **Refactor `RealtimeService` to ref-counted subscriptions and tear down on sign-out in
   Phase 0**, before a second transport exists. Also fix `unsubscribeAll()`'s missing
   restaurant-status case (`RealtimeService.swift:530-536`) and the
   `channel.unsubscribe()` vs `client.removeChannel()` inconsistency.
8. **Rewrite PROMPT §9's `ServiceError.from` justification.** It has 7 production call
   sites. The real defect is per-call-site opt-in + payload discard.
9. **Phase 0's pin fix is two changes, not one:** cut a tag *and* change
   `kind = branch` → a version requirement in all three pbxproj files.
10. **Every consumer address has NULL coordinates.** Phase 1's dispatch cost model must
    either degrade explicitly or the plan must include the shared map picker
    (RavonCore workaround #5) as a Phase-1 prerequisite. Right now
    `CourierTrackingMapView.swift:15-17` already gates the destination marker on non-nil
    coords, so the failure mode is "silently absent," which is how it went unnoticed.
