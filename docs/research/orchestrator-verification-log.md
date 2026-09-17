# Orchestrator verification log — claims in PROMPT-kotlin-backend.md checked first-hand

Session 2026-09-16. Every line below was verified by the orchestrator directly, not delegated.

## CONFIRMED

| Claim | Evidence |
|---|---|
| Supabase project deleted | `mcp supabase list_projects` returns only `Daily` (<unrelated-live-project-a>) and `toj-staging` (<unrelated-live-project-b>). Listed `toj-staging`'s tables — it is a Telegram-style messenger (dialogs/messages/calls/stickers), zero Ravon objects. `nslookup <dead-ravon-project-ref>.supabase.co` → NXDOMAIN on 8.8.8.8. |
| Apps pinned to a dangling tip | All three `Package.resolved` pin `ravon-core` to branch `mmarufov/auth-overhaul` rev `a1e9d6c814436c82dd93388158768e6720c2b18e`. `git merge-base --is-ancestor a1e9d6c8 origin/main` → false. `git tag` → empty. |
| 163 tests pass | `swift test` → `Executed 102 tests, with 0 failures` (XCTest) + `Test run with 61 tests in 16 suites passed` (swift-testing). 102 + 61 = 163. |
| Dispatch is 1,208 lines | `wc -l Sources/RavonCore/Dispatch/*.swift` → 1208 total across 6 files. |
| 21 RPCs / 15 tables from Swift | Enumerated by grep over `Sources/`. Counts match the inventory exactly. |
| `schema_drift.py` reports 15 unverified | `python3 scripts/schema_drift.py` → `0 drift, 15 unverified`, exit 0. |
| Rouble sign still in core | `CartValidation.swift:79` and `SupabaseService.swift:60`, both `"Минимальная сумма заказа: \(Int(need)) ₽"`. Exactly the cited lines. |
| 17 order states | `OrderStatus` in `Models/Order.swift` has 17 cases. |
| 17 lifecycle invariants | `grep -c "func test" Tests/RavonCoreTests/OrderLifecycleInvariantTests.swift` → 17. |
| 4 actors | `OrderActor`: consumer, merchant, courier, system. |

## CORRECTED — the brief is wrong

### C1. The foundation is not committed. This is the top risk and the brief never mentions it.
`git status --short` on `mmarufov/bucharest-v9`:
```
?? .github/                                          <- the entire CI
?? Sources/RavonCore/Dispatch/                        <- the engine being ported to Kotlin
?? Sources/RavonCore/Models/OrderLifecycle.swift      <- "the specification the Kotlin order service must implement"
?? Tests/RavonCoreTests/OrderLifecycleInvariantTests.swift
?? Tests/RavonCoreTests/{Dispatch,Hungarian,Switchback,SchemaDrift}*.swift
?? scripts/                                           <- schema_drift.py + scan_secrets.py
?? AGENTS.md
```
`git rev-list --count origin/main..HEAD` → **0**. `origin/main` holds 65 files and no `.github/`.
`gh api repos/mmarufov/ravon-core/actions/workflows` → `total_count: 0`; `gh run list` → empty.

So: **"CI with 5 jobs" has never executed once.** The workflow file is untracked. And the five
untracked test files account for 40 of the 163 tests. Every asset §5 says must not break exists
only in this worktree's working directory. A Conductor workspace teardown or a `git clean -fd`
destroys the entire basis of the plan.

**Phase 0 step 1 is `git add` + PR, before anything else.**

### C2. `ServiceError.from(serverError:)` has TEN call sites — three in core tests, seven in app production code. Both the brief and my first pass were wrong.
First pass: "3 call sites, all in `Tests/RavonCoreTests/CourierCancellationTests.swift:55,65,74`, zero
production." That grep was scoped to this repo. The consumer-constraints agent grepped the fleet:

| repo | production call sites |
|---|---|
| consumer | `DuDash/Views/Orders/OrderDetailView.swift:598` (pre-pickup cancel flow) |
| courier | `OrderOfferView.swift:156`, `ActiveDeliveryView.swift:737, 745, 779, 810`, `OrderRowView.swift:203` |
| merchant | none |

So the brief's "zero call sites, every structured payload is discarded" is false. The **actual**
defect is narrower and worse for the typed-error design:
1. The decoder is **opt-in per call site**, not wired into `SupabaseService`'s throw path. The
   consumer's cancel flow uses it; the consumer's tip flow six lines later does not; merchant uses
   it nowhere.
2. When used, it **discards every payload field except `reason`** (`SupabaseService.swift:107-124`)
   — `status`, `order_id`, `need`, `until`, `recent_cancels` all lost.
