# Ravon — working rules for coding agents

Ravon is a delivery platform: three iOS apps (consumer, merchant, courier, each in its own
repository) built on the shared Swift package in this repository, plus a Kotlin dispatch
service, PostgreSQL schema and ledger components, and offline ML. `README.md` is the
overview. This file is the rules.

## Where things live

| Path | What it is | How it is checked |
| :--- | :--- | :--- |
| `Package.swift`, `Sources/RavonCore/`, `Tests/RavonCoreTests/` | Shared Swift package used by all three apps | `swift build --build-tests && swift test` |
| `services/` | Gradle root: Kotlin dispatch engine (`dispatch/`) and Armeria gRPC server (`server/`), deployed to Fly.io | `cd services && ./gradlew :dispatch:test :server:test` (JDK 22+) |
| `proto/` | Protobuf contract for the service | `buf lint proto`, plus a breaking-change check against `main` |
| `db/schema/` | The database definition: tables, lifecycle trigger, RPCs, RLS, grants | [`db/schema/README.md`](db/schema/README.md#apply) |
| `db/ledger/` | Double-entry ledger and its invariant, idempotency and crash tests | [`db/ledger/README.md`](db/ledger/README.md#run-it) |
| `db/temporal_payout/` | Payout saga, hand-built worker vs Temporal, and the lost-reply experiment | [`db/temporal_payout/README.md`](db/temporal_payout/README.md) |
| `db/rush/` | Concurrent-checkout load harness | [`db/rush/README.md`](db/rush/README.md#run-it) |
| `db/migrations/` | Historical migrations of the deleted Supabase project. Read-only | not applied anywhere |
| `ml/` | Offline probabilistic ETA and anomaly detection (Python) | `cd ml && python -m pytest` |
| `scripts/` | CI gates: schema drift, lifecycle parity, ML report drift, secret scan, markdown links | standard-library Python 3 |
| `docs/` | ADRs, studies, dated results and research notes | [`docs/README.md`](docs/README.md) |

`.github/workflows/ci.yml` is the source of truth for how each component is built and
checked. Run the matching job's commands before calling a change done.

## Layout rules

- `Package.swift` stays at the repository root. The apps depend on this repository by URL.
- Test fixtures live next to the tests that read them.
- `.context/` is local scratch and is gitignored. Tracked files must not link into it,
  because no reader can follow the link.
- Relative links in markdown must resolve. `scripts/check_links.py` enforces this in CI.

## Swift package

RavonCore is the model and service layer of each app's MVVM stack, plus the screens all
three apps share.

- `Models/`: `Codable`, `Sendable` value types and pure domain logic, such as
  `OrderLifecycle`, `CartValidation` and `RestaurantHours`. No networking.
- `Services/`: `@MainActor` singletons with `.shared`. `AuthService` owns the
  `SupabaseClient`, and the other services reach it through
  `AuthService.shared.supabaseClient`. `SupabaseService` holds the database queries
  and RPCs, one extension per domain in `SupabaseService+<Domain>.swift`; a new
  method goes in the file for its domain. Its errors are `ServiceError`.
- `UI/`: `Theme.swift` (brand colours, `CardStyle`, `PressableButtonStyle`,
  `RavonPrimaryButton`, `RavonTextField`) and shared flows. A flow is one
  `ObservableObject` view model plus the views it drives, for example
  `AuthFlowViewModel` and `RavonAuthFlow`. View models take their services through
  `init`, defaulting to `.shared`.
- Apps call `RavonCore.configure(supabaseURL:supabaseAnonKey:)` once at launch, before
  any service is used.

Rules:

- Everything the apps use must be `public`. Types should be `Sendable` where possible.
- UIKit-dependent code must be wrapped in `#if canImport(UIKit)`, because the package
  also builds and tests on macOS.
- Screens and view models used by only one app belong in that app's repository.

## Database

`db/schema/` is the definition of the database. `db/migrations/` records what the
deleted Supabase project was patched with. It is not a rebuild source, so never apply it
or treat it as the schema. Swift `CodingKeys` must match the columns
(`scripts/schema_drift.py`), and the order lifecycle in `OrderLifecycle.swift` must
match `order_transitions` edge for edge (`scripts/lifecycle_parity.py`).

## Supabase config and security

- The Supabase project URL and keys must stay out of tracked docs and source.
- All 3 apps use the same Supabase project. Each app provides its own credentials via
  `RavonCore.configure()` at launch.
- Treat the anon key as public client config, not a secret. Any policy or RPC reachable
  with anon must be safe against direct API access outside the app.
- Never commit or ship a `service_role` key. It must never appear in client code, mobile
  binaries, tracked docs, or repo config, including private repos.
- Backend security verification must happen against the actual Supabase policies and
  grants, not just the Swift client. Local security reports in `.gstack/security-reports/`
  have previously flagged critical issues around anon-callable SECURITY DEFINER RPCs and
  over-broad UPDATE policies. `db/schema/invariants.sql` asserts the fixes in CI.

## Docs and numbers

- Every number in `README.md` and `docs/` must be reproducible from this repository.
  Several are enforced: `scripts/ml_report_drift.py`,
  `db/ledger/tests/test_docs_are_honest.py`, and the ledger kill-count gate.
- ADRs are not rewritten when a decision changes. A new ADR supersedes the old one, and
  the old one's status points at it. Keep `docs/adr/README.md` in sync.
- Dated results, pre-registrations, findings and `docs/research/` are point-in-time
  records. Keep their numbers and claims. When code they cite moves, update the pointer
  or pin it to the commit they describe.

## Commit messages

Use `type: description` format (feat, fix, refactor, chore, etc).

## Design

- Brand color: Ravon Red `#FF3008`
- Dark palette: ravonDark `#1A1A2E`
- UI language: Russian (Cyrillic)
