# Architecture-docs constraint extraction

Research note, 2026-09-16. Read-only audit of the architecture docs against the repo.

Docs read in full:
- `/Users/mmarufov/conductor/workspaces/ravon-core/bucharest/.context/architecture/02-TARGET-ARCHITECTURE.md`
- `/Users/mmarufov/conductor/workspaces/ravon-core/bucharest/.context/architecture/05-DISPATCH-ENGINE.md`
- `/Users/mmarufov/conductor/workspaces/ravon-core/bucharest/.context/architecture/08-EXPERIMENT-DESIGN-STUDY.md`
- `/Users/mmarufov/conductor/workspaces/ravon-core/bucharest/.context/architecture/10-POLYGLOT-RESTRUCTURE.md`
- `/Users/mmarufov/conductor/workspaces/ravon-core/bucharest/.context/migrations/README.md`
- `/Users/mmarufov/conductor/workspaces/ravon-core/bucharest/README.md`
- `/Users/mmarufov/conductor/workspaces/ravon-core/bucharest/CLAUDE.md`
- `/Users/mmarufov/conductor/workspaces/ravon-core/bucharest/AGENTS.md`

Read additionally because they are load-bearing for the contradictions:
`11-KOTLIN-DECISION.md`, `12-BACKEND-INVENTORY.md` (spot reads: `01`, `07`, `09`, `PROMPT-kotlin-backend.md`).

---

## 0. CLAUDE.md vs AGENTS.md — identical

**Byte-identical.** `diff` returns empty; both 62 lines; both
`md5 = f411afe17ee33e6c9cd7f9f2c7a5b241`.

`AGENTS.md` is untracked (git status: `?? AGENTS.md`); `CLAUDE.md` is tracked. So today it is a
duplicate, not a divergence — but nothing enforces that. This is exactly the class of bug
`02-TARGET-ARCHITECTURE.md:100` names ("a contract that nothing enforces"): two files that must
agree, with no test, no symlink, and no CI check behind the agreement. If a monorepo Phase 0
happens, one of them should become a symlink or a generated file.

Note also that both files are now materially wrong about the repo they describe — see §7.

---

## 1. `10-POLYGLOT-RESTRUCTURE.md` — the Phase 0 spec, captured faithfully, then critiqued

### 1a. The proposed layout (verbatim, `10-POLYGLOT-RESTRUCTURE.md:57-79`)

```
ravon/                                  # ONE repo — DoorDash consolidated as they grew
├── proto/                              # single source of truth for every contract
│   ├── ravon/order/v1/order.proto
│   ├── ravon/dispatch/v1/dispatch.proto
│   ├── ravon/ledger/v1/ledger.proto
│   └── ravon/common/v1/money.proto
├── services/                           # Kotlin + gRPC
│   ├── dispatch/                       # DeepRed analogue — moved out of the iOS package
│   ├── order/                          # checkout saga, state machine, idempotency
│   ├── ledger/                         # double-entry money
│   └── fraud/                          # rules engine: checkpoints, facts DAG, shadow mode
├── ml/                                 # Python
│   ├── eta/                            # Weibull via interval regression
│   ├── forecast/                       # region×time supply/demand
│   └── anomaly/                        # 21d/7d/1d dual-gate detector
├── ios/
│   ├── RavonCore/                      # Swift package = their "CommonApp"
│   └── apps/{consumer,merchant,courier}/   # thin wrappers, semantic theming
├── db/migrations/                      # SQL: schema, RLS, constraints only
├── policies/                           # policy-as-code gates
└── tools/                              # schema drift, secret scan, codegen
```

Phase 0 scope, verbatim (`10-POLYGLOT-RESTRUCTURE.md:187-189`):

> **Phase 0 — restructure (no new features).** One repo; `proto/` with a CI compatibility
> gate; move `Dispatch/` out of the Swift package into `services/dispatch`; XcodeGen; thin app
> wrappers with semantic theming. Everything still works at the end.

And the hard instruction (`10-POLYGLOT-RESTRUCTURE.md:216-217`):

> **Do not skip Phase 0.** Adding services on top of three repos pinned to a dangling
> branch compounds the problem the restructure exists to remove.

### 1b. The XcodeGen story — the whole of it

There are exactly **three sentences** of XcodeGen content across the entire `.context/` tree:

| Citation | Content |
|---|---|
| `10-POLYGLOT-RESTRUCTURE.md:91` | "`.pbxproj` merge conflicts; makes build settings diffable (how the iOS 26.2 vs 17 split would've been caught)" / precedent: "Published exactly this" |
| `02-TARGET-ARCHITECTURE.md:140` | "Three hand-maintained project files today. Cheap to adopt, removes a whole class of merge pain, and makes the three apps' build settings *diffable*" |
| `02-TARGET-ARCHITECTURE.md:181` | "Adopt XcodeGen; stop committing `.pbxproj`." |
| `01-DOORDASH-RESEARCH.md:41` | The DoorDash evidence line. |

**There is no `project.yml` anywhere, no example, no spec of what goes in it, and no statement
of which build settings become the shared base.** Verified: `grep -rIn 'XcodeGen\|project\.yml'`
over `.context/ Sources/ Tests/ scripts/ README.md CLAUDE.md .github/` returns only the doc
prose above — zero config artefacts.

Critique: the stated *justification* is falsified by the repo. The claim is that diffable build
settings are "how the iOS 26.2 vs 17 divergence would have been caught." But there is no
divergence to catch — **all three apps are `IPHONEOS_DEPLOYMENT_TARGET = 26.2`**, verified in
both checkout sets:

```
repos/ravon-consumer   26.2      workspaces/ravon-consumer/kolkata  26.2
repos/ravon-merchant   26.2      workspaces/ravon-merchant/milan    26.2
repos/ravon-courier    26.2      workspaces/ravon-courier/buffalo   26.2
```

The three apps *agree* with each other and *disagree with RavonCore's `Package.swift`*
(`.iOS(.v17)`) and with `CLAUDE.md`/`README.md`. A diffable `project.yml` compares app to app —
it would have shown three identical values and caught nothing. The real detector needed here is
a check that the apps' deployment target matches the package's declared platform, which is a
different tool. **XcodeGen is being justified with the wrong failure.**

### 1c. The semantic-theming story — thinner still

Three mentions, one of substance:

| Citation | Content |
|---|---|
| `10-POLYGLOT-RESTRUCTURE.md:75` | Layout comment: "thin wrappers, semantic theming" |
| `10-POLYGLOT-RESTRUCTURE.md:90` | "`сум`/`сомони`/`₽` divergence becomes one token \| They rejected separate targets and xcconfig; chose a shared library + DI, ~90% shared" |
| `10-POLYGLOT-RESTRUCTURE.md:189` | Phase 0 line |
| `09-BUILD-MENU.md:226` (outside my brief, the only real spec) | "They rejected separate targets and xcconfig, chose thin app wrappers over a shared library with **semantic** colors — `.border(.secondary)`, never `isCaviar ? .darkGray : .black`. RavonCore already *is* CommonApp; finish it deliberately. \| 1–2 days" |

Critique, three problems:

1. **Internal contradiction inside one table row.** `10-POLYGLOT-RESTRUCTURE.md:90` cites
   DoorDash as having "rejected separate targets" — while `02-TARGET-ARCHITECTURE.md:162-163`
   cites the same research as "DoorDash builds two distinctly branded apps from one codebase
   with ~90% shared code and **separate targets**." Same precedent, opposite reading, two docs.
   See §6, C-4.
2. **The example it gives is not a theming problem.** The `сум`/`сомони`/`₽` divergence is a
   *currency formatting* bug, not a color/typography token. Verified: the surviving `₽` sites are
   `Sources/RavonCore/Models/CartValidation.swift:79` and
   `Sources/RavonCore/Services/SupabaseService.swift:60`, both
   `"Минимальная сумма заказа: \(Int(need)) ₽"` — i.e. string interpolation of a `Double` inside
   a localized error message. A semantic *color* system fixes none of that. The doc that gets
   this right is `02-TARGET-ARCHITECTURE.md:186-187`: "One `Money` type in core: one currency…
   Make it impossible to render a raw `Double` as a price." Phase 0 in `10` mislabels a `Money`
   type as theming.
3. **No token inventory.** `README.md:274-278` lists exactly three brand tokens (`ravonRed`,
   `ravonDark`, `ravonGray`) and `ravonGray` has no documented value. "Semantic theming" with a
   3-token palette and no per-role variation is a rename, not a system. There is no statement of
   what the three apps would even theme *differently* — and `02-TARGET-ARCHITECTURE.md:164-165`
   concedes the apps are "three *roles* rather than two brands, so they'll share less," which
   argues the DoorDash Caviar/DoorDash dual-brand precedent does not transfer at all.

