# `proto/` contract, CI compatibility gate, and Connect-Swift integration

Scope: Part A — the proto layout and every shared type decision. Part B — the `buf` gate,
verified against the live buf docs (not memory). Part C — concrete SwiftPM integration for
Connect-Swift in RavonCore.

Builds on, and corrects, the nine prior research docs. Every claim below is either cited to
`file:line` in this repo / the three app repos, or to a live doc fetched 2026-09-16 with the
URL given.

Tool versions verified live from the GitHub releases API on 2026-09-16:

| tool | latest | source |
|---|---|---|
| `buf` CLI | **v1.73.0** | `api.github.com/repos/bufbuild/buf/releases/latest` |
| `bufbuild/buf-action` | **v1.5.0** | `api.github.com/repos/bufbuild/buf-action/releases/latest` |
| `connectrpc/connect-swift` | **1.2.3** | `api.github.com/repos/connectrpc/connect-swift/releases/latest` |
| `connectrpc/connect-kotlin` | **v0.9.0** | `api.github.com/repos/connectrpc/connect-kotlin/releases/latest` |
| `apple/swift-protobuf` | **1.38.1** | `api.github.com/repos/apple/swift-protobuf/releases/latest` |

---

## 0. Corrections to the brief and to the prior docs — READ FIRST

### 0.1 LOUD: "one is a hand-maintained pbxproj" is wrong — **none** of the three is

The task brief justifies checked-in generated code partly with "one is a hand-maintained
pbxproj." Verified false. All three app projects are **Xcode `objectVersion = 77` with
`PBXFileSystemSynchronizedRootGroup`**, i.e. filesystem-synchronised folders with no
per-file build entries:

| project | `objectVersion` | `PBXFileSystemSynchronizedRootGroup` hits | `PBXBuildFile` hits | pbxproj lines |
|---|---|---|---|---|
| `/Users/mmarufov/conductor/repos/ravon-consumer/DuDash.xcodeproj/project.pbxproj` | 77 | 3 | 3 | 371 |
| `/Users/mmarufov/conductor/repos/ravon-courier/RavonCourier/RavonCourier.xcodeproj/project.pbxproj` | 77 | 3 | 3 | 384 |
| `/Users/mmarufov/conductor/repos/ravon-merchant/RavonMerchant/RavonMerchant.xcodeproj/project.pbxproj` | 77 | 3 | 3 | 384 |

Three `PBXBuildFile` entries each — those are the framework/product links, not source files.
Adding a `.swift` file to a synchronised folder requires **zero** pbxproj edits.

The conclusion (check in the generated Swift) still holds, but for **different and stronger
reasons** — see §C.2. The *real* pbxproj constraint is the one in
`XCSwiftPackageProductDependency`: each app links exactly **one** SwiftPM product
(`RavonCore`), and adding a second requires a reviewable pbxproj edit in three repos. That is
the actual enforcement mechanism behind "the apps never import Connect" (§C.4).

### 0.2 LOUD: "All 3 apps pin RavonCore to `a1e9d6c8` on `mmarufov/auth-overhaul`" is true only of the **Conductor workspaces**, not of the repos

| location | branch | pbxproj `branch =` | `Package.resolved` ravon-core revision | `.swift` files | files with `import RavonCore` |
|---|---|---|---|---|---|
| `repos/ravon-consumer` | `main` | **no ravon-core package ref at all** | **no ravon-core pin** (only supabase-swift 2.46.0 + 6 transitive) | — | **0** |
| `workspaces/ravon-consumer/kolkata` | `mmarufov/kolkata-v1` | `mmarufov/auth-overhaul` | `a1e9d6c814436c82dd93388158768e6720c2b18e` | — | **53** |
| `repos/ravon-courier` | `main` | `main` | `f48982b059964ab701d5c72b51212370de46280b` | **2** | 1 |
| `workspaces/ravon-courier/buffalo` | `mmarufov/buffalo-v1` | `mmarufov/auth-overhaul` | `a1e9d6c8…` | 29 | 29 |
| `repos/ravon-merchant` | `main` | `main` | `f48982b0…` | **2** | 1 |
| `workspaces/ravon-merchant/milan` | `mmarufov/milan-v1` | `mmarufov/auth-overhaul` | `a1e9d6c8…` | 22 | 25 |

Three consequences that change the plan:

1. **`repos/ravon-consumer` on `main` does not depend on RavonCore at all.** It talks to
   supabase-swift directly (`XCRemoteSwiftPackageReference "supabase-swift"`,
   `DuDash.xcodeproj/project.pbxproj:352-357`, `upToNextMajorVersion` from `2.0.0`, resolved
   `2.46.0`). Its last commit on `main` is literally `424e9ad Remove broken RavonCore gitlink`.
   Any plan that says "RavonCore is the only door to the network for all three apps" is
   describing the *workspace branches*, not `main`.
2. **Courier and merchant `main` are 2-file scaffolds.** The real apps (29 and 22 Swift files)
   exist only on the unmerged Conductor branches. So the "three pinned app binaries" that a
   proto compatibility gate protects **do not exist on any merged branch yet.**
3. `f48982b0` *is* commit `f48982b` ("feat: DoorDash-style auth overhaul … (#9)"), which **is**
   an ancestor of `main`. So courier/merchant `main` track `ravon-core@main` normally. The
   dangling `a1e9d6c8` / `mmarufov/auth-overhaul` pin is a *workspace-only* artifact.

**Why this matters for this document:** the compatibility gate has, today, **zero merged
consumers**. That is the single best argument for landing `proto/` and the gate *before* the
app branches merge — the gate is free now and expensive later. It is also why v1 must be
gotten right (§A.2): once the app branches merge and ship, Ravon has **no forced-upgrade
mechanism**, so a `v2` is permanent.

### 0.3 CORRECTION to `sql-function-catalogue.md` §6.2: the `cancellation_reason_code` CHECK has **18** values, not 17

`db/migrations/09_cancellation_reason_code_and_courier_cancel_log.sql:20-36`. Counted
from the literal list: 2 consumer + 4 restaurant + 5 courier + 2 system + 4 scheduled-order +
1 no-show = **18**. `Sources/RavonCore/Models/CancellationReason.swift:8-37` also declares
**18** cases. The two are an **exact match** — there is no Swift↔SQL drift on this enum, which
is the opposite of what §6.2 implies. (§6.2's other claims about this enum — the
`cancel_order_by_courier` *runtime* whitelist of 5 disagreeing with the 18-value CHECK — are
correct and unaffected.)

### 0.4 CONFIRMED, with new precision: there is no seam to inject a client, and no test touches one

```
grep -rln "SupabaseService\|AuthService\|URLProtocol\|URLSession\|Mock" Tests/RavonCoreTests/   → 0 files
grep -rn  "protocol .*Service\|protocol .*Client"  Sources/RavonCore/                          → 0 hits
```

All 28 test files / 163 tests are pure value, `Codable`, and algorithm tests. The client is
hard-wired, not injected: `SupabaseService.swift:134` is
`private var client: SupabaseClient { AuthService.shared.supabaseClient }`, and
`RealtimeService.swift:84` is identical. `public init()` exists on both
(`SupabaseService.swift:136`, `RealtimeService.swift:106`) so a second *instance* is
constructible, but it resolves to the same global client.

So "how do the 163 tests get mocks" has a surprising answer: **they don't need any.** They
keep passing untouched. The work is creating the seam that does not exist, for the *new*
tests. See §C.3.

### 0.5 CONFIRMED: `swift-testing` count

61 `@Test` declarations across 10 files (`CartValidationTests` 11, `InsertStructTests` 5,
`MenuCategoryTemplateTests` 5, `NextOpenTimeTests` 8, `OnboardingProgressTests` 4,
`RavonCoreTests` 1, `RestaurantModelTests` 5, `RestaurantOrderabilityHintTests` 7,
`ScheduledOrderTests` 7, `SoftDeleteCodingTests` 8). Matches the established fact. The 18
XCTest files raise an independent question about parameterised counting that I did not chase.

### 0.6 CONFIRMED: `ServiceError` is 33 cases; `from(serverError:)` maps exactly 18