3. Its regex is `"reason"\s*:\s*"([A-Z_]+)"` — **uppercase only**. The migration-20 tip design
   uses lowercase codes (`tip_exceeds_cap`), which cannot parse. Three documents define three
   error vocabularies and one of them is unparseable by the shipped decoder.
4. It handles 18 of the 29 reason kinds (per the SQL catalogue §6).

The §9 requirement stands. The justification must be "opt-in, lossy, case-sensitive, 62% coverage" —
not "dead code" — or a reviewer who greps will discount the whole plan.

### C3. The dispatch engine has NO consumers at all — not even inside RavonCore.
`Dispatcher`, `HungarianSolver`, `MarketplaceSimulator`, `SwitchbackExperiment` are referenced
only from `Tests/`. `DispatchZone` is referenced from nowhere, including tests. Greps across all
three app repos for those five symbols return **zero hits**.

This materially weakens the brief's justification #1. "Dispatch ships inside the client package
all three apps embed, but a courier's phone cannot see the other couriers" is true about where
the code *lives* and false about what is *happening*: no client calls it, so no wrong behaviour
results. It is an unexercised research artifact compiled as dead weight into three binaries.

The honest and stronger Phase-1 argument: dispatch is the only component with a **complete,
verified reference implementation and a test oracle** (Hungarian cross-checked against brute
force on 300 matrices; a 30-seed simulator regression). A Kotlin port can be proven equivalent
by differential testing against the Swift original, and carries zero regression risk because
nothing calls it. That is a better reason than a layering violation that isn't biting.

Consequence the brief misses: Phase 1 ships a service **with no consumer**. `fetch_available_orders`
— the courier offer feed — is reported as never called either. So Phase 1 must include wiring
dispatch to a real caller, or it delivers something unobservable.

### C4. 36 transitions, not 38.
`grep -c "\.init(" Sources/RavonCore/Models/OrderLifecycle.swift` → **36**, all inside the
`transitions` array. No occurrence of "38" in the file or its tests.

Probable reconciliation: line 103 says *"Two entries are marked `missingServerSide` below"* and
**no `missingServerSide` marker exists anywhere in the file.** So the documented 38 = the 36
declared edges + the 2 transitions described in prose but never added to the array. The docs
count an intention; the data counts reality. Port the 36 and treat the 2 as a named gap.

### C5. All three apps target iOS 26.2, not just consumer.
`IPHONEOS_DEPLOYMENT_TARGET = 26.2` in all three `.pbxproj`. `Package.swift` declares
`.iOS(.v17)`. So there is no 9-major-version spread across apps to reconcile — the spread is
between the package floor and a uniform app target. That makes the gRPC-client minimum-iOS
question easier than the brief implies, and makes `.iOS(.v17)` in the manifest a lie worth
fixing in Phase 0 regardless.

### C6. Merchant is not uniquely the easiest client to migrate. Courier is equally gated.
`grep -rc "import Supabase"`: merchant **0**, courier **0**, consumer **2**. Two of three clients
cannot author a query RavonCore didn't write. Only consumer can, and it does — the consumer
report admits one direct `orders` write.

### C7. The JWKS-vs-shared-secret question is resolved: ES256, asymmetric, JWKS.
Empirical, not from docs. Both live projects in the account serve a populated key set:
```
GET https://<unrelated-live-project-b>.supabase.co/auth/v1/.well-known/jwks.json → 200
{"keys":[{"alg":"ES256","crv":"P-256","kty":"EC","use":"sig","key_ops":["verify"],"kid":"75c79453-…"}]}
```
Same shape for `<unrelated-live-project-a>`. `toj-staging` was created **2026-09-09**, seven days ago —
so this is what a freshly provisioned Ravon project gets, not a legacy artifact.