### 1d. How the three app repos become thin wrappers — **and the gap**

The doc asserts the outcome and never specifies the mechanism. What it actually says:

- Layout: `ios/apps/{consumer,merchant,courier}/` (`:75`).
- Benefit claim: "The dangling-branch pin and three divergent Supabase SDK versions become
  *structurally impossible*" (`:85`).
- Sequencing: "One repo" (`:187`), "Do not skip Phase 0" (`:216`).

**Does it explain how three separate GitHub repos become one monorepo without losing history?
No. Not one word.** Verified by exhaustive grep of the doc for every plausible mechanism term:

```
grep -nIi 'history|subtree|filter-repo|submodule|git mv|import' 10-POLYGLOT-RESTRUCTURE.md
→ :85   "dangling-branch pin ... structurally impossible"   (not a mechanism)
→ :148  "replay history through the same evaluator"          (fraud engine, unrelated)
```

There is no `git subtree add`, no `git filter-repo --to-subdirectory-filter`, no
`--allow-unrelated-histories` merge, no discussion of whether history is preserved at all, and
no decision recorded on the alternative (fresh repo, history abandoned, old repos archived
read-only). For a document whose central thesis is "one repo," the one irreversible step is
unspecified.

**What happens to the dangling `a1e9d6c8` pin? Also unspecified.** The pin is named twice
(`:85`, `:216`) purely as motivation. Nothing says whether Phase 0 (a) resolves the pin to a
merge commit first, (b) cherry-picks `a1e9d6c8`'s content onto `main` before consolidating, or
(c) simply deletes the dependency edge and lets the content arrive as files. These have
different outcomes: the orchestrator established that the content diff `a1e9d6c8..origin/main`
is only `.gitignore` + `README.md`, so option (c) is nearly free *today* — but the doc does not
know that and does not say it.

### 1e. Additional critique: the repo state is materially worse than Phase 0 assumes

This is the most important finding in this section. The doc's premise — "three repos pinned to a
dangling branch" — is only true of the **Conductor workspace branches**, not of the app repos'
`main`. Verified:

| Checkout | branch | HEAD | RavonCore dep declared in `.pbxproj` | `Package.resolved` ravon-core | supabase-swift | files importing RavonCore |
|---|---|---|---|---|---|---|
| `workspaces/ravon-consumer/kolkata` | `mmarufov/kolkata-v1` | `1ffcb1a` | `kind = branch; branch = "mmarufov/auth-overhaul"` | `a1e9d6c8…` / `mmarufov/auth-overhaul` | **2.41.1** | 49 |
| `workspaces/ravon-merchant/milan` | `mmarufov/milan-v1` | `d0842d6` | (remote ref present) | `a1e9d6c8…` / `mmarufov/auth-overhaul` | **2.43.1** | 22 |
| `workspaces/ravon-courier/buffalo` | `mmarufov/buffalo-v1` | `2117610` | (remote ref present) | `a1e9d6c8…` / `mmarufov/auth-overhaul` | **2.42.0** | 27 |
| `repos/ravon-consumer` | `main` | `424e9ad` **"Remove broken RavonCore gitlink"** | **none — no ravon-core package reference at all** | **absent** | **2.46.0** | **0** |
| `repos/ravon-merchant` | `main` | `c8bcf6e` | `kind = branch; branch = main` | `f48982b0…` / `main` | **2.46.0** | **1** |
| `repos/ravon-courier` | `main` | `8296c54` | `kind = branch; branch = main` | `f48982b0…` / `main` | **2.46.0** | **1** |

Three consequences the docs do not account for:

1. **There is a fourth Supabase SDK version.** `02-TARGET-ARCHITECTURE.md:89` says "Three
   different Supabase SDK versions (2.41.1 / 2.42.0 / 2.43.1)". That is exactly right for the
   workspace branches, and incomplete: `main` in all three repos resolves **2.46.0**. Four
   versions across six checkouts.
2. **The declared requirement is not a pin — it is a floating branch.** In `repos/ravon-merchant`
   and `repos/ravon-courier` the `.pbxproj` says `kind = branch; branch = main`
   (`project.pbxproj:367-370` in each). A branch requirement means the build is not reproducible
   at all; `a1e9d6c8` is only what a *stale* `Package.resolved` remembers. The docs frame this as
   "pinned to a dangling branch," which understates it: there is no pin, only a stale lockfile.
   `02-TARGET-ARCHITECTURE.md:170` claims "with one repo there is no pin, no tag, no dangling
   branch" — true, but the problem being solved is misdescribed.
3. **The app code is not on `main` in any of the three repos.** `repos/ravon-consumer@main` has
   **zero** files importing RavonCore and a HEAD commit literally titled *"Remove broken
   RavonCore gitlink"*; merchant and courier `main` have one each. The 49/22/27 files of real app
   code live only on the unmerged workspace branches. So "consolidate the three app repos into
   one repo" is not a mechanical move of three `main` branches — it requires deciding which
   *branch* of each repo is canonical first. Phase 0 says "Everything still works at the end"
   (`:189`) without acknowledging that on `main`, today, nothing works: there are no apps there
   to wrap.

### 1f. Phase 0 items that are already true, and one that is not

- "move `Dispatch/` out of the Swift package into `services/dispatch`" (`:188`) — `Dispatch/` is
  already **fully unwired** from the rest of RavonCore. `grep -rn
  'Dispatcher|MarketplaceSimulator|HungarianSolver|ZoneGrid' Sources/RavonCore` returns hits in
  only the six files inside `Sources/RavonCore/Dispatch/` itself. Nothing in `Models/`,
  `Services/`, or `UI/` references it. So the extraction has no call-site fan-out — it is a
  file move plus a language port, which is the cheapest item in Phase 0, not a risk.
- `Sources/RavonCore/Dispatch/` is **untracked** (`git status: ?? Sources/RavonCore/Dispatch/`).
  Moving untracked files into a new monorepo has no history to preserve, which quietly removes
  part of problem 1d — but only for this one directory, and only by accident.
- "`proto/` with a CI compatibility gate" (`:187`) — `.github/` exists but is untracked
  (`?? .github/`). Whether it already contains a workflow is out of scope for this note.

---

## 2. `02-TARGET-ARCHITECTURE.md` — what it commits to that a Kotlin extraction contradicts

`02` contains an explicit **Refuse** table (`:145-155`). Four of its six rows are directly
contradicted by the Kotlin plan in `10` and `11`:

| `02` commitment | Citation | What contradicts it |
|---|---|---|
| **"Kotlin/gRPC microservices — Supabase Postgres + RPCs *is* the right backend for one developer. Microservices trade simplicity for team parallelism you don't have."** | `02:149` | `10:24` ("Kotlin + gRPC → backend services"), `10:64-68` (four Kotlin services), `11:3` ("**yes, but as an extraction, not a rewrite**"). This is the head-on collision. |
| "Cadence workflow engine — `pg_cron` already does the job; the escalation ladder is written." | `02:151` | `12:52-53` moves `run_courier_escalation_ladder`, `mark_no_show_deliveries`, `activate_scheduled_orders` to "Kotlin scheduled workers, replacing `pg_cron`". `10:166` still cites Cadence approvingly for the payout lock. |
| "Monorepo with distributed build service — the monorepo idea is right; the *distributed build service* is not." | `02:154` | Not contradicted, but `10` adds `proto/` codegen + `protoc` in the iOS build (`11:85-86`), which is new build surface of exactly the kind `02` was trimming. |
| "Service mesh — There is one service." | `02:155` | `10:64-68` proposes four Kotlin services plus three Python packages. Seven deployables. |

Three further `02` commitments that a Kotlin extraction breaks, which the Refuse table does not
even flag:

1. **"Authorization lives in Postgres, not in Swift"** — `02:135-143` builds the whole Adopt
   table on RLS + `SECURITY DEFINER` being the referee; `README.md:288` states it as a security
   invariant; `CLAUDE.md` makes "Backend security verification must happen against the actual
   Supabase policies and grants" a project rule. A Kotlin service connecting "as its **own
   role** — not as the end user" (`11:75-76`) *inverts* this: Postgres stops being the gate and
   becomes defence-in-depth. `10:211-213` admits this cost explicitly ("Supabase's value drops…
   RLS stays as defence-in-depth, the service is the primary gate"). So the two docs disagree
   about which layer is authoritative, and `README.md` + `CLAUDE.md` are on `02`'s side.
2. **"Typed, structured errors across the boundary… It just needs a `callRPC` wrapper that
   actually calls it"** (`02:138`) — this is a concrete Phase 1 item (`02:189-191`) that becomes
   dead work if the 13 RPCs move to Kotlin and errors arrive as gRPC status + error details.
   `10`/`11` never retire it; `02:189` still schedules it. Someone will build a `callRPC` wrapper
   for RPCs that are scheduled for deletion.
3. **"Functional core, imperative shell… pure functions in RavonCore with no I/O — which makes
   them unit-testable without a backend. That matters enormously right now, because there
   *is* no backend"** (`02:139`) — the stated *reason* for putting pricing/state-transition logic
   in Swift is the absence of a backend. The Kotlin plan supplies a backend and then moves that
   logic out (`11:45`). The argument for `02`'s Phase 1 evaporates the moment Phase 1 of `11`
   lands, but `02`'s Phase 1 is still written as work to do.

**Sequencing collision.** Both docs define a "Phase 0", and they are not the same Phase 0:

| | `02:178-182` | `10:187-189` / `11:101-103` |
|---|---|---|
| 1 | Consolidate three repos + RavonCore into one repo, three targets | One repo |
| 2 | Adopt XcodeGen; stop committing `.pbxproj` | `proto/` + CI compatibility gate |
| 3 | Add a test target, wire PreviewSnapshots + PropertyTestingKit | Move `Dispatch/` → `services/dispatch` |
| 4 | — | XcodeGen |
| 5 | — | Thin app wrappers + semantic theming |

`02`'s Phase 0 item 3 (test target + PreviewSnapshots) is silently dropped from `10`'s Phase 0,
and `10` silently adds two items. Neither doc references the other's numbering. Anyone executing
"Phase 0" needs to be told which one.

---

## 3. `05-DISPATCH-ENGINE.md` — measured results and their exact provenance

### 3a. Provenance table

Every number in `05`, mapped to the assertion that does or does not back it. Test file:
`/Users/mmarufov/conductor/workspaces/ravon-core/bucharest/Tests/RavonCoreTests/DispatchSimulationTests.swift`
(`DST`) and `…/HungarianSolverTests.swift` (`HST`).

| Claim in `05` | Cite | Asserting test | What is actually asserted | Verdict |
|---|---|---|---|---|
| orders assigned **+42.2% mean** across 30 seeds | `:65` | `DST:37` `test_optimalDispatchIsSubstantiallyBetterUnderLoad` | `XCTAssertGreaterThan(mean, 0.20)` (`DST:48`). The mean *is* computed over seeds 1…30 (`DST:39-47`); `42.2` appears only in a code comment (`DST:35-36`: "Measured at +42% mean"). | **Computed, not pinned.** A regression to +21% passes. |
| min **+30.2%**, max **+55.2%** | `:65` | none | min/max are never computed. | **Unasserted.** |
| mean delivery time **−44.6%** (min −38.2, max −49.6) | `:66` | **none** | `meanDeliveryMinutes` appears in the whole dispatch suite exactly once: `DST:95`, inside `test_simulationIsReproducible`, asserting only that two runs of the *same* seed agree to `1e-12`. No test compares greedy vs optimal delivery time. | **Unasserted. This is the second headline number in the doc and nothing guards it.** |
| total courier travel **−1.4%** | `:67` | `DST:53` `test_throughputGainDoesNotCostExtraTravel` | `XCTAssertLessThan(optimal.totalCourierTravelKm, greedy.totalCourierTravelKm * 1.10)` (`DST:59-62`), seeds 1…10 only. `-1.4%` is a comment (`DST:58`). | **Weakly asserted.** The test permits **+10% more** driving; the doc's "on the same fuel" (`:77`) and "on 1.4% *less* courier travel" (`:121` of `10`) are not protected. |
| **30 / 30** seeds where optimal won | `:68` | `DST:22` `test_optimalDispatchNeverLosesToGreedy` | `XCTAssertGreaterThanOrEqual` over seeds 1…30 (`DST:27-30`). | **Mis-stated.** The test asserts optimal never *loses* (≥). "Won 30/30" requires strict `>` on all 30, which is not asserted. |
| Single run seed 42: `greedy 121/240, 115.3 min, 981.8 km` / `optimal 164/240, 67.3 min, 980.8 km` | `:73-74` | **none** | No test runs seed 42 at 12 couriers. `DST:71-72` uses seed 42 at **6** and **48** couriers. | **Unasserted and not reproducible from the suite.** |
| Supply sweep, 6 couriers: 61 → 101, **+65.6%** | `:85` | `DST:70` `test_advantageVanishesWhenCouriersAreAbundant` | `XCTAssertGreaterThan(scarceGain, 20)` (`DST:81`) — an **absolute** order count, not a percentage. 101−61 = 40 > 20, so consistent. | **Partially asserted** (a 21-order gain would pass). |
| Supply sweep, 12 couriers: 121 → 164, +35.5% | `:86` | — | Note the arithmetic: (164−121)/121 = **+35.5%**, which is the *seed-42* figure, whereas `:65`'s **+42.2%** is the 30-seed mean. Both are "12 couriers". The doc does not say they are different quantities, and a reader will read `:86` as contradicting `:65`. | **Confusing, not wrong.** |
| Supply sweep, 24 couriers: 238 → 240, +0.8% | `:87` | **none** | 24 couriers is not exercised by any test. | **Unasserted.** |
| Supply sweep, 48 couriers: 240 → 240, **0.0%** | `:88` | `DST:82-85` | `XCTAssertEqual(abundantOptimal.ordersAssigned, abundantGreedy.ordersAssigned)`. | **Fully asserted.** The strongest-guarded number in the doc, and it is the *caveat*, not the headline — which is consistent with `:90-96`'s "lead with the caveat". |
| "asserted as a test (`test_advantageVanishesWhenCouriersAreAbundant`)" | `:92-93` | `DST:70` | Test exists with that exact name. | **Correct.** |
| Solver verified against brute force over **300 random matrices** of varying shape | `:100-101` | `HST:57` `test_matchesBruteForceOptimum_onRandomMatrices` | 300 trials (`HST:59`), rows 1…5, columns rows…6 (`HST:60-61`), exhaustive permutation oracle (`HST:19-41`), equality to `1e-9` (`HST:68-71`). | **Fully asserted, exactly as described.** |
| valid-permutation checks (no column twice) | `:102` | `HST:76` | 200 trials, `Set(used).count == used.count` (`HST:87`). | **Correct.** |
| surplus rows returning unmatched | `:103` | `HST:102` | `HST:109-112`. | **Correct.** |
| forbidden pairs never selected even when the only option | `:103` | `HST:117` | `HST:127-128` (`[[forbidden]]` → `nil`). | **Correct.** |
| Haversine vs Dushanbe→Khujand **~205 km** | `:104` | `HST:137` | `XCTAssertEqual(distance, 205, accuracy: 15)` (`HST:141`) plus zero-distance and symmetry. | **Correct.** (Note `DST:123` comments "~200 km" for the same pair — cosmetic inconsistency.) |
| Cost function `travelToPickup + waitAtRestaurant + deliveryLeg − min(orderAge × 1.5, 25) − min(courierIdle × 0.4, 25)` | `:38-42` | — | Matches `Sources/RavonCore/Dispatch/Dispatcher.swift:124-130` exactly, with defaults `orderAgeCreditPerMinute = 1.5`, `courierIdleCreditPerMinute = 0.4`, `maxCreditMinutes = 25` (`Dispatcher.swift:79-82`), each credit capped separately. | **Faithful.** |
| 8 km service radius | `:49`, `:137` | — | `maxAssignmentRadiusKm: Double = 8` (`Dispatcher.swift:78`); enforced at `Dispatcher.swift:110`; tested at `DST:120`. | **Faithful.** |
| "Jonker-Volgenant form of the Hungarian algorithm with potentials, O(n²m), handling rectangular inputs by padding to square" | `:25-26` | — | `HungarianSolver.swift:1-3` claims exactly this; padding at `HungarianSolver.swift:33-37`. The *algorithmic characterisation* is a source comment, unverified by test — but the *behaviour* (optimality) is verified against brute force, which is the claim that matters. | **Faithful; the complexity class is a comment, not a measurement.** |
| "`Sources/RavonCore/Dispatch/`, **4 files**, **14 tests**" | `:3` | — | **14 tests is exactly right**: `DST` has 7 `func test`, `HST` has 7. **4 files is stale**: the directory now holds 6 files / 1208 lines. `DispatchZone.swift` (mtime 11:29) and `SwitchbackExperiment.swift` (mtime 11:28) were created ~11 hours after `05` was written (mtime 00:38) the same day. | **Stale by construction, not an error.** |
| "Suite total: **93 XCTest + 61 swift-testing = 154 tests**, all passing" | `:106` | — | Today: **102 + 61 = 163** (orchestrator-verified). Reconciles exactly: 113 `func test` are declared, of which 11 sit behind `#if canImport(UIKit)` and are compiled out on macOS (`EmailValidatorTests.swift:1` ×3, `OTPCooldownTests.swift:1` ×1, `PasswordStrengthTests.swift:1` ×7) → 102. At `05`'s write time `SwitchbackExperimentTests` (7) and `SchemaDriftToolTests` (2) did not exist → 102 − 9 = **93**. | **Stale, and stale in a verifiable way.** The doc's number was correct when written. Worth noting the suite size is **platform-dependent**: 163 on macOS, 174 on iOS. |
| "Not wired to the app" | `:150-152` | — | Confirmed: `Dispatch/` symbols are referenced only from `Dispatch/` and `Tests/`. Also `Sources/RavonCore/Dispatch/` is untracked in git. | **Correct.** |

### 3b. Two methodological notes on the results

1. **The baseline is not what production does.** `Dispatcher.swift:139-144` says
   `GreedyDispatcher` is "What Ravon does today, modelled faithfully." It is not quite:
   `GreedyDispatcher` defaults to the *same credit-bearing* `DispatchCostModel()`
   (`Dispatcher.swift:149`), so it ranks candidates by travel + wait + delivery − urgency −
   fairness, whereas the production SQL quoted at `05:9-14` has no cost model at all (radius
   filter + `ORDER BY created_at`, courier self-selects). This is arguably the *better* experiment
   — it isolates lookahead as the single independent variable — but it means "+42% vs what Ravon
   does today" overstates the comparison. The honest statement is "+42% from batch lookahead,
   holding the cost model constant."
2. **`DispatchCostModel.distanceOnly` is dead code.** Declared at `Dispatcher.swift:90-93` with
   the doc comment "Pure distance only — used as the control in simulator experiments." Verified:
   `grep -rn 'distanceOnly' Sources/ Tests/` returns exactly one hit — the declaration. The
   documented control has never been run. If the "distance minimisation starves edge couriers"
   argument (`05:30-35`) is going to be defended in an interview, this is the experiment that
   would substantiate it, and it does not exist.

---

## 4. `08-EXPERIMENT-DESIGN-STUDY.md` — design, bias finding, and the harness interface

### 4a. The design, as built

Three designs on one simulated world (`08:18-24`), implemented in
`Sources/RavonCore/Dispatch/SwitchbackExperiment.swift`:

| Design | Randomisation unit | Implementation |
|---|---|---|
| ground truth | none — two separate full-world runs | `SwitchbackExperiment.run` lines 234-240: `MarketplaceSimulator.run` twice, same `config.seed`, one dispatcher each; lift = difference in assignment rate ×100 |
| naive A/B | each individual order, coin-flipped | `ArmAssignment.naiveOrderLevel(salt:)`, `SwitchbackExperiment.swift:63-70`, FNV-style hash of the order UUID |
| switchback | each (zone × time block) cell | `ArmAssignment.switchback(grid:blockMinutes:epoch:salt:)`, `SwitchbackExperiment.swift:74-99`; cell key = `(zone.row, zone.column, floor(minutes/blockMinutes))` |

Both non-truth designs run inside a single world via `ExperimentDispatcher`
(`SwitchbackExperiment.swift:103-147`), which splits orders by arm while **both arms draw from
one courier pool** — the interference under study. It alternates which arm gets first refusal on
the pool by tick parity (`SwitchbackExperiment.swift:121-123`), so arm ordering cannot masquerade
as a treatment effect. That detail is good and is *not* mentioned in `08`.

`ZonedDispatcher` (`DispatchZone.swift:90-115`) is the fix: `Dictionary(grouping:)` couriers by
`grid.zone(for: courier.location)` and orders by `grid.zone(for: order.pickup)`, then run `base`
per zone. `ZoneGrid` (`DispatchZone.swift:31-69`) is a uniform lat/lon grid with `cos(lat)`
longitude scaling and out-of-box clamping.

### 4b. The measured bias finding, with provenance

Test file:
`/Users/mmarufov/conductor/workspaces/ravon-core/bucharest/Tests/RavonCoreTests/SwitchbackExperimentTests.swift`
(`SET`).

| Claim in `08` | Cite | Asserting test | What is asserted | Verdict |
|---|---|---|---|---|
| **20 seeds**, 12 couriers, 240 orders | `:28`, `:60` | — | No test uses 20 seeds. `SET:45-46` and `:82-83` use **seeds 1…12**; `SET:64-66` uses **seeds 1…8**. | **Not reproducible from the suite.** Every table in `08` is from an ad-hoc run at a seed count the tests do not use. |
| ground truth lift **+17.9 pts** | `:31` | **none** | `Report.groundTruthLiftPoints` is computed (`SwitchbackExperiment.swift:237-240`) but **no test ever reads it**. `SET` only calls `report.biasPoints(for:)` (`SET:30`), which returns the *difference*. | **Unasserted.** |
| 1×1: naive **22.7** / switchback **24.7** pts | `:64` | `SET:44` | `XCTAssertGreaterThan(unpartitioned, 10)` for switchback only (`SET:48-51`). Naive at 1×1 is never measured by a test. | **Weakly asserted (switchback), unasserted (naive).** |
| 2×2: naive **7.1** / switchback **8.7** | `:65` | `SET:63` | Only monotonicity: `coarse > medium > fine` (`SET:68-69`), seeds 1…8, switchback only. | **Unasserted numerically.** |
| 3×3: naive **2.4** / switchback **2.9** | `:66` | `SET:44`, `SET:81` | `partitioned < 6` (`SET:52-55`); `naive < 6` and `switchback < 6` (`SET:85-86`). | **Bounded, not pinned.** |
| "Roughly a **10×** reduction in experiment bias" | `:68` | `SET:44` | `XCTAssertLessThan(partitioned, unpartitioned / 2)` (`SET:56-59`) — i.e. **≥2×**, not 10×. | **Headline overstates the guard by 5×.** A regression from 10× to 2.1× passes. |
| honest negative result: naive ≈ switchback once zoned | `:76-78` | `SET:81` `test_switchbackAndNaiveAreComparableOnceZoned` | Both `< 6` and `max/min < 3.0` (`SET:88-91`). | **Properly asserted.** The most rigorously guarded claim in the doc — again, it is the *negative* result. |
| ground-truth lift **fell from +17.9 to +4.6** under 3×3 partitioning | `:89` | **none** | Nothing reads `groundTruthLiftPoints`. | **Unasserted. This is `08`'s "third finding, unprompted" (`:87`) and there is no test behind it at all.** |
| "`Sources/RavonCore/Dispatch/{SwitchbackExperiment,DispatchZone}.swift`, **14 tests**" | `:3` | — | `SwitchbackExperimentTests.swift` contains **7** `func test`. There is no other test file touching `SwitchbackExperiment` or `DispatchZone`. | **Wrong — 2× overstated.** `14` is almost certainly copied from `05:3`, where 14 is correct (7 `DST` + 7 `HST`). |
| "each zone's couriers matched only to that zone's orders" | `:55` | `SET:128` `test_zonedDispatcherKeepsAssignmentsWithinZone` | Cross-zone pair returns empty (`SET:142-145`). | **Correct.** |
| grid clamping | — | `SET:150` | Row/column in `0..<3` for a point at (89, 179). | **Correct.** |

### 4c. Does the Kotlin dispatch service need to preserve the experiment harness? **Yes — the docs are explicit.**

- `10-POLYGLOT-RESTRUCTURE.md:197`: "Dispatch service exposes `Assign`; **the simulator becomes
  its test harness.**"
- `11-KOTLIN-DECISION.md:92-95`: "**The dispatch simulator moves too.** It's the dispatch
  service's test harness, so it follows the code into Kotlin. That means porting ~1,000 lines of
  Swift — the Hungarian solver, cost model, simulator, and the brute-force verification tests.
  Mechanical, but a real day or two, and **the Swift version should be deleted rather than left
  to rot.**"
- `11:105-108`: dispatch is Phase 1 precisely because it has "**no database writes**".

So the harness is not optional, and the measured 1208 lines (not ~1,000) all move.

### 4d. The interface the Kotlin port must preserve

All in `/Users/mmarufov/conductor/workspaces/ravon-core/bucharest/Sources/RavonCore/Dispatch/`.

**The one abstraction everything hangs off** (`Dispatcher.swift:134-137`):

```swift
public protocol Dispatcher: Sendable {
    var name: String { get }
    func assign(couriers: [DispatchCourier], orders: [DispatchOrder], now: Date) -> [Assignment]
}
```

`GreedyDispatcher` (`:145`), `OptimalBatchDispatcher` (`:181`), `ZonedDispatcher`
(`DispatchZone.swift:90`) and `ExperimentDispatcher` (`SwitchbackExperiment.swift:103`) are all
just conformances. `ZonedDispatcher` and `ExperimentDispatcher` are **decorators** over
`any Dispatcher` — that composability is the whole reason the experiment study was cheap, and a
Kotlin port must keep it (a sealed class of concrete dispatchers would break it).

| Type / entry point | Cite | Shape |
|---|---|---|
| `DispatchCourier` | `Dispatcher.swift:4-19` | `id: UUID`, `location: GeoPoint`, `idleSince: Date`, `excludedOrderIDs: Set<UUID>` |
| `DispatchOrder` | `Dispatcher.swift:21-44` | `id`, `pickup: GeoPoint`, `dropoff: GeoPoint`, `readyAt: Date`, `createdAt: Date`, `excludedCourierIDs: Set<UUID>` |
| `Assignment` | `Dispatcher.swift:46-50` | `courierID`, `orderID`, `cost: Double` |
| `DispatchCostModel` | `Dispatcher.swift:61-88` | 5 knobs: `averageSpeedKmh=18`, `maxAssignmentRadiusKm=8`, `orderAgeCreditPerMinute=1.5`, `courierIdleCreditPerMinute=0.4`, `maxCreditMinutes=25`; `cost(courier:order:now:) -> Double` |
| `HungarianSolver` | `HungarianSolver.swift:12-` | `static let forbidden = 1e9`; `solve(cost: [[Double]]) -> [Int?]`; `totalCost(of:cost:)` |
| `GeoPoint.distanceKm(to:)` | `Geo.swift:19-29` | Haversine, `earthRadiusKm = 6371.0088` |
| `DispatchZone` / `ZoneGrid` | `DispatchZone.swift:13-69` | `zone(for: GeoPoint) -> DispatchZone`, `allZones`, `divisions` clamped to ≥1 |
| `ZonedDispatcher(base:grid:)` | `DispatchZone.swift:90-115` | decorator |
| `ExperimentArm` | `SwitchbackExperiment.swift:22-25` | `.control` / `.treatment` |
| `ArmAssignment` | `SwitchbackExperiment.swift:29-99` | `arm(for: DispatchOrder)` **and** `arm(for: MarketplaceSimulator.OrderRecord)`; factories `.naiveOrderLevel(salt:)`, `.switchback(grid:blockMinutes:epoch:salt:)` |
| `ExperimentDispatcher(control:treatment:assignment:)` | `SwitchbackExperiment.swift:103-147` | decorator; alternates arm priority by tick parity |
| `SwitchbackExperiment.run(config:control:treatment:zoneDivisions:blockMinutes:) -> Report` | `SwitchbackExperiment.swift:227-262` | the whole study |
| `Report` | `SwitchbackExperiment.swift:174-206` | `groundTruthLiftPoints`, `groundTruthDeliveryDeltaMinutes`, `designs: [DesignResult]`, `biasPoints(for:) -> Double?`, `summary: String` |
| `MarketplaceSimulator.Config` | `MarketplaceSimulator.swift:85-120` | `seed: UInt64`, `courierCount`, `orderCount`, `durationMinutes`, `dispatchIntervalSeconds=30`, `cityCenter=38.5598/68.7870`, `cityRadiusKm=6`, `prepMinutesRange=8...25`, `latent` |
| `MarketplaceSimulator.OrderRecord` | `MarketplaceSimulator.swift:122-` | per-order outcome; required because "aggregate numbers cannot answer 'what happened to the treated orders specifically'" |

**Three properties the port must preserve or the numbers stop meaning anything:**

1. **Bit-identical determinism from `seed`.** `05:54-57` and `SET`/`DST` reproducibility tests
   rest on it. The simulator uses seeded SplitMix64. A JVM port that uses `java.util.Random`, or
   that differs in floating-point summation order, will produce *different* numbers — at which
   point every table in `05` and `08` must be re-measured, not translated. Budget for
   re-measuring, not for porting numbers.
2. **`arm(for:)` must be a pure function of the order**, re-derivable after the run
   (`SwitchbackExperiment.swift:28`, asserted `SET:118` `test_armAssignmentIsDeterministic`).
   This is what allows per-arm metrics to be computed post hoc from `orderRecords` instead of
   being threaded through the simulation.
3. **`forbidden = 1e9` sentinel semantics**, not "very expensive": `OptimalBatchDispatcher`
   filters `cost < forbidden` *after* solving (`Dispatcher.swift:203`), and `HungarianSolver`
   returns `nil` for such rows. Asserted at `HST:117` and `DST:102`/`DST:120`. A Kotlin port using
   `Double.MAX_VALUE` or `null` costs must reproduce "leaving an order unassigned beats
   dispatching a banned courier" (`05:49-50`).

**One port-fidelity hazard worth writing down.** `ZonedDispatcher.assign` iterates
`for (zone, zoneOrders) in ordersByZone` over a Swift `Dictionary`
(`DispatchZone.swift:105-113`), whose iteration order is not stable across processes. Today this
is harmless because zones partition couriers and orders *disjointly*, so the resulting
`[Assignment]` set is identical and only its order varies. But `test_simulationIsReproducible`
(`DST:90`) runs both trials **inside the same process**, so it cannot detect cross-process
order instability — and the suite's entire claim is reproducibility. A Kotlin port must not
assume `Assignment` list order carries meaning, and if zones are ever allowed to share couriers
(the obvious next feature: cross-zone spillover) this becomes real nondeterminism with no test
watching it.

**One cosmetic dead operation.** `ArmAssignment.hashToArm` ends with
`hash.multipliedReportingOverflow(by: 1).partialValue % 2` (`SwitchbackExperiment.swift:58`) —
multiplying by 1 is a no-op; it is just `hash % 2`. Not a bug, but it will read as confusion in a
portfolio review, and the port should drop it.

---

## 5. `migrations/README.md` — the stated policy, and whether it survives Flyway

### 5a. The stated policy, verbatim

`migrations/README.md:3-4`:

> Apply in numeric order against the Supabase project (`milan` / production).
> All migrations are idempotent (use `IF NOT EXISTS` and `CREATE OR REPLACE`).

Application mechanism, `migrations/README.md:88-94`:

> ```
> mcp__supabase__apply_migration  name="08_courier_heartbeat..."  query=<SQL>
> ```
> Or paste each file into the SQL editor in order.

Plus three policy elements that are not migrations at all:

1. **A dashboard-only appendix** (`:40-86`): email provider config, `Confirm email = ON`,
   `Secure email change = ON`, OTP expiry 600s, OTP length 6, two Russian HTML email templates
   using `{{ .Token }}` instead of `{{ .ConfirmationURL }}`, password minimum length 8, rate
   limits left at defaults. Stated reason: "These cannot be expressed as migrations."
2. **Manual verification queries** (`:96-131`): six hand-run SQL snippets (A–F) that check tier
   values, the escalation ladder, heartbeat/ETA, 3-strike suspension, chat RLS grace windows,
   and photo proof. These are the *only* tests the SQL layer has.
3. **Post-migration hardening applied out-of-band** (`:133-141`): "Functions added without
   explicit `search_path` at create time (helpers like `earnings_tier_for_cancel`,
   `set_chat_sender_role`) were tightened **post-migration** with `ALTER FUNCTION … SET
   search_path = public`." That `ALTER` is in no migration file.

### 5b. Is the idempotency claim true? Yes, in substance

Verified across all 19 files:

- `CREATE TABLE` — 1 occurrence, `09_…:39`, and it is `CREATE TABLE IF NOT EXISTS`. Zero
  non-guarded `CREATE TABLE`.
- `ALTER TYPE … ADD VALUE` — 2 occurrences (`06_…:15`, `09_…:11`), both wrapped in
  `DO $$ … IF NOT EXISTS (SELECT 1 FROM pg_enum …) … END $$`. Idempotent.
- `CREATE POLICY` — 8 occurrences across 3 files (`01_…` ×4, `09_…` ×1, `15_…` ×3), each
  preceded by a matching `DROP POLICY IF EXISTS` (counts match exactly per file: 4/4, 1/1, 3/3).
  Idempotent by drop-then-create, which is *not* the `IF NOT EXISTS` mechanism the README names
  — the README's parenthetical is imprecise, the property holds.
- Constraints follow the same pattern (`09_…`: `DROP CONSTRAINT IF EXISTS` then `ADD CONSTRAINT`).

### 5c. Does the policy survive a Flyway-based Kotlin service?

**First, a correction to the brief: Flyway is not proposed anywhere.** `grep -rIn
'Flyway\|flyway\|Liquibase'` over `.context/` returns **zero hits**. `10-POLYGLOT-RESTRUCTURE.md:76`
proposes a `db/migrations/` directory with the scope comment "SQL: schema, RLS, constraints only"
and says nothing about a runner, a naming convention, a checksum policy, or who owns the
`schema_history` table. So the answer below is about *any* checksummed migration runner, of which
Flyway is the canonical JVM example.

Five collisions, in descending severity:

1. **Idempotency and checksumming are opposed design philosophies, and the current files fail
   the checksum contract on contact.** A checksummed runner applies each versioned migration
   **exactly once** and then *validates the file's checksum forever*. The current corpus was
   authored for repeated hand-application against a live DB, which is why it is idempotent — and
   why `README:133-141` records hardening applied *after* the files, out of band. Under Flyway,
   `V08__…sql` would be recorded as applied with a checksum, and the out-of-band
   `ALTER FUNCTION … SET search_path` would have to become `V20__harden_search_path.sql` or it
   simply does not exist in any environment built from the repo. **The out-of-band changes are
   the part of the policy that does not survive at all.** Idempotency itself survives harmlessly
   (a runner just never re-runs the file), but it stops being a *requirement*, and the discipline
   that produced it stops being enforced by anything.
2. **There is no baseline to migrate from, so `V1` does not exist.** Verified: the corpus
   contains exactly **one** `CREATE TABLE` (`courier_cancellation_log`). 14 of the 15 tables Swift
   touches, and all 6 enums, were dashboard-created (`12-BACKEND-INVENTORY.md:21`, `:29-32` —
   independently confirmed here by the `CREATE TABLE` grep and by `06`/`09` doing
   `ALTER TYPE order_status ADD VALUE` with no `CREATE TYPE` anywhere). A checksummed runner needs
   a real `V1__baseline.sql` that creates the world. **That file has to be written from scratch,
   reconstructed from migrations ∪ Swift `Codable` models ∪ Swift call sites** — which is what
   `scripts/schema_drift.py` exists for, and which currently reports 0 drift with **15 unverified
   findings**. Writing `V1` is the single largest piece of unscoped work implied by
   `db/migrations/`, and neither `10` nor `migrations/README.md` mentions it.
3. **The "SQL: schema, RLS, constraints only" scope is a deletion order for 28 of 34 functions.**
   `12-BACKEND-INVENTORY.md:40-62` allocates 34 SQL functions: 13 → `services/order`, 4 →
   `services/dispatch`, 4 → `services/ledger`, 4 → Kotlin scheduled workers, 3 →
   `services/merchant`, and **6 stay in SQL**. So `db/migrations/` under the new scope keeps
   `handle_new_user`, `profiles_block_role_change`, `set_chat_sender_role`,
   `sync_order_delivery_mode_from_address`, `generate_verification_code`, and the orderability
   trio — and drops everything else. The current `migrations/README.md`, which is organised
   entirely around those RPCs ("Umbrella II — courier hardening" is nothing else), becomes
   obsolete as a document, not just as a runbook.
4. **The dashboard-only appendix has no home.** `README:40-86` is six pages of auth
   configuration that is, by its own admission, not expressible as SQL. A migration runner cannot
   hold it. Under a Kotlin service this becomes Terraform/Supabase-CLI config or it stays a
   manual runbook — and if it stays manual, "one repo makes skew structurally impossible"
   (`10:85`) is false for the auth layer, which is precisely the layer `11:47` says stays on
   Supabase.
5. **`pg_cron` jobs live inside migrations and are scheduled to be deleted.** Five named cron
   jobs are registered by the SQL: `auto_resume_accepting_orders` (`05_…:47`, `*/5 * * * *`),
   `activate_scheduled_orders` (`06_…:111`, `* * * * *`), `purge_soft_deleted_menu` (`07_…:6`,
   `0 3 * * *`), `courier_escalation_ladder` (`14_…:121`, `* * * * *`),
   `mark_no_show_deliveries` (`16_…:146`, `* * * * *`). `12-BACKEND-INVENTORY.md:18` says there
   are **3** — see §6, C-7. Whichever count is right, scheduling is *side-effecting
   infrastructure* being created by files that a checksummed runner will treat as immutable
   history, while `12:52-53` plans to replace the schedulers with Kotlin workers. Someone has to
   write the `cron.unschedule` migration, and nothing currently anticipates it.

**One more policy detail that must not survive, for a different reason.**
`migrations/README.md:3` names the target as "the Supabase project (`milan` / production)".
`CLAUDE.md`/`AGENTS.md` require that "The Supabase project URL and keys must stay out of tracked
docs and source." A project alias is not a URL or a key, so this is not a violation — but it is a
tracked doc naming production infrastructure, and the named infrastructure **does not exist**
(orchestrator-established: no Ravon Supabase project; `<dead-ravon-project-ref>.supabase.co` =
NXDOMAIN). `milan` is also the name of the Conductor workspace for the merchant app
(`workspaces/ravon-merchant/milan`), so the reference is ambiguous on its face.

---

## 6. Contradiction ledger

Every contradiction I can substantiate with two citations. `[doc↔doc]`, `[doc↔repo]`.

### C-1 `[doc↔doc]` — Kotlin/gRPC is simultaneously refused and adopted. **The central one.**

- `02-TARGET-ARCHITECTURE.md:149` — under the heading **"Refuse — wrong scale, actively harmful
  here"**: "Kotlin/gRPC microservices | Supabase Postgres + RPCs *is* the right backend for one
  developer. Microservices trade simplicity for team parallelism you don't have."
- `10-POLYGLOT-RESTRUCTURE.md:24`, `:64-68` — "Kotlin + gRPC → backend services (dispatch, order,
  ledger, fraud)" with four service directories; `11-KOTLIN-DECISION.md:3` — "Short answer:
  **yes, but as an extraction, not a rewrite.**"