Counted in `Sources/RavonCore/Services/SupabaseService.swift:5-38` (21 original + 12 "Umbrella
II") and `:106-125` (18 `case` arms before `default: return nil` at `:126`). Both prior claims
stand.

### 0.7 CONFIRMED and sharpened: `RESTAURANT_CLOSED` has **three** distinct causes, not two

`db/migrations/04_create_order_v3_and_validate_cart.sql`:

- `:153-157` — `SELECT * INTO r … FOR UPDATE; IF NOT FOUND OR r.restaurant_status = 'closed' THEN RAISE … 'RESTAURANT_CLOSED'`
  → conflates **restaurant row does not exist** with **restaurant is closed**.
- `:162-165` — `IF r.restaurant_status <> 'active' THEN RAISE … 'RESTAURANT_CLOSED'`
  → a **third** cause: any non-`active`, non-`paused`, non-`closed` status label.

So the split the task asks for is a **three**-way split, not two. See §A.6.


---

## ⚠ ORCHESTRATOR CORRECTION to §0.2 — do not trust it

§0.2 above was derived from `~/conductor/repos/<app>` checkouts, which are **2–5 commits behind
`origin/main`**. Read out of the `origin/main` blobs directly (`git show origin/main:<path>` from
the Conductor workspaces), the truth is:

| app | `origin/main` pbxproj | `origin/main` Package.resolved ravon-core | supabase-swift | RavonCore-importing files on `origin/main` |
|---|---|---|---|---|
| consumer | `kind = branch; branch = "mmarufov/auth-overhaul"` | `a1e9d6c8…` | 2.41.1 | 49 |
| merchant | same | `a1e9d6c8…` | 2.43.1 | 22 |
| courier | same | `a1e9d6c8…` | 2.42.0 | 27 |

So, specifically reversing §0.2's three numbered consequences:

1. Consumer's `origin/main` **does** depend on RavonCore, via the dangling branch like the others.
   The "no ravon-core package ref at all" reading is the stale clone, whose HEAD is the older
   commit `424e9ad Remove broken RavonCore gitlink`.
2. Courier and merchant `main` are **not** 2-file scaffolds — 22 and 27 files import RavonCore.
   Each workspace branch has HEAD *equal to* `origin/main`.
3. The dangling pin is **not** a workspace-only artifact. It is on `origin/main` in three repos;
   deleting `mmarufov/auth-overhaul` breaks all three. And `f48982b0` is not what they track.

Therefore **the compatibility gate has three merged consumers, not zero**, and the argument
"the gate is free now and expensive later" does not rest on that premise. The surviving form of
the argument is stronger anyway: shipped iOS apps have **no forced-upgrade mechanism**, so a `v2`
is permanent whenever it happens — get `v1` right regardless.

Everything else in §0 (§0.1, §0.3–§0.7, and the live tool-version table) was independently
spot-checked and holds. Parts A, B and C were never written — the agent was cut off. The plan's
§4 is being filled from a re-run.
---
---

# PART A — the `proto/` contract

## A.1 Directory tree

`buf.yaml` lives at the **repo root** (which becomes the monorepo root under doc 10's layout,
so this is a no-op move later). The module root is `proto/`, so module-relative paths match
package names and `PACKAGE_DIRECTORY_MATCH` is satisfied without a `subdir=` on any command.

```
<repo root>/
├── buf.yaml                    # workspace: one module, rooted at proto/
├── buf.lock                    # written by `buf dep update`
├── buf.gen.kotlin.yaml         # server codegen — sees EVERYTHING
├── buf.gen.swift.yaml          # client codegen — excludes the admin/sim surfaces
└── proto/
    └── ravon/
        ├── common/v1/
        │   ├── money.proto            # Money, the TJS constant
        │   ├── geo.proto              # GeoPoint, CoarseGeoPoint, Zone
        │   ├── error.proto            # ErrorReason (the 37 kinds) + RavonErrorDetail
        │   ├── page.proto             # PageRequest / PageInfo  (AIP-158)
        │   ├── period.proto           # Period, PeriodSelector, the Dushanbe day rule
        │   └── identity.proto         # UserRole, ActorRef, projected identity views
        ├── order/v1/
        │   ├── order.proto            # OrderStatus, OrderActor, DeliveryMode,
        │   │                          # CancellationReason, the 4 projected order views
        │   ├── order_service.proto    # consumer + merchant + courier RPCs (PUBLIC)
        │   └── order_admin_service.proto   # system/cron RPCs (INTERNAL — no Swift codegen)
        ├── dispatch/v1/
        │   ├── dispatch.proto         # DispatchCourier/Order/Assignment/CostModel, CourierOffer
        │   ├── dispatch_service.proto # PUBLIC: offers, claim, decline, heartbeat, ETA
        │   ├── dispatch_admin_service.proto  # INTERNAL: RunDispatchRound, ladder
        │   └── dispatch_sim_service.proto    # INTERNAL: SimulateDispatch (no Swift codegen)
        └── ledger/v1/
            ├── ledger.proto           # Account, Entry, Transaction, EarningType, Payout
            └── ledger_service.proto   # PostTransaction, GetBalance, ListEntries, RecordPayout
```

### Why the admin/system surface is a separate **file and service**, not a separate method group

This is security-by-construction at the codegen layer, and it closes a verified hole.
`sql-function-catalogue.md` §3 / §7-defect-2 establishes four `SECURITY DEFINER` functions
with **no auth check** granted to `authenticated`: `reassign_ghosted_order`,
`activate_scheduled_order`, `run_courier_escalation_ladder`, `mark_no_show_deliveries`. Any
logged-in user can invoke them today.

Putting them in `order_admin_service.proto` / `dispatch_admin_service.proto` and then
*excluding those files from the Swift generation template* (§B.2) means:

- no iOS client for them is ever generated, so no app can call them even by accident;
- they are bound to a separate Armeria listener / port with a service-account-only
  interceptor, so the boundary is a deployment fact, not a code convention;
- `buf breaking` still protects them, because the Kotlin template generates everything.

The one-line summary: **a method that no client stub exists for cannot be called by a client
that only has stubs.** The current design's failure was a *grant*; the fix is a *codegen
exclusion plus a listener*, which is checkable in CI.

### Files that are deliberately absent

- No `ravon/chat/v1`. Chat stays on Supabase Realtime + `chat_messages` per the established
  facts (streaming not needed; Realtime keeps order-status + chat). Adding it later is a new
  package, which is free.
- No `ravon/auth/v1`. Auth stays Supabase (ES256 / JWKS, established). The Kotlin services
  *verify* the token; they do not issue it. The proto surface therefore has no login RPC and
  no token type — only an `Authorization: Bearer` metadata contract (§C.4).
- No `ravon/catalog/v1` **yet**. Restaurants/menus are read-mostly, Realtime-backed, and not
  on the critical path for dispatch/ledger/order. Deferring it is the correct scope cut; note
  it as the obvious `v1alpha1` candidate.

## A.2 Package naming, and the exact rule for when `v1` becomes `v2`

**Naming.** `ravon.<domain>.<version>`, one directory per package, package always ends in a
version component. This is forced by lint rules, not taste:

- `PACKAGE_DIRECTORY_MATCH` — "A file's directory path must match its package name."
- `PACKAGE_VERSION_SUFFIX` — "The last component of a package must be a version of the form
  `v\d+`, `v\d+test.*`, `v\d+(alpha|beta)\d*`, or `v\d+p\d+(alpha|beta)\d*`, where the numeric
  parts are at least 1."
  (both verbatim from <https://buf.build/docs/lint/rules/>)

So: `ravon.order.v1`, `ravon.dispatch.v1`, `ravon.ledger.v1`, `ravon.common.v1`. Pre-ship
churn goes in `ravon.<domain>.v1alpha1`, which `PACKAGE_VERSION_SUFFIX` accepts and which
`breaking.ignore_unstable_packages: true` exempts from the gate (§B.1). **Promote `v1alpha1`
to `v1` at the first TestFlight build that contains it, never later.**

**The v1→v2 rule, stated so it can be applied mechanically:**

> A new major package is created if and only if a required change would make
> `buf breaking --against <baseline>` fail **and** the failure is intended. Everything else —
> new fields, new RPCs, new enum values, new messages, deprecations — stays in `v1` forever.

Procedure when that test is met:

1. Copy the affected file(s) to `proto/ravon/<domain>/v2/`. Make the incompatible change
   there. **`v1` is not touched** — not even to add a comment, so its digest is stable.
2. The server implements **both**. `v1` handlers delegate to `v2` through a single
   `V1Adapter` file with a fixture table (`v1 request → v2 request`, `v2 response → v1
   response`) and a round-trip test over every field. One file, not scattered `if version ==`
   branches.
3. Mark every `v1` RPC `option deprecated = true;` and add
   `// DEPRECATED: use ravon.<domain>.v2.<X>. Removal no earlier than <ISO date>.`
   Note: **no `buf breaking` rule covers `deprecated`** — it is advisory only. The enforcement
   is a lint-style CI grep that every `deprecated = true` RPC carries a removal date.
4. **`v1` may be deleted only when a minimum-supported-build gate exists in the apps.** Today
   it does not. The three apps consume RavonCore as a *branch*-pinned SwiftPM dependency
   (`kind = branch`, verified in all three pbxproj files) with no force-upgrade path and no
   remote kill switch. Until a `GetClientPolicy`-style gate exists, **a `v2` doubles the
   surface permanently.** Write that in the ADR; it is the strongest argument for spending the
   extra week on `v1`.
5. Never create `ravon.order.v2` for one field. The cost is two implementations forever; the
   alternative for almost every real case is a new field plus a deprecation comment.

**Concrete list of changes that *would* justify a v2 here, so the bar is legible:**
- Splitting `Order` into per-actor views if we had shipped a single `Order` with codes in it
  (we are doing it up front instead — §A.8, `OrderView` family).
- Changing `Money` from `int64 diram` to anything else (we are choosing `int64` up front —
  §A.4).
- Renaming `OrderStatus` wire labels away from the Postgres text values. Not planned.

## A.3 Shared enums

All enums live in the package that owns the concept, are `UPPER_SNAKE_CASE`, are prefixed with
the enum name (`ENUM_VALUE_PREFIX`), and have a `0` value suffixed `_UNSPECIFIED`
(`ENUM_ZERO_VALUE_SUFFIX`). Both rules are in `STANDARD`.

### A.3.1 `OrderStatus` — 17 values, `ravon/order/v1/order.proto`

Numbers follow the declaration order in `Sources/RavonCore/Models/Order.swift:4-19`, which is
load-bearing (`allCases` order drives `visibleStatuses` iteration — `order-lifecycle-spec.md`
§1).

```proto
enum OrderStatus {
  ORDER_STATUS_UNSPECIFIED                = 0;
  ORDER_STATUS_SCHEDULED                  = 1;
  ORDER_STATUS_CREATED                    = 2;
  ORDER_STATUS_ACCEPTED                   = 3;
  ORDER_STATUS_PREPARING                  = 4;
  ORDER_STATUS_READY                      = 5;
  ORDER_STATUS_ASSIGNED                   = 6;
  ORDER_STATUS_COURIER_ARRIVED_RESTAURANT = 7;
  ORDER_STATUS_PICKED_UP                  = 8;
  ORDER_STATUS_DELIVERING                 = 9;
  ORDER_STATUS_COURIER_ARRIVED_CUSTOMER   = 10;
  ORDER_STATUS_DELIVERED                  = 11;
  // Orphaned legacy value. `OrderLifecycle.orphanedLegacyStatuses == [.cancelled]`
  // (OrderLifecycle.swift:194). No transition produces it. Retained because
  // ENUM_VALUE_NO_DELETE forbids removal; a test asserts zero transitions target it.
  ORDER_STATUS_CANCELLED                  = 12 [deprecated = true];
  ORDER_STATUS_REJECTED                   = 13;
  ORDER_STATUS_CANCELLED_BY_CUSTOMER      = 14;
  ORDER_STATUS_CANCELLED_BY_RESTAURANT    = 15;
  ORDER_STATUS_CANCELLED_BY_SYSTEM        = 16;
  ORDER_STATUS_CANCELLED_BY_COURIER       = 17;
}
```

**The Postgres-text mapping is exact and mechanical**, which is worth stating because
`order-lifecycle-spec.md` §1 warns "Do not auto-derive; transcribe the column" — that warning
applies to the *Swift* `rawValue` overrides, not to the proto. Checked all 17: the rule
`lower(strip_prefix("ORDER_STATUS_", name))` reproduces every single `rawValue` in the §1
table, including the seven explicit snake_case overrides (`courier_arrived_restaurant`,
`picked_up`, `courier_arrived_customer`, `cancelled_by_customer`, `cancelled_by_restaurant`,
`cancelled_by_system`, `cancelled_by_courier`). So one 3-line helper per language plus a
round-trip test over `OrderStatus.allCases` replaces a hand-transcribed 17-row table. Do
transcribe once, then assert the rule holds — the test is the transcription.

`stepIndex` is **not** a proto field. It is a partial order that collapses all seven terminal
states to `-1` and `scheduled` to `-2` (`order-lifecycle-spec.md` §1), exists solely for the
liveness test, and is meaningless to compare between cancel states. Keep it as a client-side
presentation table in RavonCore.

### A.3.2 `OrderActor` — 4 values, and `UserRole` — 3, kept distinct

```proto
enum OrderActor {
  ORDER_ACTOR_UNSPECIFIED = 0;
  ORDER_ACTOR_CONSUMER    = 1;
  ORDER_ACTOR_MERCHANT    = 2;
  ORDER_ACTOR_COURIER     = 3;
  ORDER_ACTOR_SYSTEM      = 4;   // pg_cron jobs and triggers (OrderLifecycle.swift:15)
}
```

```proto
// ravon/common/v1/identity.proto — declaration order matches UserRole.swift:4-6
enum UserRole {
  USER_ROLE_UNSPECIFIED = 0;
  USER_ROLE_CONSUMER    = 1;
  USER_ROLE_COURIER     = 2;
  USER_ROLE_MERCHANT    = 3;
}
```

`OrderActor` and `UserRole` share three labels but **must not be one enum**: `SYSTEM` has no
`UserRole` counterpart (`order-lifecycle-spec.md` §2), and the numbering differs because the
Swift declaration orders differ (`consumer, merchant, courier, system` vs
`consumer, courier, merchant`). Unifying them would silently renumber one of the two. A
conversion function `UserRole → OrderActor` (total) and `OrderActor → UserRole?` (partial,
`SYSTEM → nil`) belongs in `common` and gets an exhaustiveness test.

This also matters for security. `profiles.role` is the field that migration 19 locked and
migration 18's `handle_new_user` re-opened by copying `raw_user_meta_data.role`, which
`AuthService.swift:63-72` sets **client-side** (established fact). Therefore: **`UserRole`
must never appear in any request message.** It is a claim the server derives from the verified
JWT subject, and it appears only in responses. Stated as a rule with a CI grep:
`! grep -rn 'UserRole role' proto/**/*Request*` — cheap, and it makes S1 structurally
unreachable through the new transport.

### A.3.3 `DeliveryMode` — 2 values, with a mandatory-explicit rule

```proto
enum DeliveryMode {
  DELIVERY_MODE_UNSPECIFIED  = 0;
  DELIVERY_MODE_HAND_TO_ME   = 1;   // wire: "hand_to_me"
  DELIVERY_MODE_LEAVE_AT_DOOR = 2;  // wire: "leave_at_door"
}
```

**`UNSPECIFIED` must be rejected, never defaulted.** `Order.swift`'s initialiser defaults
`deliveryMode: DeliveryMode = .handToMe`, and `courier_deliver_order` branches on the column
to decide code-vs-photo (`order-lifecycle-spec.md` §4, mig 13:406-415). A proto3 scalar enum
that defaults to `0` plus a server that treats `0` as `hand_to_me` means a client that forgets
the field silently converts a leave-at-door order into a code order, and the courier is then
asked for a code the consumer was never shown. Server behaviour: `CreateOrder` with
`DELIVERY_MODE_UNSPECIFIED` → `invalid_argument` / `REASON_DELIVERY_MODE_REQUIRED`. This is a
one-line rule that prevents a class of field failure the current code is wide open to.

### A.3.4 `CancellationReason` — 18 values, exact match to Swift **and** SQL

Verified against `Sources/RavonCore/Models/CancellationReason.swift:8-37` (18 cases) and
`db/migrations/09_…sql:20-36` (18 literals). See correction §0.3.

```proto
enum CancellationReason {
  CANCELLATION_REASON_UNSPECIFIED = 0;

  // Consumer-initiated  (CancellationReason.consumerAllowed, :40-42)
  CANCELLATION_REASON_CONSUMER_CHANGED_MIND = 1;
  CANCELLATION_REASON_CONSUMER_DUPLICATE    = 2;

  // Restaurant-initiated
  CANCELLATION_REASON_RESTAURANT_CLOSED         = 3;
  CANCELLATION_REASON_RESTAURANT_OUT_OF_ITEMS   = 4;
  CANCELLATION_REASON_RESTAURANT_REJECTED       = 5;
  CANCELLATION_REASON_RESTAURANT_TOO_LONG_WAIT  = 6;

  // Courier-initiated
  CANCELLATION_REASON_COURIER_VEHICLE_ISSUE      = 7;
  CANCELLATION_REASON_COURIER_SAFETY_ISSUE       = 8;
  CANCELLATION_REASON_COURIER_RESTAURANT_CLOSED  = 9;
  CANCELLATION_REASON_COURIER_ITEMS_UNAVAILABLE  = 10;
  CANCELLATION_REASON_COURIER_NON_RESPONSIVE     = 11;

  // System-initiated
  CANCELLATION_REASON_SYSTEM_TIMEOUT          = 12;
  CANCELLATION_REASON_SYSTEM_FRAUD_SUSPECTED  = 13;

  // Scheduled-order activation failures (mig 06 exits)
  CANCELLATION_REASON_RESTAURANT_NOT_OPEN_AT_SCHEDULED_TIME = 14;
  CANCELLATION_REASON_ITEM_UNAVAILABLE   = 15;
  CANCELLATION_REASON_INSUFFICIENT_STOCK = 16;
  CANCELLATION_REASON_ITEM_DELETED       = 17;

  // Customer no-show (informational; the order still lands on DELIVERED — drift 4)
  CANCELLATION_REASON_CUSTOMER_NO_SHOW = 18;
}
```

**Do not model the per-actor allowed subsets as separate enums.** There are three subsets
today and they disagree with each other: `consumerAllowed` = 2 (`:40-42`), `courierAllowed` =
5 (`:47-53`), the SQL CHECK = 18, and `cancel_order_by_courier`'s runtime whitelist = 5 but
partitioned reassignable/non-reassignable (`order-lifecycle-spec.md` §4). Four hand-maintained
lists is exactly the "unenforced contract" failure mode.

Instead: **one enum, plus a server-driven picker.**

```proto
// Returns exactly the reasons this actor may send for this order right now.
// The UI renders the response; it holds no hard-coded list.
rpc ListCancellationReasons(ListCancellationReasonsRequest)
  returns (ListCancellationReasonsResponse) { option idempotency_level = NO_SIDE_EFFECTS; }

message ListCancellationReasonsRequest { string order_id = 1; }
message ListCancellationReasonsResponse {
  message Choice {
    CancellationReason reason      = 1;
    string             display_ru  = 2;   // from localizedDisplayName, :55-76
    bool               requires_free_text = 3;
    // True when picking this reason returns the order to the pool (status → READY)
    // rather than terminating it. Partition verified at mig 13:536-555.
    bool               reassigns_order = 4;
  }
  repeated Choice choices = 1;
}
```

This collapses four lists into one server table, makes `reassignableReason` /
`nonReassignableReason` a **property of the value** rather than two independent boolean guards
(the §4 recommendation), and eliminates the lowercase/uppercase split (defect 14) because
`CourierDelayReason` gets the same treatment:

```proto
// CancellationReason.swift:81-86. The SQL uses lowercase for these five and
// SCREAMING_SNAKE everywhere else (mig 17:125). The proto normalises to one convention;
// the lowercase strings never appear on the new wire.
enum CourierDelayReason {
  COURIER_DELAY_REASON_UNSPECIFIED         = 0;
  COURIER_DELAY_REASON_TRAFFIC             = 1;
  COURIER_DELAY_REASON_RESTAURANT_SLOW     = 2;
  COURIER_DELAY_REASON_ADDRESS_UNCLEAR     = 3;
  COURIER_DELAY_REASON_CUSTOMER_UNREACHABLE = 4;
  COURIER_DELAY_REASON_OTHER               = 5;
}
```

### A.3.5 The other five enums the wire contract needs

From `sql-function-catalogue.md` §6.2, all verified there:

```proto
// ravon/order/v1/order.proto — validate_cart / get_restaurant_orderability reason.kind.
// 7 values, CartValidation.swift:21-27.
enum OrderabilityReason {
  ORDERABILITY_REASON_UNSPECIFIED            = 0;
  ORDERABILITY_REASON_OK                     = 1;
  ORDERABILITY_REASON_RESTAURANT_CLOSED      = 2;
  ORDERABILITY_REASON_RESTAURANT_PAUSED      = 3;
  ORDERABILITY_REASON_RESTAURANT_NOT_ACCEPTING = 4;  // + until
  ORDERABILITY_REASON_OUT_OF_HOURS           = 5;    // + opens_at
  ORDERABILITY_REASON_OVERLOADED             = 6;
  ORDERABILITY_REASON_MIN_ORDER_NOT_MET      = 7;    // + need
}

// Per-item cart status. SQL emits 4 (mig 04:82-93); CartValidation.swift:106-111 declares 5.
// PRICE_CHANGED is decoder-only — no SQL emits it.
enum CartItemStatus {
  CART_ITEM_STATUS_UNSPECIFIED       = 0;
  CART_ITEM_STATUS_OK                = 1;
  CART_ITEM_STATUS_UNAVAILABLE       = 2;
  CART_ITEM_STATUS_INSUFFICIENT_STOCK = 3;   // + have, want
  CART_ITEM_STATUS_DELETED           = 4;
  // Declared in the Swift decoder and emitted by no SQL. Keeping the value means the
  // Kotlin service can implement price-drift detection without a wire change; the
  // alternative is deleting the Swift case. DECISION: keep, and implement — a silent
  // price change between cart view and checkout is the single most trust-destroying
  // thing a delivery app can do.
  CART_ITEM_STATUS_PRICE_CHANGED     = 5;    // + old_price, new_price (Money)
}

enum RestaurantStatus {   // ALTER TYPE only in migrations; labels from the Swift model
  RESTAURANT_STATUS_UNSPECIFIED = 0;
  RESTAURANT_STATUS_ACTIVE      = 1;
  RESTAURANT_STATUS_PAUSED      = 2;
  RESTAURANT_STATUS_CLOSED      = 3;
}

// ravon/ledger/v1 — courier_earnings.earning_type CHECK, 7 values (mig 12:28-31,
// CourierEarning.swift:4-11). Exact match verified.
enum EarningType {
  EARNING_TYPE_UNSPECIFIED            = 0;
  EARNING_TYPE_FULL                   = 1;
  EARNING_TYPE_PARTIAL_ASSIGNED       = 2;   // tier 25%
  EARNING_TYPE_PARTIAL_AT_RESTAURANT  = 3;   // tier 50%
  EARNING_TYPE_PARTIAL_PICKED_UP_LOST = 4;   // tier 100%
  EARNING_TYPE_NO_SHOW_COMPENSATION   = 5;
  EARNING_TYPE_MANUAL_ADJUSTMENT      = 6;
  EARNING_TYPE_CLAWBACK               = 7;
}

enum ChatSenderRole {   // mig 15:16
  CHAT_SENDER_ROLE_UNSPECIFIED = 0;
  CHAT_SENDER_ROLE_CONSUMER    = 1;
  CHAT_SENDER_ROLE_COURIER     = 2;
  CHAT_SENDER_ROLE_MERCHANT    = 3;
  CHAT_SENDER_ROLE_SYSTEM      = 4;
}
```

### A.3.6 The closed-enum hazard `buf breaking` cannot see

`buf` classifies "add an enum value" as **non-breaking**. For Ravon it is breaking at runtime,
and the evidence is in the repo: `OrderabilityReason.init(from:)`
(`CartValidation.swift:29-41`) and `CartItemStatus.init(from:)` (`:113-127`) decode into a
**closed** Swift enum and **throw** on an unrecognised value, and three app binaries are
branch-pinned with no forced upgrade.

Generated Swift protobuf enums are *open* — `protoc-gen-swift` emits
`.UNRECOGNIZED(Int)`, so the *decode* degrades safely. The hazard moves to RavonCore's mapping
layer, where a hand-written `switch` either (a) fails to compile when a value is added, which
is good, or (b) has a `default:` that silently swallows it, which is the current behaviour's
bug. **Gate, added to the Swift CI job because `buf` cannot see it:** for every generated
enum, a test asserts `UNRECOGNIZED` maps to a named safe fallback and that the fallback is
rendered to the user as a generic-but-honest string, never as the "everything is fine"
variant. Concretely: `ORDERABILITY_REASON_UNSPECIFIED` and `.UNRECOGNIZED` must **not** map to
"orderable"; they map to "cannot verify — try again," which fails closed.

## A.4 MONEY — `int64` minor units. Decided, with the rounding rule.

### The decision

```proto
// proto/ravon/common/v1/money.proto
syntax = "proto3";
package ravon.common.v1;

// A signed monetary amount in Tajikistani dirams.
//
// 100 diram = 1 somoni (TJS, ISO 4217 numeric 972, minor unit 2).
//
// This is the ONLY money representation in the Ravon contract. `double` and `float`
// are forbidden for any monetary field; CI enforces this (see the money-type gate).
message Money {
  // Signed amount in dirams. Negative is legal and meaningful: clawbacks, refunds,
  // and the credit side of every ledger entry.
  //
  // Range note: int64 dirams overflows at ~9.2e16 somoni. numeric(12,2) — the widest
  // plausible column — tops out at 1e10 somoni. No lossy range.
  int64 diram = 1;

  // ISO 4217 alphabetic code. MUST be "TJS".
  //
  // Empty is accepted and interpreted as "TJS" so that a client which omits the field
  // is not a hard failure during the cutover. Any other non-empty value is rejected
  // with invalid_argument / REASON_UNSUPPORTED_CURRENCY.
  //
  // Carried per-Money rather than per-envelope so that a second currency is a
  // validation change, not a wire change.
  string currency_code = 2;
}
```

### Why `int64` minor units and not `google.type.Money`

Fetched and read `google/type/money.proto` verbatim. `Money` there is
`{string currency_code = 1; int64 units = 2; int32 nanos = 3;}` with nanos in
`[-999999999, +999999999]` and a documented sign-consistency invariant: "If `units` is
positive, `nanos` must be positive or zero. … If `units` is negative, `nanos` must be negative
or zero."

Four reasons it is the wrong choice here:

1. **It admits values the database cannot store.** The server side is Postgres `numeric` with
   `round(…, 2)` — verified at `mig12:81`
   (`round((v_delivery_fee * v_tier / 100.0)::numeric, 2)`). `nanos` gives 9 decimal places,
   i.e. 7 digits of sub-diram precision that cannot round-trip. A contract whose type is
   strictly wider than its storage is a contract that lies.
2. **The sign invariant is an unenforceable footgun on the exact path that needs negatives.**
   Ravon's money is negative routinely — `EARNING_TYPE_CLAWBACK`, and every credit leg of a
   double-entry transaction. `{units: -1, nanos: +250000000}` is a valid protobuf message and
   an invalid `Money`, and nothing in the toolchain catches it. `int64 diram = -125` has no
   invalid encodings.
3. **Two fields means two places to get arithmetic wrong.** Conservation ("the signed sum per
   transaction is zero", doc 10 Tier-S item 1) is a one-line integer assertion over `diram`.
   Over `(units, nanos)` it is a normalisation problem first.
4. **`currency_code` is unconstrained in either design**, so `google.type.Money` buys nothing
   on that axis, and it costs the well-known-type import in the generated Swift for all three
   apps.

### The single currency constant

```
CURRENCY_CODE == "TJS"      // ISO 4217 alpha; numeric 972; minor unit = diram, 100/somoni
```

Exposed once per language as a constant next to the generated code, never inlined:
`RavonCore.Currency.tjs` in Swift, `Currency.TJS` in Kotlin. Server validation:
`currency_code.isEmpty || currency_code == "TJS"`, else `invalid_argument`.

Note the display-string mess this replaces. `app-courier-constraints.md` §6 (LOUD CORRECTION
#7) verified **15** hard-coded unit sites in the courier app alone, split across **two
spellings** — `сомони` (5 sites) and `сом.` (10 sites) — with `ActiveDeliveryView.swift:145`
and `:262` using *both* for `order.deliveryFee` on the same flow. Plus `₽` (the **rouble**) in
core: `CartValidation.swift:79` and `SupabaseService.swift:60`
(`.minOrderNotMet` → `"Минимальная сумма заказа: \(Int(need)) ₽"` — verified at `:60`,
a Russian rouble sign on a Tajik order). **Pick `сом.`** — it is the majority (10 vs 5), it is
the shorter string for a `.caption` label, and the two-spelling problem is worse than either
spelling. One formatter in RavonCore, zero string interpolation of units at call sites.

### The ONE rounding rule

Three clauses, one rule, no contradiction:

**(1) Transport, storage, and arithmetic: exact `int64` dirams. No rounding, ever.**
Adding, subtracting, and comparing dirams is exact. Nothing on the wire is ever rounded.

**(2) Display: divide by 100 and render exactly 2 fraction digits. This is also exact.**
Because the atomic unit *is* the diram and the display shows 2 decimal places,
`diram → somoni.dd` is a lossless reformat, not a rounding. **Therefore the sum of the
displayed rows equals the displayed total, always, by construction.**

This clause alone deletes a verified defect. `app-courier-constraints.md` §6 measured it:
three 12.50 rows display `12 12 12` (libc `printf "%.0f"` is half-to-**even**, measured on
this machine: `printf '%.0f %.0f %.0f' 0.5 1.5 2.5` → `0 2 2`) while the summary displays
`round(37.50) = 38`. *The total never equals the sum of the visible rows.* With clause (2) the
rows read `12.50 12.50 12.50` and the total reads `37.50`.

A **compact** style (`Int(diram / 100)`, truncating) remains available for standalone headline
figures — the offer-card fee, the Home "today" card. Rule: **the compact style may never
appear on the same screen as its own components.** That is a lint-able UI rule, and it is
strictly narrower than today, where the compact style is used for both rows *and* totals.

Also from §6, fixed by having one formatter: `EarningsView.swift:155` is the only site using
`.formatted(.number…)`, which applies **locale grouping** — a 1 500-somoni day renders
`+1 500 сом.` in a row and `1500 сом.` in the card two inches above. Russian locale uses a
narrow no-break space (U+202F/U+00A0), which is also a string-comparison hazard in tests. One
formatter with an explicit grouping decision (**off**, because the unit label already
disambiguates and NBSP breaks tests) ends that.

And the sign convention, which §6 found undefined (`:153-156` prefixes `+` only when `>= 0`;
`:80` renders the same magnitudes as a *positive* "Удержания: N сом." with a minus icon):
**one signed style.** `formatSomoni(_ m: Money, style: .signed)` renders `-12.50 сом.`;
`.plain` renders `12.50 сом.`. A clawback row is `.signed`. No icon carries sign information.

**(3) Server-side fractional computation: round half-up away from zero to whole dirams, and
post the residual to a rounding account.**

This is the only place rounding exists. It is needed because the server multiplies:
`earnings_tier_for_cancel` returns a percentage (25 / 50 / 100 — `mig12:35-45`) and
`insert_courier_earning_for_cancel` computes `fee × tier/100` (`mig12:80-90`). In diram
integers:

```
earned_diram = roundHalfUpAwayFromZero(fee_diram * tier_pct, 100)
             = (fee_diram * tier_pct + sign(fee_diram * tier_pct) * 50) / 100   // integer div
residual     = fee_diram * tier_pct / 100 - earned_diram        // exactly-representable remainder
```

and `residual` becomes an `Entry` on `ACCOUNT_TYPE_ROUNDING`, so conservation holds to the
diram. Half-up **away from zero** (not half-even) because: it is what a human doing the
arithmetic expects, it is symmetric under negation (so a clawback of a rounded payment is
exactly the rounded payment), and the systematic bias half-even is designed to avoid is
irrelevant when the residual is captured in a ledger account instead of discarded.

While we are here, `app-courier-constraints.md` §5 found two more defects that clause (3) plus
the ledger design fixes, and both are *arithmetic*, not formatting:

- **`totalDeliveryFees` double-counts on partial tiers.** `insert_courier_earning_for_cancel`
  writes `delivery_fee = v_delivery_fee` — the **full** fee — while
  `total_earned = fee × tier/100` (`mig12:80-90`). Summing `deliveryFee` across a 25%-tier
  cancellation reports 100% of the fee under "fees earned." In the ledger design there is no
  `delivery_fee` column to sum: there are entries, and the sum of entries *is* the balance.
- **`courier_earnings` is not append-only.** `insert_courier_earning_for_cancel` ends with
  `ON CONFLICT (order_id) DO UPDATE SET …` (`mig12:84-98`), so a clawback **overwrites** the
  prior partial-pay row. There is no way to reconstruct what the courier was told they earned.
  `PostTransaction` (§A.8.3) is append-only by construction; a clawback is a *new*
  compensating transaction.

### The money-type CI gate (belongs in Part B but is stated here for coherence)

`buf` has no rule that forbids `double`. Add a 3-line check:

```bash
# Any float/double field whose name looks monetary is a hard failure.
! grep -rnE '^\s*(double|float)\s+[a-z_]*(amount|fee|total|subtotal|tip|price|balance|earned|need|revenue|payout|adjustment|diram|somoni)[a-z_]*\s*=' proto/
```

`double` remains legal for genuinely continuous quantities, which are enumerable and few:
`latitude`, `longitude`, `accuracy_meters`, `heading_degrees`, `speed_mps`, `distance_km`, and
the dispatch cost-model scalars (`DispatchCostModel.averageSpeedKmh` etc.,
`Dispatcher.swift:62-75`). Those are measurements, not money.

## A.5 Timestamps, the Dushanbe rule, and the earnings day boundary

**Instants: `google.protobuf.Timestamp`, UTC, always server-stamped.**

This closes a verified defect. `schema-from-callsites.md` §3.3 established that RavonCore
stamps its own timestamps with `ISO8601DateFormatter()` at `SupabaseService.swift:139` —
default options, no fractional seconds — computed from the **client clock** (`Date()`), for
`accepted_at` (`:398`), `rejected_at` (`:428`), `read_at` (`:1085`), `deleted_at` (`:1262`,
`:1292`), and the `gte` bounds at `:606` and `:856-862`. A courier's skewed phone clock writes
skewed audit timestamps. **Rule: no request message contains a timestamp that the server will
persist as an event time.** Requests may carry *intent* times the user chose
(`scheduled_for`); they may never carry `occurred_at`, `created_at`, `accepted_at`,
`delivered_at`, or a query boundary.

**Dates as dates: `google.type.Date`** for the ledger's day partition key — not a `Timestamp`
truncated client-side, which is exactly how the current bug arises.

**Dushanbe: `Asia/Dushanbe`, UTC+5, no DST.** Because there is no DST, the offset is the
constant `+05:00`, which makes the day boundary expressible in SQL as a generated column and
indexable:

```sql
-- the ledger's day partition. Deterministic, immutable, indexable.
business_date date GENERATED ALWAYS AS ((occurred_at + interval '5 hours')::date) STORED
```

### The earnings day boundary rule, stated precisely

> A ledger entry belongs to **business date D** iff its server-stamped `occurred_at` lies in
> the half-open interval `[D 00:00:00.000 +05:00, D+1 00:00:00.000 +05:00)`, i.e.
> `[D-1 19:00:00Z, D 19:00:00Z)`.
>
> - `occurred_at` is the **ledger post time**, not the order's `created_at`. A tip added the
>   next morning belongs to the morning's day.
> - Week = Monday-start ISO week in `Asia/Dushanbe` (TJ first weekday = Monday; matters for
>   `Calendar.firstWeekday` if the client ever renders week labels).
> - Month = calendar month in `Asia/Dushanbe`.
> - **The client never computes the boundary.** It sends a `PeriodSelector`; the server
>   resolves it and echoes the resolved `Period` in the response so the UI can label it
>   truthfully.

```proto
// proto/ravon/common/v1/period.proto
enum PeriodSelector {
  PERIOD_SELECTOR_UNSPECIFIED = 0;
  PERIOD_SELECTOR_TODAY       = 1;   // the current business date in Asia/Dushanbe
  PERIOD_SELECTOR_THIS_WEEK   = 2;   // Monday-start ISO week, calendar boundary
  PERIOD_SELECTOR_THIS_MONTH  = 3;   // calendar month
  PERIOD_SELECTOR_ALL_TIME    = 4;
  PERIOD_SELECTOR_CUSTOM      = 5;   // uses Period below; server clamps to <= 400 days
}

// The server's resolution of a selector. Echoed in every response so the client
// labels what it actually got.
message Period {
  google.type.Date       start_date  = 1;  // inclusive, Asia/Dushanbe
  google.type.Date       end_date    = 2;  // inclusive, Asia/Dushanbe
  google.protobuf.Timestamp start_at = 3;  // inclusive instant, UTC
  google.protobuf.Timestamp end_at   = 4;  // EXCLUSIVE instant, UTC
  // IANA zone the boundaries were computed in. Pinned to "Asia/Dushanbe"; present so
  // that a DST adoption or a second market is a value change, not a schema change.
  string time_zone = 5;
}
```

### Why this is the highest-value single fix in the ledger area

`app-courier-constraints.md` §5 measured the current bug exactly: `ISO8601DateFormatter()`
defaults to GMT so the *instant* transports correctly, but `Calendar.current` at
`SupabaseService.swift:855` resolves the **device's** timezone when computing midnight. With
the device in `America/Los_Angeles` (UTC−7) the offset is exactly 12 h:

- correct "today" for Dushanbe day D: `[D-1 19:00Z, now]`
- actually sent: `[D 07:00Z, now]`
- → **the first 12 hours of the Dushanbe business day are silently excluded from "Сегодня".**

And §5 point 1 is the structural version of the same problem: *the period boundary is entirely
client-determined.* `fetchEarnings` is a PostgREST `GET /courier_earnings` with a
client-supplied `gte`. Anyone with the anon key and a JWT picks their own day. `PeriodSelector`
+ server resolution + the echoed `Period` removes the client's ability to be wrong and the
client's ability to lie, in one field.

Three smaller items §5 flagged, resolved by the same design:
- `.week`/`.month` are **rolling offsets from `now`**, not calendar boundaries
  (`SupabaseService.swift:858`, `:861`). `PeriodSelector` makes them calendar boundaries.
- `.all` is an **unbounded query with no pagination** (`:863-864` `break`, then `:867-870`
  unbounded `.order().execute()`), silently truncated at PostgREST's `max-rows`.
  `ListEntries` is `PageRequest`-mandatory (§A.8.3).
- `ServiceError.courierSuspended`'s own formatter (`SupabaseService.swift:72-74`,
  `dateFormat = "HH:mm"`, **no `timeZone`**) is core-side, so core must consume the pinned
  zone too — not just the apps.

## A.6 TYPED ERRORS

### Transport

`google.rpc.Status` + `google.rpc.ErrorInfo`, carried in the Connect error `details` array.
Verified shapes:

```proto
// google/rpc/status.proto
message Status { int32 code = 1; string message = 2; repeated google.protobuf.Any details = 3; }
// google/rpc/error_details.proto  — fetched verbatim
message ErrorInfo { string reason = 1; string domain = 2; map<string, string> metadata = 3; }
message RetryInfo { google.protobuf.Duration retry_delay = 1; }
```

`ErrorInfo.reason` is documented as "at most 63 characters and match the regex
`[A-Z][A-Z0-9_]+[A-Z0-9]`" — UPPER_SNAKE_CASE. `ErrorInfo.domain` is "the registered service
name of the tool or product that generates the error."

Connect's own error envelope (from <https://connectrpc.com/docs/protocol/>) is
`{"code": "<string>", "message": "<string>", "details": [{"type": "...", "value": "<base64 proto>", "debug": {...}}]}`,
and connect-swift surfaces it as `ConnectError` with `code`, `message`, `metadata`, and
`unpackedDetails()`:

```swift
if let chatErrors: [Eliza_V1_ChatError] = response.error?.unpackedDetails() { … }
```

So the wire is: Connect `code` (the gRPC code) + one `google.rpc.ErrorInfo` in `details`,
optionally plus `google.rpc.RetryInfo`. **`domain = "ravon.dev"`** on every error.

### The reason enum and the bare-kind wire rule

```proto
// proto/ravon/common/v1/error.proto
package ravon.common.v1;

enum ErrorReason {
  ERROR_REASON_UNSPECIFIED = 0;
  ERROR_REASON_UNAUTHORIZED = 1;
  … // full list in the table below
}
```

`ENUM_VALUE_PREFIX` forces the `ERROR_REASON_` prefix on the value *names*. The string placed
in `ErrorInfo.reason` is the **bare kind with the prefix stripped** —
`ERROR_REASON_COURIER_SUSPENDED` → `"COURIER_SUSPENDED"`.

That choice is load-bearing, not cosmetic. The bare kinds are byte-identical to (a) the 29
`DETAIL` strings the existing SQL raises (`sql-function-catalogue.md` §6) and (b) the 18
strings already switched on at `SupabaseService.swift:107-124`. So during the cutover a single
client decoder works against **either** backend, and `ServiceError.from` does not need to
fork. Longest bare kind is `COURIER_ALREADY_HAS_ACTIVE_ORDER` (32 chars) — well inside the
63-char `ErrorInfo.reason` limit, as is the prefixed form (45).

Enforce the strip rule with a round-trip test over `ErrorReason.allCases`; the test is the
transcription (same pattern as `OrderStatus`).

### The full mapping — 38 reason values (37 + UNSPECIFIED)

Derivation from the established 29: **collapse 2 → 1** (−1), **split `RESTAURANT_CLOSED`
three ways** (+2), **add** `INVALID_TIP_AMOUNT`, `TIP_WINDOW_CLOSED`, `ADDRESS_NOT_FOUND`,
`ADDRESS_NOT_OWNED`, `ORDER_ALREADY_CLAIMED`, `IDEMPOTENCY_KEY_REUSED`, `ITEM_DELETED`,
`DELIVERY_MODE_REQUIRED`, `UNSUPPORTED_CURRENCY` (+9) → **37**.

`INSUFFICIENT_STOCK` was already one of the 29 (`sql-function-catalogue.md` §6 row 22,
`create_order`, + `menu_item_id`, `have`). What the task means by "add" it is that it is one of
the **11 kinds the Swift decoder drops** — it gets a mapped, reachable case here for the first
time.

Retry column follows the DoorDash contract in the brief verbatim: clients retry
**`unavailable` / `deadline_exceeded` / `internal` only**, never `invalid_argument` /
`already_exists` / `failed_precondition`. `aborted` is a documented carve-out and retried
**only when a `RetryInfo` detail is attached** (§A.7 clause 3).

| # | bare kind on the wire | Connect / gRPC code | HTTP | `ErrorInfo.metadata` keys | retry? | provenance |
|---|---|---|---|---|---|---|
| 1 | `NOT_AUTHENTICATED` | `unauthenticated` (16) | 401 | — | no | 29-set #17 (`update_courier_heartbeat`) |
| 2 | `UNAUTHORIZED` | `permission_denied` (7) | 403 | — | no | 29-set #1, **13 emission sites** |
| 3 | `ROLE_CHANGE_FORBIDDEN` | `permission_denied` (7) | 403 | `attempted_role` | no | 29-set #11; SQLSTATE **42501**, unmapped in Swift |
| 4 | `ORDER_NOT_FOUND` | `not_found` (5) | 404 | `order_id` | no | 29-set #3 |
| 5 | `RESTAURANT_NOT_FOUND` | `not_found` (5) | 404 | `restaurant_id` | no | **NEW** — split from `RESTAURANT_CLOSED`, mig 04:153 `IF NOT FOUND` |
| 6 | `ADDRESS_NOT_FOUND` | `not_found` (5) | 404 | `address_id` | no | **NEW** — mig 04:202 never checks |
| 7 | `ADDRESS_NOT_OWNED` | `permission_denied` (7) | 403 | `address_id` | no | **NEW** — closes the cross-tenant IDOR, §7 defect 1 |
| 8 | `MENU_ITEM_NOT_FOUND` | `not_found` (5) | 404 | `menu_item_id` | no | **NEW** — split out of `ITEM_UNAVAILABLE`'s `NOT FOUND` arm, mig 04:213 |
| 9 | `INVALID_STATUS_TRANSITION` | `failed_precondition` (9) | 400 | `order_id`, `status`, `attempted_status` | no | 29-set #2, 10 sites, `status` on only 7 |
| 10 | `ORDER_ALREADY_TERMINAL` | `failed_precondition` (9) | 400 | `order_id`, `status` | no | 29-set #16 |
| 11 | `CANCEL_NOT_ALLOWED_POST_PICKUP` | `failed_precondition` (9) | 400 | `order_id`, `status` | no | **COLLAPSED** from 29-set #27 `CANNOT_CANCEL_POST_PICKUP` + #28 `CANCEL_AFTER_PICKUP_NOT_ALLOWED` |
| 12 | `ORDER_NO_LONGER_PICKUPABLE` | `aborted` (10) | 409 | `order_id`, `status` | no | 29-set #6 |
| 13 | `ORDER_ALREADY_CLAIMED` | `aborted` (10) | 409 | `order_id` | no | **NEW** — makes `ServiceError.orderAlreadyClaimed` reachable; see below |
| 14 | `COURIER_ALREADY_HAS_ACTIVE_ORDER` | `failed_precondition` (9) | 400 | `order_id` (the *active* one) | no | 29-set #26 |
| 15 | `COURIER_MUST_BE_ONLINE` | `failed_precondition` (9) | 400 | — | no | 29-set #23 |
| 16 | `COURIER_SUSPENDED` | `permission_denied` (7) | 403 | `until` (RFC3339) | no | 29-set #8 — Swift **drops `until`** |
| 17 | `COURIER_EXCLUDED_FROM_ORDER` | `permission_denied` (7) | 403 | `order_id` | no | 29-set #24 |
| 18 | `COURIER_CANCEL_COOLDOWN` | `resource_exhausted` (8) | 429 | `recent_cancels`, `limit`, `window_hours`, `until` | no | 29-set #25 — Swift **hardcodes 3** |
| 19 | `ACCURACY_TOO_LOW` | `invalid_argument` (3) | 400 | `accuracy_meters`, `max_accuracy_meters` | no | 29-set #29 — Swift **drops `accuracy`** |
| 20 | `INVALID_VERIFICATION_CODE` | `invalid_argument` (3) | 400 | `attempts_remaining` | no | 29-set #21 |
| 21 | `WRONG_DELIVERY_CODE` | `invalid_argument` (3) | 400 | `attempts_remaining` | no | 29-set #9 |
| 22 | `MISSING_PROOF_IMAGE` | `invalid_argument` (3) | 400 | `delivery_mode` | no | 29-set #18 |
| 23 | `INVALID_REASON_CODE` | `invalid_argument` (3) | 400 | `code` | no | 29-set #4 — Swift **drops `code`** |
| 24 | `INVALID_EXTRA_MINUTES` | `invalid_argument` (3) | 400 | `min`, `max` (1, 15) | no | 29-set #7 — **courier-reachable and unmapped** |
| 25 | `SCHEDULED_TIME_INVALID` | `invalid_argument` (3) | 400 | `min_lead_seconds` (300), `max_lead_seconds` (604800) | no | 29-set #10, mig 04:178-183 |
| 26 | `DELIVERY_MODE_REQUIRED` | `invalid_argument` (3) | 400 | — | no | **NEW** — §A.3.3 |
| 27 | `UNSUPPORTED_CURRENCY` | `invalid_argument` (3) | 400 | `currency_code` | no | **NEW** — §A.4 |
| 28 | `INVALID_TIP_AMOUNT` | `invalid_argument` (3) | 400 | `min_diram`, `max_diram` | no | **NEW** — `add_tip` exists in **no migration** (§5b) |
| 29 | `TIP_WINDOW_CLOSED` | `failed_precondition` (9) | 400 | `until`, `delivered_at` | no | **NEW** — ditto |
| 30 | `RESTAURANT_CLOSED` | `failed_precondition` (9) | 400 | `restaurant_id` | no | 29-set #5, narrowed to `restaurant_status = 'closed'` |
| 31 | `RESTAURANT_NOT_ACTIVE` | `failed_precondition` (9) | 400 | `restaurant_id`, `restaurant_status` | no | **NEW** — mig 04:162 `<> 'active'`, the third arm |
| 32 | `RESTAURANT_PAUSED` | `failed_precondition` (9) | 400 | `restaurant_id` | no | 29-set #12, unmapped in Swift, **no `ServiceError` case at all** |
| 33 | `RESTAURANT_NOT_ACCEPTING` | `failed_precondition` (9) | 400 | `restaurant_id`, `until` | no | 29-set #13 |
| 34 | `OUT_OF_HOURS` | `failed_precondition` (9) | 400 | `restaurant_id`, `opens_at` | no | 29-set #15 — SQL hardcodes `opens_at: null` (defect 17); fix server-side |
| 35 | `OVERLOADED` | `resource_exhausted` (8) | 429 | `restaurant_id`, `active_orders`, `max_concurrent_orders` | **no** | 29-set #14 — merchant capacity, not server load; the generic interceptor must not retry it |
| 36 | `MIN_ORDER_NOT_MET` | `failed_precondition` (9) | 400 | `need_diram`, `subtotal_diram` | no | 29-set #19 — `need` is **required** in the Swift decoder (`CartValidation.swift:40` uses `decode`, not `decodeIfPresent`) |
| 37 | `ITEM_UNAVAILABLE` | `failed_precondition` (9) | 400 | `menu_item_id` | no | 29-set #20 |
| 38 | `INSUFFICIENT_STOCK` | `failed_precondition` (9) | 400 | `menu_item_id`, `have`, `want` | no | 29-set #22 — unmapped in Swift today |
| 39 | `ITEM_DELETED` | `failed_precondition` (9) | 400 | `menu_item_id` | no | **NEW** — `validate_cart` emits item status `DELETED` and `CancellationReason.ITEM_DELETED` exists; `create_order` collapses it into `ITEM_UNAVAILABLE` (mig 04:213) |
| 40 | `IDEMPOTENCY_KEY_REUSED` | `already_exists` (6) | 409 | `idempotency_key`, `method`, `first_seen_at` | **no** | **NEW** — §A.7 clause 4 |

(40 rows because `MENU_ITEM_NOT_FOUND` is a 10th addition found while splitting the
`create_order` arms; the enum is therefore **40 values + UNSPECIFIED = 41 members**. The task's
arithmetic and mine differ by the two `NOT_FOUND` splits I found in mig 04 that the brief did
not anticipate — `MENU_ITEM_NOT_FOUND` at `:213` `IF NOT FOUND OR mi.deleted_at IS NOT NULL OR
mi.is_available = false` has the same three-way conflation as `RESTAURANT_CLOSED`.)

### `ORDER_ALREADY_CLAIMED` — why adding a 41st value is worth it

`app-courier-constraints.md` LOUD CORRECTION #6: `OrderOfferView.swift:147` and `:157` both
test `ServiceError.orderAlreadyClaimed` to show `"Заказ уже занят другим курьером"`. **No
server reason maps to it.** `claim_order` raises `ORDER_NO_LONGER_PICKUPABLE` for an
already-taken order (`mig13:199-200`), which maps to `.orderNoLongerPickupable` → the courier
sees the generic `"Заказ больше недоступен"`. So the message a courier hits *most often*
(losing a race) is unreachable even after the `callRPC` fix. Splitting the two conditions —
`ORDER_ALREADY_CLAIMED` when `courier_id IS NOT NULL`, `ORDER_NO_LONGER_PICKUPABLE` when the
status left the claimable set — makes an existing, written, translated UI branch reachable for
the cost of one enum value.

### The structured-payload rule that replaces regex scraping

`ServiceError.from(serverError:)` is a **regex over `String(describing: error)`** —
`SupabaseService.swift:95-105`, pattern `#""reason"\s*:\s*"([A-Z_]+)""#`. It therefore
discards every structured field the server took care to send. Verified losses
(`app-courier-constraints.md` §2): `COURIER_SUSPENDED` + `until` → `until: nil`;
`COURIER_CANCEL_COOLDOWN` + `recent_cancels` → hardcoded `3`; `ACCURACY_TOO_LOW` + `accuracy`
→ `0`; `INVALID_REASON_CODE` + `code` → `""`; `ORDER_NO_LONGER_PICKUPABLE` + `status` →
dropped; `COURIER_ALREADY_HAS_ACTIVE_ORDER` + `order_id` → dropped. Every parameterised
Russian string in `errorDescription` (`SupabaseService.swift:70-82`) is a placeholder waiting
for data the decoder threw away.

`ErrorInfo.metadata` is `map<string, string>`, so the fields arrive typed-as-strings and are
parsed once, in one place, with a test per key. The metadata keys are **part of the contract**
and `buf breaking` does *not* protect map *values* — so the enforcement is a table-driven test
asserting that every `ErrorReason` produces exactly its declared key set, run on both sides
against one shared fixture file. That test is the reason to write `RavonErrorDetail` as a real
message too, for the fields that deserve types:

```proto
// Optional second detail, packed alongside ErrorInfo when a typed payload is useful.
// ErrorInfo.metadata stays the canonical, always-present, language-agnostic form.
message RavonErrorDetail {
  ErrorReason reason = 1;
  oneof payload {
    OrderStateContext   order_state   = 2;   // status, attempted_status, order_id
    CourierGateContext  courier_gate  = 3;   // until, recent_cancels, limit
    CartItemContext     cart_item     = 4;   // menu_item_id, have, want
    MoneyContext        money         = 5;   // need, subtotal  (Money, not double)
    IdempotencyContext  idempotency   = 6;
  }
}
```

### The 11 unmapped kinds, and why closing them is the highest-value item here

`sql-function-catalogue.md` §6.1: the 11 kinds the Swift decoder drops are `RESTAURANT_CLOSED`,
`RESTAURANT_PAUSED`, `RESTAURANT_NOT_ACCEPTING`, `OUT_OF_HOURS`, `OVERLOADED`,
`MIN_ORDER_NOT_MET`, `ITEM_UNAVAILABLE`, `INSUFFICIENT_STOCK`, `SCHEDULED_TIME_INVALID`,
`INVALID_EXTRA_MINUTES`, `ROLE_CHANGE_FORBIDDEN`. **Nine of those eleven are every single
`create_order` failure mode.** `ServiceError` already declares cases for most of them with
Russian strings written and unreachable (`.restaurantClosed` `:49`, `.restaurantNotAccepting`
`:50`, `.restaurantOverloaded` `:51`, `.restaurantOutOfHours` `:52`, `.insufficientStock`
`:53`, `.minOrderNotMet` `:60`, `.scheduledTimeInvalid` `:61`).

Combined with the established fact that `from(serverError:)` has **zero production call sites
in RavonCore** and 7 in the apps (consumer 1, courier 6, merchant 0), and that the courier's
pickup handler is one of the ones that forgot (`ActiveDeliveryView.swift:604-612` catches
`as ServiceError` which never matches, so `:606` is unreachable): **no `create_order` error is
typed today, end to end.** The proto's single most valuable property is that
`response.error?.unpackedDetails()` is the *only* way to read an error, so forgetting to call
the decoder is a compile-time impossibility rather than a per-call-site choice.