Interceptor consequences:
- ECDSA P-256 verification, `kid`-based key selection from the JWK set. **Not HMAC.**
- A library that only handles RSA JWKS is disqualified.
- Supabase docs: the endpoint is cached **10 min at Supabase's edge + up to 10 min in client
  libraries**, cleared every ~20 min. Revocation is therefore *not* instantaneous for a
  self-verifying backend (it is for Supabase's own products). The interceptor needs an explicit
  cache-bust path or the plan must state the 20-minute revocation window as accepted risk.
- Supabase will not let you extract the private key once on signing keys, so the Kotlin service
  cannot mint Supabase-compatible JWTs unless a key is imported deliberately.

Corroborating evidence that the wrong answer was already assumed once: the abandoned
`mmarufov/Ravon_android` repo's `backend/.env.example` asks for `SUPABASE_JWT_SECRET` — i.e. an
HS256 shared-secret design. That is the mistake this resolution prevents repeating.

## NEW — not in the brief

### N1. There are four app repos and one is already Kotlin.
`gh repo list`: `ravon-core` (**public**), `ravon-consumer`, `ravon-merchant`, `ravon-courier`
(private), and **`Ravon_android`** — private, primaryLanguage **Kotlin**, Gradle Kotlin DSL,
last push 2026-03-11, ~102 KB. Contents: a Compose `HomeScreen`, theme, a Retrofit
`DuDashApiService` with `/health` and `/api/v1/hello`, and a `backend/` directory containing
only `fly.toml` (+ `fly-deploy.sh`, `.env.example`) — `primary_region = 'sjc'`, 1 GB shared-cpu,
`/health` check. A deploy target was chosen and abandoned; no service source was written.

Two consequences:
1. An argument for proto contracts the brief misses entirely: a `.proto` generates Kotlin stubs
   for free, so an Android client stops being a second hand-written API layer. That is a real
   payoff, not a portfolio talking point.
2. `primary_region = 'sjc'` is San Jose. For Dushanbe that is a terrible default. Fly has no
   Central Asia region; the realistic choices are Frankfurt/Warsaw. Whatever the stack research
   returns, do not inherit `sjc`.

### N2. The monorepo has a repo-visibility problem nobody has addressed.
`ravon-core` is **public**; all three apps are **private**. "One repo" forces one visibility:
- public monorepo → three previously-private app codebases become public;
- private monorepo → the public portfolio artifact disappears, and the docs' entire framing is
  "this is a portfolio."
Neither is free. The plan must pick one and say why. Related hazard: co-locating `services/`
with `ios/` puts service config beside client code — the Android repo already has a
`backend/.env.example` naming `SUPABASE_SERVICE_ROLE_KEY` inside an *app* repo. `scan_secrets.py`
must therefore gate the whole monorepo, and env templates must never carry real values.

### N3. Money is `numeric` on the server and `Double` in Swift, and `Order` has no payment method.
Corrected from a first pass. The server side is already right:
`db/migrations/04_create_order_v3_and_validate_cart.sql:144` declares
`subtotal numeric := 0; v_total numeric;` and migration 12 rounds courier earnings with
`round((v_delivery_fee * v_tier / 100.0)::numeric, 2)`. So Postgres stores and computes money as
`numeric` with 2-decimal rounding.

Swift degrades it: `Sources/RavonCore/Models/MenuItem.swift:9` is `public let price: Double`, and
the three apps then apply three different rounding rules on top (merchant truncates via `Int(x)`,
courier rounds via `%.0f`, consumer is integer-when-whole else `%.2f`). The lossy hop is
JSON `numeric` → Swift `Double`, not the database.

That reframes the work: this is not "migrate money off floating point everywhere," it is
"stop the client from decoding `numeric` into `Double`." Smaller than it looked, and it argues for
int64 minor units on the **wire** (the proto) rather than a schema change.

Separately: `grep -in "payment\|cash\|card" Sources/RavonCore/Models/Order.swift` → **no matches.**
There is no payment method on the order at all. Tajikistan is a cash-heavy market, and a
double-entry ledger cannot book a cash-collected order without knowing who is holding the cash.
Adding a payment method to the order model is therefore a prerequisite for the ledger phase, not
a later nicety.

### N12. `create_order` has no idempotency key, and that is the concrete defect the order service exists to fix.
`db/migrations/04_…:127` — the signature is
`create_order(p_restaurant_id, p_address_id, p_items, p_notes, p_scheduled_for)` and it
`RETURNS uuid`. There is no client-supplied key and no dedupe on any natural key. The Swift side
(`SupabaseService.swift:360`) just does
`let result: String = try await client.rpc("create_order", params: params).execute().value`.

**A retried checkout creates a second order.** On a throttled Dushanbe 3G link that is not a
hypothetical. This is the single strongest concrete justification for the order service, and it is
better than "SQL is untestable": there is a specific, reachable double-charge bug, and DoorDash's
published idempotency contract fixes it exactly.

Two more things read off the body, both relevant to porting it as a saga:
- It takes real row locks: `SELECT * FROM restaurants … FOR UPDATE` and
  `SELECT * FROM menu_items … FOR UPDATE` per line item. The Kotlin port must preserve equivalent
  serialisation or it loses the stock/throttle guarantees.
- `IF NOT FOUND OR r.restaurant_status = 'closed'` conflates "restaurant does not exist" with
  "restaurant is closed" — both raise `RESTAURANT_CLOSED`. The typed-error design should split
  these (`NOT_FOUND` vs `FAILED_PRECONDITION`).

### N13. The authoritative error-reason set is 29 kinds, and two pairs are duplicates.
Extracted with a multiline-safe regex over every `'reason', '<KIND>'` in the migrations:

`ACCURACY_TOO_LOW`, `CANCEL_AFTER_PICKUP_NOT_ALLOWED`, `CANNOT_CANCEL_POST_PICKUP`,
`COURIER_ALREADY_HAS_ACTIVE_ORDER`, `COURIER_CANCEL_COOLDOWN`, `COURIER_EXCLUDED_FROM_ORDER`,
`COURIER_MUST_BE_ONLINE`, `COURIER_SUSPENDED`, `INSUFFICIENT_STOCK`, `INVALID_EXTRA_MINUTES`,
`INVALID_REASON_CODE`, `INVALID_STATUS_TRANSITION`, `INVALID_VERIFICATION_CODE`,
`ITEM_UNAVAILABLE`, `MIN_ORDER_NOT_MET`, `MISSING_PROOF_IMAGE`, `NOT_AUTHENTICATED`,
`ORDER_ALREADY_TERMINAL`, `ORDER_NOT_FOUND`, `ORDER_NO_LONGER_PICKUPABLE`, `OUT_OF_HOURS`,
`OVERLOADED`, `RESTAURANT_CLOSED`, `RESTAURANT_NOT_ACCEPTING`, `RESTAURANT_PAUSED`,
`ROLE_CHANGE_FORBIDDEN`, `SCHEDULED_TIME_INVALID`, `UNAUTHORIZED`, `WRONG_DELIVERY_CODE`.

Frequency is informative: `UNAUTHORIZED` appears 13 times, `INVALID_STATUS_TRANSITION` 10,
`ORDER_NOT_FOUND` 7 — those three are 30 of the ~68 raise sites, i.e. the bulk of the error surface
is authorisation, state-machine refusal, and lookup failure. Those map cleanly onto
`PERMISSION_DENIED`, `FAILED_PRECONDITION`, `NOT_FOUND`.

`CANCEL_AFTER_PICKUP_NOT_ALLOWED` and `CANNOT_CANCEL_POST_PICKUP` are two spellings of one
condition. The proto enum should collapse them, not preserve both.

Several carry structured context beside the reason: `status`, `order_id`, `need`, `menu_item_id`,
`have`, `accuracy`, `until`, `recent_cancels`, `code`. That payload is what makes these worth
typing — and it is exactly what `ServiceError.from` was written to read and never wired up (C2).

### N4. Doc 10 and the brief disagree on phase order, and the brief says not to reorder.
`.context/architecture/10-POLYGLOT-RESTRUCTURE.md` Part 4: Phase 1 = **ledger**, Phase 2 =
order + dispatch. `PROMPT-kotlin-backend.md` §8: Phase 1 = **dispatch**, Phase 2 = ledger,
Phase 3 = order. Both documents present their order as settled. This must be resolved explicitly
in the plan rather than silently following one of them.

### N5. `CLAUDE.md` and `AGENTS.md` are byte-identical (3021 bytes each) and both still claim
"iOS 17+", contradicting C5.

### N6. The RLS model is not reconstructible from ANY of the three sources. This is worse than the column gap.
`grep -in "CREATE POLICY" db/migrations/*.sql` yields policies for exactly four tables:
`menu_items`, `menu_categories`, `courier_cancellation_log`, `chat_messages`.

**There is no `CREATE POLICY ... ON orders` anywhere.** Nor on `profiles`, `addresses`,
`restaurants`, `order_items`, `order_status_history`, `courier_earnings`, `courier_locations`,
`restaurant_hours`, `modifier_groups`, `modifier_options`, `menu_item_modifier_groups`.

The brief treats the migrations as an incomplete source for *tables* and offers the Swift models
as a second record. That works for columns. It does not work for RLS: a Swift call site tells you
what query the client *issued*, never what the server *permitted*. So the authorisation model for
11 of 15 tables is simply gone, and no union of repo sources recovers it.

Two consequences, and the first is good news:
1. The brief's §10 goal — "no client write policies on `orders` at all" — is free. There is nothing
   to remove; there is only something to not create. Same for the security report's
   "over-broad UPDATE policies on orders": those were dashboard-created, so they died with the
   project.
2. RLS must be **designed from scratch**, not reconstructed, and the plan must say so plainly
   instead of implying the migrations give a starting point. Given RLS is demoted to
   defence-in-depth behind the Kotlin services, designing it fresh is the right call anyway — but
   it is net-new work that the "reconstructed schema" deliverable does not cover.

### N7. `create_order` takes five parameters, not the four CLAUDE.md documents.
`db/migrations/04_create_order_v3_and_validate_cart.sql:127` —
`create_order(p_restaurant_id uuid, p_address_id uuid, p_items jsonb, p_notes text, p_scheduled_for timestamptz)`.
The grant at line 277 confirms the 5-arg signature. `CLAUDE.md` / `AGENTS.md` document
`create_order(p_restaurant_id, p_address_id, p_items, p_notes)` — the scheduled-orders parameter
from migration 06 was never added to the docs. Minor, but it is the one RPC signature the project
instructions state explicitly, and it is wrong.

### N8. The typed-error surface is 29 distinct `reason` kinds.
Enumerated from every `USING DETAIL = jsonb_build_object('reason', …)` across the migrations:
`ACCURACY_TOO_LOW`, `CANCEL_AFTER_PICKUP_NOT_ALLOWED`, `CANNOT_CANCEL_POST_PICKUP`,
`COURIER_ALREADY_HAS_ACTIVE_ORDER`, `COURIER_CANCEL_COOLDOWN`, `COURIER_EXCLUDED_FROM_ORDER`,
`COURIER_MUST_BE_ONLINE`, `COURIER_SUSPENDED`, `INVALID_EXTRA_MINUTES`, `INVALID_REASON_CODE`,
`INVALID_STATUS_TRANSITION`, `INVALID_VERIFICATION_CODE`, `ITEM_UNAVAILABLE`, `MIN_ORDER_NOT_MET`,
`MISSING_PROOF_IMAGE`, `NOT_AUTHENTICATED`, `ORDER_ALREADY_TERMINAL`, `ORDER_NOT_FOUND`,
`ORDER_NO_LONGER_PICKUPABLE`, `OUT_OF_HOURS`, `OVERLOADED`, `RESTAURANT_CLOSED`,
`RESTAURANT_PAUSED`, `ROLE_CHANGE_FORBIDDEN`, `SCHEDULED_TIME_INVALID`, `UNAUTHORIZED`,
`WRONG_DELIVERY_CODE`.
Note `CANCEL_AFTER_PICKUP_NOT_ALLOWED` and `CANNOT_CANCEL_POST_PICKUP` are two spellings of one
condition — an existing inconsistency the proto enum should collapse, not preserve.
Several carry structured context alongside the reason (`status`, `order_id`, `need`,
`menu_item_id`, `accuracy`, `until`, `recent_cancels`, `code`). That payload is what makes these
worth typing, and it is exactly what `ServiceError.from` was built to read and never wired up (C2).

### N9. Only three functions are granted to `anon`, and all three are read-only.
`restaurant_within_hours`, `restaurant_is_orderable`, `get_restaurant_orderability` —
`GRANT EXECUTE ... TO authenticated, anon`. Every other function is `authenticated`-only. So the
security reports' "anon-callable SECURITY DEFINER RPC" concern has a much smaller blast radius
than the brief's framing suggests; these three take a restaurant id plus a timestamp and return
orderability. Worth confirming they leak no non-public restaurant fields, but they are not a
privilege-escalation path.

### N10. The dangling pin has a documented cause.
`.context/integration-prompts/_shared.md` step 1 instructs each app: *"Bump the RavonCore SPM
dependency to the new tag (TBD when published — for now, point to the `mmarufov/auth-overhaul`
branch or the local path)."* All three apps did exactly that. The tag was never published. So this
is not drift; it is an instruction that was followed and never closed out. The fix is to publish
the tag and re-pin — and to never again hand the app agents a branch as a dependency target.

### N11. The iOS gRPC client decision has hard numbers, and they point the opposite way from doc 11.
Fetched both manifests directly.

**gRPC Swift 2** (`grpc/grpc-swift-2`, `main`): `swift-tools-version:6.1`; availability mapped to
**macOS 15.0, iOS 18.0**, watchOS 11, tvOS 18, visionOS 2. No package-level `platforms:` block —
the floor is expressed through the `@available` mapping in build settings.

**Connect-Swift** (`connectrpc/connect-swift`, `main`): `swift-tools-version:5.9`;
```
platforms: [ .iOS(.v13), .macOS(.v10_15), .tvOS(.v13), .watchOS(.v6) ]
```

RavonCore today: `swift-tools-version: 5.9`, `platforms: [.iOS(.v17), .macOS(.v14)]`.

So adopting gRPC Swift 2 forces RavonCore to **Swift tools 6.1, iOS 18, macOS 15**. Adopting
Connect-Swift costs nothing on either axis.

The iOS bump is harmless in practice — all three apps are already on 26.2 (C5). The macOS bump
matters slightly more because `swift test` runs on macOS: the CI runner is `macos-15`, exactly at
the new floor, and local development would require macOS 15+.

`.context/architecture/11-KOTLIN-DECISION.md` recommends gRPC Swift 2 with Connect-Swift as the
fallback. On this evidence the default should be **Connect-Swift**, for a reason that document
raises and then does not follow through on: it asks "whether streaming is needed at all given
Supabase Realtime already handles subscriptions," and the answer is no — order-status and chat
subscriptions stay on Realtime by design. Unary-only is the whole requirement. Connect-Swift
delivers unary over HTTP/1.1 or HTTP/2 in <200 KB with no platform bump, no Swift-6 tools
migration, and no Envoy.

The genuinely useful conclusion is that **this decision is reversible and must not gate Phase 1.**
Both are wire-compatible with gRPC, so the server is unaffected by the choice; switching is a
client-side change inside RavonCore. Pick Connect-Swift, and make the switch trigger explicit: the
first RPC that genuinely needs bidirectional streaming.

## SESSION 2 — additions and one retraction

### R1. RETRACTED: "the app code is not on `main` in any of the three repos" (arch-docs §1e)
The arch-docs agent's table compared `~/conductor/repos/<app>@main` against the workspace
branches and concluded the real app code lives only on unmerged workspace branches. **Wrong.**
`~/conductor/repos/` are stale main checkouts — 2 / 4 / 5 commits behind `origin/main`.
Verified from each workspace after `git fetch`:
```
kolkata  HEAD 1ffcb1a == origin/main 1ffcb1a  (ancestor: yes)  RavonCore-importing files on origin/main: 49
milan    HEAD d0842d6 == origin/main d0842d6  (ancestor: yes)  22
buffalo  HEAD 2117610 == origin/main 2117610  (ancestor: yes)  27
```
The workspace branches ARE `origin/main`. Consequences: Phase 0 needs no branch merging; the
"fourth supabase-swift version (2.46.0)" seen on `repos/` main is a stale-checkout artifact and
the brief's three versions (2.41.1 / 2.42.0 / 2.43.1) are the real fleet. What *survives* of
§1e: the `.pbxproj` requirement is `kind = branch` (floating), so no app build is reproducible.
Note for future agents: never trust `~/conductor/repos/` as a source of truth; fetch in the workspace.

Also: `milan` has 10 uncommitted files. Flag to the merchant chat.

### R2. Dispatch baseline recorded, seeds 1–30, before any port
`.context/research/dispatch-baseline-seeds-1-30.json` — 60 rows (30 seeds × greedy/optimal),
11 fields each, at `Config(courierCount: 12, orderCount: 240, durationMinutes: 180)` = the exact
`DispatchSimulationTests` config. Harness: `_scratch/main.swift`, compiled against the 6
untracked `Dispatch/*.swift` files with `swiftc -O`.

| Metric | Measured | Docs claim | Test floor |
|---|---|---|---|
| mean Δ orders assigned | **+44.6%** | +42% (`05`), +44.6% (note) | `> 0.20` → note asks `≥ 0.35` |
| mean Δ delivery minutes | **−45.3%** | −45% | none |
| mean Δ courier travel | **−1.1%** | −1.4% | `< +10%` |
| seeds where optimal wins | **30/30** | 30/30 | `≥` per seed |
| weakest seed | **+29.9%** (seed 6) | — | — |

So the note's numbers are exact, the docs' "−1.4% travel" is slightly off, and a per-seed floor
would have to sit below 0.30 — the `≥ 0.35` tightening is on the *mean* and has 9.6 points of
headroom. The RNG is SplitMix64 (`MarketplaceSimulator.swift:14-23`), so seed-for-seed
reproduction in Kotlin is feasible; the residual risk is Swift's stdlib range-mapping for
`Double.random(in:using:)` / `Int.random(in:using:)`, which the port must reimplement rather
than substitute.

### R3. `db/` exists and is empty (created 16:21 today). No `db/ledger/`, no `HANDOFF-for-kotlin.md`,
no ledger branch on origin. The parallel ledger agent has not landed yet. Plan Phase 3 is written
as a facade over `ledger_post(...)` with an explicit interface-needs table to reconcile against
the handoff when it appears.

---

## Measured dispatch numbers — the travel claim is overstated

Compiled and ran the real engine this session (seeds 1–30, 12 couriers, 240 orders, 180 min —
the exact config `DispatchSimulationTests` uses). Fixture: `dispatch-baseline-seeds-1-30.json`.

| Claim in the docs / the note | Measured | Verdict |
|---|---|---|
| +42% orders assigned | **+44.6%** mean, min +29.9%, optimal wins **30/30** | Understated. Good. |
| −45% mean delivery time | **−45.3%** | Accurate. |
| **−1.4% courier travel** | **−1.06%** mean over 30 seeds — **but the worst single seed is +2.13%** | **Overstated, and the mean hides the sign flip.** |
| 30/30 seeds | 30/30 on orders assigned | Accurate. |

The travel number is the one to fix before it goes on a résumé. Over the 10 seeds the test
actually checks, the mean is **−0.78%** with a worst case of **+1.87%**. So optimal matching does
sometimes drive *further* than greedy. The defensible claim is **"no measurable travel penalty —
mean −1.1%, worst single seed +2.1%"**, not "−1.4% less travel." That is still a strong result
(a +44.6% throughput gain bought for roughly zero extra driving); it is just not a travel
*improvement*, and a reviewer who reruns the sim will see the +2.13% seed.

This also explains why `test_throughputGainDoesNotCostExtraTravel` allows 10% headroom rather
than asserting the mean: the headroom is accommodating the per-seed spread. Tightening it to the
mean would make the test flaky. The test comment now records the real numbers.

Changes made to `Tests/RavonCoreTests/DispatchSimulationTests.swift` this session (test-only, both
verified green — 7/7 dispatch, 7/7 Hungarian):
- `test_optimalDispatchIsSubstantiallyBetterUnderLoad`: guard tightened from
  `XCTAssertGreaterThan(mean, 0.20)` to `XCTAssertGreaterThanOrEqual(mean, 0.35)`, as the
  coordination note requested, with the comment corrected from "+42%" to the measured +44.6%
  (min +29.9%, 30/30).
- `test_throughputGainDoesNotCostExtraTravel`: comment corrected from "measured is ~-1.4%" to the
  real per-seed spread, with the reason the 10% headroom has to stay.

**Also confirmed:** `HungarianSolverTests.test_matchesBruteForceOptimum_onRandomMatrices` passes —
300 random matrices (rows 1–5, columns rows–6, integer costs 0–50) checked against a brute-force
optimum to 1e-9. The solver really is exact at this size, which is what retires Gurobi from the
non-goals list and what makes the Kotlin port verifiable rather than merely tested.

## S1 verified first-hand: the PR that closed it opened an easier version, and documented doing so

Read migrations 18 and 19 and `AuthService.swift` directly. The chain holds, link by link:

1. `Sources/RavonCore/Services/AuthService.swift:63-72` —
   `client.auth.signUp(email:password:data: ["full_name": …, "role": .string(role.rawValue)])`.
   GoTrue writes `data` verbatim into `auth.users.raw_user_meta_data`.
2. `18_handle_new_user_trigger.sql:26` —
   `COALESCE((NEW.raw_user_meta_data->>'role')::user_role, 'consumer'::user_role)`, inserted
   straight into `public.profiles.role`. `AFTER INSERT ON auth.users`, `SECURITY DEFINER`.
3. `19_lock_down_profile_role.sql:35-39` — the guard is
   `BEFORE UPDATE ON public.profiles … WHEN (auth.uid() IS NOT NULL AND auth.uid() = OLD.id)`.
   The trigger insert is not an UPDATE, and during the `auth.users` insert there is no session so
   `auth.uid()` is NULL regardless. **The guard cannot fire on the path that sets the value.**

So `POST /auth/v1/signup` with the anon key and `{"data":{"role":"merchant"}}` still yields a
merchant profile — no session, no app, one curl. Migration 19 relocated S1 from "escalate after
signup" to "declare at signup," which is strictly cheaper for the attacker.

Two details that make this the sharpest illustration of the project's own thesis — *every fleet
bug is an unenforced contract*:

- **Migration 18's header describes the metadata read approvingly**, as a feature: *"Reads
  `full_name` and `role` from auth.users.raw_user_meta_data, which the Swift
  `AuthService.signUp()` already passes via the `data:` parameter."* Migration 19's header says it
  *"Closes the CRITICAL finding."* **Both shipped in the same PR (#9, the auth overhaul.)** The
  contract "a user does not choose their own role" was written in a comment and enforced nowhere.
- **Migration 19's stated purpose is itself unfulfilled.** Its header says the structured error
  exists *"so the Swift `ServiceError.from(serverError:)` decoder can surface a typed
  `.unauthorized`"* — but `ROLE_CHANGE_FORBIDDEN` is not one of the 18 kinds in that decoder's
  switch (`SupabaseService.swift:107-124`), so it returns `nil`. The migration added an error
  contract for a consumer that was never written.

This is why §9 rule 4 is "`role` is never client input," enforced three ways — no INSERT grant on
`profiles` for any client role, no `UPDATE (role)` column grant, and a CI assertion that no
`pg_proc` body matches `raw_user_meta_data|user_metadata`. A comment describing the intent is
exactly what failed here.

## Settled against `origin/main` blobs: the pin, the SDK drift, and two agents' stale-checkout error

Two research agents independently reached opposite wrong conclusions from the same cause — they
read `~/conductor/repos/<app>` checkouts, which are **2–5 commits behind `origin/main`**:

- `arch-docs-constraints.md` §1e concluded *"the app code is not on `main` in any of the three
  repos"* and that there is a **fourth** supabase-swift version (2.46.0).
- `proto-and-ios-client.md` §0.2 concluded the dangling pin is *"a workspace-only artifact"*, that
  courier/merchant `main` track `ravon-core@main` normally via `f48982b0`, that
  `repos/ravon-consumer@main` has **no ravon-core dependency at all**, and therefore that *"the
  compatibility gate has, today, zero merged consumers."*

**Both are wrong.** Read directly out of `origin/main` with `git show origin/main:<path>`:

| app | `origin/main` pbxproj requirement | `origin/main` Package.resolved ravon-core | supabase-swift | files importing RavonCore on `origin/main` |
|---|---|---|---|---|
| consumer | `kind = branch; branch = "mmarufov/auth-overhaul"` | `a1e9d6c8…` on that branch | **2.41.1** | 49 |
| merchant | `kind = branch; branch = "mmarufov/auth-overhaul"` | `a1e9d6c8…` | **2.43.1** | 22 |
| courier | `kind = branch; branch = "mmarufov/auth-overhaul"` | `a1e9d6c8…` | **2.42.0** | 27 |

Also verified: each workspace branch (`kolkata-v1` / `milan-v1` / `buffalo-v1`) has HEAD **equal
to** `origin/main` and is an ancestor of it — the workspaces are level, not ahead.

So, conclusively:

1. **The dangling-branch requirement is on `origin/main` for all three apps.** It is not a
   workspace artifact. Deleting `mmarufov/auth-overhaul` breaks `main` in three repos.
2. **The app code is on `origin/main`** — 49/22/27 files. There is no branch-merging to do in
   Phase 0, only re-pinning.
3. **The compatibility gate has three merged consumers, not zero.** The proto doc's headline
   argument for landing `proto/` early ("free now, expensive later") is built on a false premise.
   The better version of that argument survives: there is no forced-upgrade mechanism for shipped
   iOS apps, so `v1` has to be right regardless of how many consumers are merged.
4. **Three supabase-swift versions, not four** — 2.41.1 / 2.43.1 / 2.42.0, exactly as the original
   brief said. 2.46.0 exists only in the stale local checkouts. **Pin target is `2.43.1`**, the
   newest actually on `origin/main`, which is what the app prompts specify.

**Rule for every later phase:** `~/conductor/repos/<app>` is a stale convenience clone. Read app
state with `git show origin/main:<path>` from the Conductor workspace, or fetch first. Two
independent agents tripped on this, so it is a property of the environment, not a lapse.

### Kept from `proto-and-ios-client.md` §0 (verified-good parts)

- **No app has a hand-maintained pbxproj.** All three are `objectVersion = 77` with
  `PBXFileSystemSynchronizedRootGroup` and exactly 3 `PBXBuildFile` entries (framework links, not
  sources). Adding a `.swift` file needs **zero** pbxproj edits — so the brief's justification for
  checked-in generated code ("one is a hand-maintained pbxproj") is wrong. The real constraint is
  better: each app links exactly **one** SwiftPM product (`RavonCore`), so adding a second requires
  a reviewable pbxproj edit in three repos. That is the actual mechanism enforcing "the apps never
  import Connect."
- **There is no seam to inject a client, and no test needs one.**
  `grep -rln "SupabaseService\|AuthService\|URLProtocol\|URLSession\|Mock" Tests/` → **0 files**;
  `grep -rn "protocol .*Service\|protocol .*Client" Sources/` → **0 hits**. `SupabaseService.swift:134`
  and `RealtimeService.swift:84` both resolve `client` from the global `AuthService.shared`. All 163
  tests are pure value/Codable/algorithm tests, so they keep passing untouched — the work is
  *creating* the seam for new tests, not retrofitting mocks.
- **`cancellation_reason_code` has 18 values, not 17**, and `CancellationReason.swift:8-37` also
  declares 18 — an exact Swift↔SQL match, contradicting `sql-function-catalogue.md` §6.2.
- **`RESTAURANT_CLOSED` has three causes, not two**: row-not-found and `status = 'closed'`
  conflated at `04_…:153-157`, plus any other non-`active` status at `:162-165`. The typed-error
  split is three-way.
- Tool versions, fetched live 2026-09-16: `buf` **v1.73.0**, `buf-action` **v1.5.0**,
  `connect-swift` **1.2.3**, `connect-kotlin` **v0.9.0**, `swift-protobuf` **1.38.1**.