Neither `10` nor `11` cites, quotes, or overrules `02`. `02` is 11 hours older by mtime
(`02`: Sep 15 23:59; `10`: Sep 16 12:45; `11`: Sep 16 13:04), so chronology implies `11`
supersedes — but nothing in the corpus *says* so, and `02` is still the doc titled "target
architecture". **`02`'s Refuse table needs a superseded-by banner or the corpus has no
architecture.**

### C-2 `[doc↔doc]` — "There is one service" vs seven deployables

- `02-TARGET-ARCHITECTURE.md:155` — "Service mesh | There is one service."
- `10-POLYGLOT-RESTRUCTURE.md:64-73` — 4 Kotlin services (`dispatch`, `order`, `ledger`, `fraud`)
  + 3 Python packages (`eta`, `forecast`, `anomaly`).

### C-3 `[doc↔doc]` — `pg_cron` is sufficient vs `pg_cron` is replaced

- `02-TARGET-ARCHITECTURE.md:151` — "Cadence workflow engine | `pg_cron` already does the job;
  the escalation ladder is written."
- `12-BACKEND-INVENTORY.md:52-53` — "**→ Kotlin scheduled workers, replacing `pg_cron` (4):**
  `run_courier_escalation_ladder`, `mark_no_show_deliveries`, `activate_scheduled_orders`,
  `activate_scheduled_order`". Compounded by `10-POLYGLOT-RESTRUCTURE.md:166`, which cites
  Cadence approvingly ("Mirrors Cadence's 'free locks via workflow ID'") in the same corpus that
  refused it.

### C-4 `[doc↔doc]` — the same DoorDash precedent, read two opposite ways

- `02-TARGET-ARCHITECTURE.md:162-163` — "DoorDash builds two distinctly branded apps from one
  codebase with ~90% shared code and **separate targets**".
- `10-POLYGLOT-RESTRUCTURE.md:90` — "They **rejected separate targets** and xcconfig; chose a
  shared library + DI, ~90% shared". Echoed at `09-BUILD-MENU.md:226`.

Same source, same "~90% shared", contradictory conclusion about targets. This one matters
because it decides whether Phase 0 produces three Xcode targets or three thin app wrappers over
a library — a structural fork.

### C-5 `[doc↔doc]` — Postgres is the authorization gate vs Kotlin is

- `02-TARGET-ARCHITECTURE.md:135-143` (the Adopt table) + `README.md:288` ("**Authorization lives
  in Postgres**, not in Swift… the authoritative checks are RLS policies and `SECURITY DEFINER`
  RPCs") + `CLAUDE.md` ("Backend security verification must happen against the actual Supabase
  policies and grants").
- `11-KOTLIN-DECISION.md:75-79` — "The service connects to Postgres as its **own role** — not as
  the end user… **Kotlin becomes the authorization gate for writes**"; `10:211-213` — "RLS stays
  as defence-in-depth, the service is the primary gate."

### C-6 `[doc↔repo]` — `ServiceError` case count is wrong

- `02-TARGET-ARCHITECTURE.md:35` — "`ServiceError` has **24 cases**".
- Repo: **33 cases**. `Sources/RavonCore/Services/SupabaseService.swift:4-38`, counted
  (`awk 'NR>=4 && NR<=39' … | grep -cE '^\s+case ' → 33`). 21 in the original block (`:5-25`) plus
  12 under the "Umbrella II — courier hardening" comment (`:27-38`).

### C-7 `[doc↔repo]` — `pg_cron` job count is wrong (3 claimed, 5 in the files)

- `12-BACKEND-INVENTORY.md:18` — "`pg_cron` jobs | **3** | restaurant accepting-orders flip
  (5 min), `courier_escalation_ladder` (1 min), `mark_no_show_deliveries` (1 min)".
- Repo: **5** named jobs. `05_set_accepting_orders_with_until.sql:47` `auto_resume_accepting_orders`
  `*/5 * * * *`; `06_scheduled_orders.sql:111` `activate_scheduled_orders` `* * * * *`;
  `07_soft_delete_purge_cron.sql:6` `purge_soft_deleted_menu` `0 3 * * *`;
  `14_courier_escalation_ladder_cron.sql:121` `courier_escalation_ladder` `* * * * *`;
  `16_no_show_and_restaurant_delay.sql:146` `mark_no_show_deliveries` `* * * * *`.
  `12`'s own list at `:52-53` includes `activate_scheduled_orders` as a scheduled worker, so the
  doc contradicts itself two paragraphs apart. `migrations/README.md:135-136` also only asks the
  operator to verify **two** of the five.

### C-8 `[doc↔repo]` — the iOS 26.2 divergence is fleet-wide, not consumer-only

- `02-TARGET-ARCHITECTURE.md:92` — "**Consumer's** deployment target is iOS 26.2, not the iOS 17
  CLAUDE.md claims." `10:91` repeats the framing as "the iOS 26.2 vs 17 split".
- Repo: **all three apps** are `IPHONEOS_DEPLOYMENT_TARGET = 26.2`, in both the `repos/` and
  `workspaces/` checkouts (six `project.pbxproj` files, single unique value each). The divergence
  is apps-vs-package (`Package.swift` declares `.iOS(.v17)`), not app-vs-app — which invalidates
  XcodeGen's stated justification. See §1b.

### C-9 `[doc↔repo]` — `README.md` test count is three generations stale

- `README.md:21` (badge "Tests-73 unit"), `:154` ("73 unit tests across 22 suites"), `:293`
  ("**73 unit tests across 22 suites**").
- Repo: **163** tests across **28** files on macOS (orchestrator-verified: 102 XCTest + 61
  swift-testing). `05-DISPATCH-ENGINE.md:106` says **154**. So the corpus asserts 73, 154, and
  163 for the same quantity. `README.md` is the tracked, public-facing one and is the worst.

### C-10 `[doc↔repo]` — `README.md` and `CLAUDE.md` both claim iOS 17+ as a platform fact

- `README.md:18` (badge "Platforms-iOS 17+ | macOS 14+"), `:68` ("native SwiftUI, iOS 17+"),
  `:176` (requirements table "iOS | 17.0+"); `CLAUDE.md` Tech Stack ("iOS 17+ / macOS 14+").
- Repo: `Package.swift` does declare `.iOS(.v17)`, so the *package* claim is true; every
  *consumer* of it requires 26.2. A reader of `README.md` will conclude the apps run on iOS 17.
  `02:93` states the consequence plainly: "In Tajikistan that is approximately nobody."

### C-11 `[doc↔repo]` — `README.md` describes the fleet's dependency topology as healthy

- `README.md:181-193` — shows the app integration as `.package(url: …, from: "1.0.0")`, a
  semver range.
- Repo: **no tags exist** (orchestrator-established), so `from: "1.0.0"` cannot resolve. The
  actual requirements are `kind = branch` — `mmarufov/auth-overhaul` in the workspace branches,
  `main` in `repos/ravon-merchant/…/project.pbxproj:367-370` and
  `repos/ravon-courier/…/project.pbxproj:367-370`. `README.md:179` also states
  `supabase-swift (2.41+)` while the fleet resolves 2.41.1 / 2.42.0 / 2.43.1 / 2.46.0.

### C-12 `[doc↔repo]` — "never called anywhere in RavonCore" is technically true and practically misleading

- `02-TARGET-ARCHITECTURE.md:35-38` — the `DETAIL`-jsonb decoder at `SupabaseService.swift:90`
  "is **never called anywhere in RavonCore**"; `02:107` restates it as "`ServiceError.from`
  exists, is never called".
- Repo: `ServiceError.from(serverError:)` has **three** call sites, all in
  `Tests/RavonCoreTests/CourierCancellationTests.swift:55, 65, 74`, and **zero** in
  `Sources/`. So the claim is correct for the `RavonCore` target and wrong as written for the
  package. The precise defect — and the one that should be in the doc, because it is a sharper
  indictment — is **"unit-tested but never wired into the service layer."** Tested dead code is
  worse than untested dead code: the tests create the impression of coverage.

### C-13 `[doc↔doc]` — two different, unreconciled "Phase 0" definitions

- `02-TARGET-ARCHITECTURE.md:178-182` — 3 items, including "Add a test target and wire
  PreviewSnapshots + PropertyTestingKit".
- `10-POLYGLOT-RESTRUCTURE.md:187-189` / `11-KOTLIN-DECISION.md:101-103` — 5 items, dropping the
  test-target item and adding `proto/` + the `Dispatch/` move. Full comparison in §2.

### C-14 `[doc↔repo]` — `08`'s test count is 2× the reality

- `08-EXPERIMENT-DESIGN-STUDY.md:3` — "`Sources/RavonCore/Dispatch/{SwitchbackExperiment,DispatchZone}.swift`,
  **14 tests**".
- Repo: `Tests/RavonCoreTests/SwitchbackExperimentTests.swift` contains **7** `func test`
  (`:44, :63, :81, :95, :118, :128, :150`). No other file references `SwitchbackExperiment`,
  `ZoneGrid`, `ZonedDispatcher` or `ArmAssignment`. The 14 is `05:3`'s correct number (7 `DST` +
  7 `HST`) copied into the wrong doc.

### C-15 `[doc↔repo]` — `08`'s headline "10×" is guarded at 2×; `05`'s "42%" is guarded at 20%

- `08:68` "Roughly a **10×** reduction in experiment bias" vs
  `SwitchbackExperimentTests.swift:56-59` `XCTAssertLessThan(partitioned, unpartitioned / 2)`.
- `05:65` "**+42.2% mean**" vs `DispatchSimulationTests.swift:48`
  `XCTAssertGreaterThan(mean, 0.20)`.

Both docs claim the numbers are "pinned as a test so nobody tunes it for the wrong regime"
(`05:124`) / "pinned so they stay true" (`SwitchbackExperimentTests.swift:4`). The tests pin
*order-of-magnitude floors*, not the numbers. That is a defensible engineering choice — the
comments at `DST:35-36` say so explicitly ("asserted well below that so cost-model tuning does
not cause spurious failures") — but the prose overstates what is protected, and `05:66`'s
delivery-time result and `08:89`'s ground-truth-lift result are protected by **nothing at all**.

### C-16 `[doc↔repo]` — `08`'s tables report 20 seeds; no test uses 20 seeds

- `08:28`, `:60` — "20 seeds, 12 couriers, 240 orders".
- `SwitchbackExperimentTests.swift:45-46, :82-83` use `seeds: 1...12`; `:64-66` uses `1...8`.

### C-17 `[doc↔repo]` — `migrations/README.md` targets a project that does not exist

- `migrations/README.md:3` — "Apply in numeric order against the Supabase project (`milan` /
  production)"; `:42-43` — "Apply them once in **Supabase → Authentication** for the production
  project."
- Orchestrator-established: no Ravon Supabase project exists in the account;
  `<dead-ravon-project-ref>.supabase.co` is NXDOMAIN. `12-BACKEND-INVENTORY.md:5` says so in the
  same corpus ("the backend is deleted, so this is a rebuild, not a migration"), and `02:83`
  agrees. `migrations/README.md` was never updated and still reads as a live runbook. It is also
  the corpus's only remaining description of *how* to apply schema, so a reader follows it into
  a dead end.

### C-18 `[doc↔doc]` — `05` and `10` both give an unqualified travel number the test does not defend

- `05:77` "on the same fuel"; `10:120-121` "**−45% delivery time on 1.4% less courier travel
  across 30 seeds**".
- `DispatchSimulationTests.swift:53-63` asserts travel only over **seeds 1…10** and only that
  optimal stays under greedy **× 1.10**. Neither the 30-seed scope nor the sign of the travel
  delta is asserted. `10:120` compounds `05:67` by attaching "across 30 seeds" to the travel
  figure, which was measured over 10.

### C-19 `[doc↔repo]` — `README.md` claims the package is credential-free and drift-free; both are looser than stated

- `README.md:78` — "**One core, three apps — no drift.** … A schema change is made in one place
  and every app picks it up."
- Repo: four resolved `supabase-swift` versions and two different `ravon-core` revisions across
  six checkouts (§1e table). `README.md:44` — "The three apps live in their own repositories;
  this is their spine" — is the exact topology `10:85` calls structurally broken. The README and
  the architecture docs describe the same fact as a feature and as the root cause.

---

## 7. Corrections to the brief (loud, with evidence)

1. **"Flyway-based Kotlin service" is not in any doc.** Zero hits for `Flyway`/`flyway`/
   `Liquibase` across `.context/`. `10-POLYGLOT-RESTRUCTURE.md:76` proposes only a
   `db/migrations/` directory with no runner named. Treat §5c as generic-checksummed-runner
   analysis, not as a critique of a stated plan.
2. **`05-DISPATCH-ENGINE.md`'s "4 files" and "93 XCTest / 154 total" are not errors — they are
   correct-as-of-writing.** `05` mtime is Sep 16 00:38; `DispatchZone.swift` (11:29) and
   `SwitchbackExperiment.swift` (11:28) postdate it, as do `SwitchbackExperimentTests` (11:30)
   and `SchemaDriftToolTests` (11:43). 102 − 7 − 2 = 93 reconciles exactly. `08`'s "14 tests"
   (C-14) *is* a real error.
3. **The suite size is platform-dependent and the "163" figure is the macOS number.** 113 `func
   test` are declared; 11 sit behind `#if canImport(UIKit)` (`EmailValidatorTests.swift:1`,
   `OTPCooldownTests.swift:1`, `PasswordStrengthTests.swift:1`) and compile out on macOS. So
   macOS = 102 + 61 = **163**; iOS = 113 + 61 = **174**. Any doc that states one number without
   the platform is ambiguous.
4. **The dangling-pin framing understates the problem.** `a1e9d6c8` is what a stale
   `Package.resolved` remembers; the *declared* requirement in `repos/ravon-merchant` and
   `repos/ravon-courier` is `kind = branch; branch = main` (`project.pbxproj:367-370`), and in
   `repos/ravon-consumer` there is **no `ravon-core` package reference at all** (HEAD `424e9ad`
   "Remove broken RavonCore gitlink"). A branch requirement is strictly less reproducible than a
   revision pin.
5. **The app code is not on `main` in any of the three app repos.** `import RavonCore` file
   counts: `repos/` main = 0 / 1 / 1 (consumer/merchant/courier); `workspaces/` feature branches
   = 49 / 22 / 27. "Consolidate the three app repos" therefore requires a canonical-branch
   decision per repo before any `git` mechanism is chosen — a step no doc mentions.
6. **There are four Supabase SDK versions in play, not three.** `02:89`'s 2.41.1 / 2.42.0 /
   2.43.1 is exactly right for the workspace branches; `repos/` main resolves **2.46.0** in all
   three.
7. **`02:35`'s "24 cases" is wrong; `ServiceError` has 33** (`SupabaseService.swift:4-38`).
8. **`12:18`'s "3 `pg_cron` jobs" is wrong; the migrations register 5** (C-7).
9. **`02:92`'s iOS-26.2 finding is scoped to consumer; it is fleet-wide** (C-8), which also
   removes XcodeGen's stated justification (§1b).
10. **`02:35`/`02:107`'s "never called" needs the precise wording** "unit-tested but never wired
    into the service layer" — three test call sites at
    `CourierCancellationTests.swift:55, 65, 74`, zero in `Sources/` (C-12).

---

## 8. Open questions and UNKNOWNs

1. **Which Phase 0 is canonical — `02`'s or `10`/`11`'s?** The corpus has two, with different
   item lists, and no supersession marker (C-1, C-13). This is the single blocking ambiguity.
2. **Monorepo history: preserve or abandon?** UNKNOWN — no doc states a position, and the choice
   is irreversible. Note that the two largest new bodies of code
   (`Sources/RavonCore/Dispatch/`, `scripts/`) are **untracked**, so they have no history to
   preserve either way.
3. **Which branch of each app repo is canonical?** UNKNOWN — needs a decision from the author,
   not introspection. The workspace branches (`kolkata-v1`, `milan-v1`, `buffalo-v1`) hold the
   app code; `main` holds skeletons.
4. **Do `.github/` workflows already contain a `proto`/schema gate?** `.github/` is untracked and
   outside my read brief; not inspected.
5. **Will the ported Kotlin simulator reproduce the published numbers?** UNKNOWN and probably
   **no** — the numbers depend on seeded SplitMix64 draws and floating-point summation order.
   Budget for **re-measuring** `05`'s and `08`'s tables in Kotlin, and for updating both docs.
   This should be an explicit Phase 1 deliverable, because `05` and `08` are the two most
   quotable documents in the corpus.
6. **What is the `V1__baseline.sql`?** UNKNOWN until the schema is reconstructed. Current best
   source is migrations ∪ Swift models ∪ Swift call sites; `scripts/schema_drift.py` reports 0
   drift with **15 unverified findings**, so 15 questions are open by construction.
7. **Where does the dashboard-only auth config live after Phase 0?** UNKNOWN — it cannot go in a
   migration (`migrations/README.md:42-43`) and `10`'s layout has no slot for it.
8. **Credentials hardcoded "in three places, in three different shapes"** (`02:94`) — not
   re-verified here; I deliberately did not grep app repos for key material.
9. **`ravonGray`'s value** is undocumented (`README.md:278` shows "—"), which matters if
   "semantic theming" is to be specified rather than named.

---

## 9. Bottom line for Phase 0

The concrete Phase 0 spec in `10-POLYGLOT-RESTRUCTURE.md` is **five bullet points and a
directory tree** (`:57-79`, `:187-189`). Of the five:

- **"One repo"** — the only irreversible step, and the only one with no stated mechanism. Blocked
  on two decisions nobody has recorded (history preservation; canonical branch per app repo).
  Harder than the doc thinks, because the app code is not on `main` anywhere.
- **"`proto/` with a CI compatibility gate"** — coherent, well-precedented, unspecified in
  detail. No `.proto` exists yet.
- **"Move `Dispatch/` → `services/dispatch`"** — the cheapest item, not the riskiest:
  `Dispatch/` has zero internal callers and is untracked. But it is a *language port*, and the
  published numbers will not survive it unchanged.
- **"XcodeGen"** — justified by a divergence that does not exist (all three apps are 26.2). Keep
  it if you want diffable settings; change the reason.
- **"Thin app wrappers with semantic theming"** — the weakest item. Its only concrete example
  (`₽`/`сум`/`сомони`) is a `Money`-type problem, not a theming problem, and its DoorDash
  precedent is read in the opposite direction by `02:162-163`.

And the one thing Phase 0 must not inherit uncritically: **`02-TARGET-ARCHITECTURE.md` still
refuses, in writing, the entire architecture that `10` and `11` propose.** Until `02:145-155` is
amended or explicitly superseded, "the target architecture" is two mutually exclusive documents.
