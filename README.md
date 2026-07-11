<!--
  Drop a logo here to complete the header (the reference repos lead with one):
  put the file at docs/logo.png and uncomment the block below.

  <p align="center">
    <img src="docs/logo.png" alt="Ravon" width="140" />
  </p>
-->

<h1 align="center">Ravon</h1>

<p align="center">
  <em>A three-sided food-delivery platform for Tajikistan — consumer, merchant, and courier apps sharing one native Swift core, wired to a single <a href="https://supabase.com">Supabase</a> backend with realtime order tracking, on-device battery-aware location streaming, and DoorDash-style email-OTP auth.</em>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-5.9%2B-orange.svg?logo=swift" alt="Swift 5.9+" />
  <img src="https://img.shields.io/badge/Platforms-iOS%2017%2B%20%7C%20macOS%2014%2B-blue.svg" alt="Platforms" />
  <img src="https://img.shields.io/badge/SwiftPM-compatible-brightgreen.svg?logo=swift" alt="SwiftPM" />
  <img src="https://img.shields.io/badge/Backend-Supabase-3ECF8E.svg?logo=supabase" alt="Supabase" />
  <img src="https://img.shields.io/badge/Tests-73%20unit-success.svg" alt="73 tests" />
</p>

<!--
  Screenshot showcase (mirrors the reference repos). Add real captures to docs/
  and uncomment. Three columns, one per app, keeps the three-sided story visible.

  <table>
    <tr>
      <td width="33%"><img src="docs/consumer.png" /></td>
      <td width="33%"><img src="docs/merchant.png" /></td>
      <td width="33%"><img src="docs/courier.png" /></td>
    </tr>
    <tr align="center">
      <td>Consumer — browse, order, track, chat.</td>
      <td>Merchant — menu, hours, order queue.</td>
      <td>Courier — claim, navigate, get paid.</td>
    </tr>
  </table>
-->

---

**This repository is `RavonCore`** — the shared Swift Package that all three Ravon apps are built on. It's the single, tested source of truth for the models, authentication, realtime, and backend access every app needs. The three apps live in their own repositories; this is their spine.

## Table of Contents

- [The idea](#the-idea)
- [Why it's interesting](#why-its-interesting)
- [Architecture](#architecture)
- [Repo layout](#repo-layout)
- [Local setup](#local-setup)
- [How an order moves through the system](#how-an-order-moves-through-the-system)
- [Public API surface](#public-api-surface)
- [Design system](#design-system)
- [Security model](#security-model)
- [Testing](#testing)
- [What's intentionally out of scope](#whats-intentionally-out-of-scope)
- [Conventions](#conventions)
- [Credits](#credits)

## The idea

A hungry customer in Dushanbe opens the **Ravon consumer app**, browses nearby restaurants, builds a cart, and places an order. Across town, the restaurant's **merchant app** lights up: a new ticket in the queue. They accept it with a prep estimate and start cooking. The moment the food is ready, a nearby driver running the **courier app** claims the order, drives to the restaurant, confirms a pickup code, and heads out — their location streaming live back to the customer's map. At the door, a delivery code closes the loop, a photo proof is uploaded, and the courier's earnings tick up.

Three apps, three completely different sets of screens — but underneath they must agree, exactly, on what an `Order` is, which state transitions are legal, how a courier gets paid, and how to talk to the database securely. **That shared agreement is this repository.**

Ravon is built like DoorDash / Uber Eats, adapted for a local market: native SwiftUI, iOS 17+, a Russian‑language (Cyrillic) UI, and a single shared **Supabase** backend (Postgres + Auth + Realtime + Storage).

| App | Audience | What they do |
| --- | --- | --- |
| 🛒 **Consumer** | Customers | Browse restaurants, build a cart, place & track orders, chat, tip |
| 🍳 **Merchant** | Restaurants | Manage menus & hours, accept/reject orders, mark food ready |
| 🚗 **Courier** | Drivers | Go online, claim orders, navigate, stream location, get paid |

## Why it's interesting

- **One core, three apps — no drift.** Models, business rules, and backend calls are defined and tested *once* in this package. A schema change is made in one place and every app picks it up. No copy‑pasting a `Order` struct three times and watching them diverge.

- **A 17-state order machine, modeled and tested.** The full lifecycle — from `scheduled` through `delivered`, plus six distinct cancellation states — lives in one typed state machine that knows what's terminal, what's active for a courier, and what transition is legal. The three apps physically *cannot* disagree about what state an order is in.

- **Server-truth, not client-trust.** The client is treated as hostile (anyone can hit the API with the anon key). Authoritative checks — cart re-pricing, order creation, state transitions — run as `SECURITY DEFINER` RPCs and Row-Level-Security policies in Postgres. The Swift-side validation is convenience; the database is the referee.

- **Battery-aware location streaming.** `CourierLocationStreamer` varies GPS cadence *and* movement filtering by order status — a courier idling online sips battery; one actively delivering streams tightly. The policy is a pure function, so it's unit-tested without a device.

- **DoorDash-style auth, done properly.** Six-digit email OTP sign-up with resend cooldown, password recovery, live strength metering, and typed `AuthError`s mapped to friendly localized messages — no raw Supabase errors ever reach a user.

- **A realtime closed loop.** Live subscriptions push order status, courier location, menu changes, and in-order chat between all three sides as they happen — the same publish/subscribe model that lets the customer watch the driver approach.

## Architecture

```
┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│  Consumer    │   │  Merchant    │   │  Courier     │
│    App       │   │    App       │   │    App       │
│  (SwiftUI)   │   │  (SwiftUI)   │   │  (SwiftUI)   │
└──────┬───────┘   └──────┬───────┘   └──────┬───────┘
       │                  │                  │
       └──────────────────┼──────────────────┘
                          ▼
              ┌───────────────────────┐
              │       RavonCore       │  ◄── this repository
              │  ┌─────────────────┐  │
              │  │ Models          │  │   Codable · Sendable · public
              │  │ AuthService     │  │   sign-up/in/out · OTP · recovery
              │  │ SupabaseService │  │   ~60 typed DB ops + RPCs
              │  │ RealtimeService │  │   live orders · location · chat
              │  │ Theme + Auth UI │  │   shared brand kit + auth screens
              │  └─────────────────┘  │
              └───────────┬───────────┘
                          ▼
              ┌───────────────────────┐
              │       Supabase        │
              │ Postgres · Auth ·     │
              │ Realtime · Storage    │
              │ Row-Level Security ·  │
              │ SECURITY DEFINER RPCs │
              └───────────────────────┘
```

**Key patterns**

- **Everything is `public`** — consumed by external app targets.
- **`Sendable` wherever possible** — Swift 6 concurrency-ready.
- **Services are `@MainActor` singletons** exposed via `.shared`.
- **`AuthService` owns the `SupabaseClient`**; `SupabaseService` reaches it via `AuthService.shared.supabaseClient` — one authenticated client, one session.
- **Config is injected, never hardcoded** — each app calls `RavonCore.configure(supabaseURL:supabaseAnonKey:)` at launch, so the same package can point at staging or production.
- **UIKit-dependent UI is guarded** by `#if canImport(UIKit)` so the package still builds for macOS.

## Repo layout

```
Sources/RavonCore/
├── Models/                     ~20 domain types mirroring the DB schema
│   ├── Order.swift             17-state lifecycle + typed transitions
│   ├── Restaurant.swift        listings, status, operating hours
│   ├── MenuItem.swift          items, modifiers, availability
│   ├── Profile.swift           user + UserRole (consumer/courier/merchant)
│   ├── CourierEarning.swift    tiered earnings + period summaries
│   ├── CartValidation.swift    pre-checkout truth-gate types
│   └── …                       Address, ChatMessage, OrderEta, and more
├── Services/
│   ├── RavonConfig.swift       RavonCore.configure(...) — credential injection
│   ├── AuthService.swift       session, sign-up/in/out, email OTP, recovery
│   ├── AuthError.swift         raw Supabase errors → typed, localized messages
│   ├── SupabaseService.swift   ~60 typed DB operations + RPC calls
│   ├── RealtimeService.swift   live order / location / menu / chat subscriptions
│   └── CourierLocationStreamer battery-aware GPS cadence + movement filtering
└── UI/
    ├── Theme.swift             brand colors, buttons, text fields, CardStyle
    └── Auth/                   full shared auth flow (sign-in/up, OTP, recovery,
                                forgot/new password, strength meter)

Tests/RavonCoreTests/           73 unit tests across 22 suites (see Testing)

CLAUDE.md                       working notes / conventions for the codebase
```

## Local setup

RavonCore is a Swift Package — no Xcode project of its own. To build and test it standalone:

```bash
git clone https://github.com/<your-org>/ravon-core.git
cd ravon-core
swift build
swift test
```

**Requirements**

| | |
| --- | --- |
| Swift | 5.9+ |
| iOS | 17.0+ |
| macOS | 14.0+ |
| Backend | A Supabase project (URL + anon key) |

The only third-party dependency is [`supabase-swift`](https://github.com/supabase/supabase-swift) (`2.41+`); everything else is Apple's own (`swift-crypto`, `swift-http-types`, …), resolved transitively.

**Adding it to an app**

In Xcode → *File → Add Package Dependencies…*, or in the app's `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/<your-org>/ravon-core.git", from: "1.0.0"),
],
targets: [
    .target(name: "ConsumerApp", dependencies: [
        .product(name: "RavonCore", package: "ravon-core"),
    ]),
]
```

**Configure once, at launch** — before any service is touched:

```swift
import SwiftUI
import RavonCore

@main
struct ConsumerApp: App {
    init() {
        RavonCore.configure(
            supabaseURL: URL(string: "https://YOUR-PROJECT.supabase.co")!,
            supabaseAnonKey: "YOUR_ANON_KEY"   // inject from an .xcconfig / Secrets.plist / CI secret
        )
    }
    var body: some Scene { WindowGroup { RootView() } }
}
```

> ⚠️ The anon key is *public client config* — but credentials still don't belong in source control. Inject them from a git-ignored `.xcconfig`, `Secrets.plist`, or CI secret. See [Security model](#security-model).

Then observe auth state and call the backend with typed methods:

```swift
struct RootView: View {
    @StateObject private var auth = AuthService.shared
    var body: some View {
        if !auth.isLoaded            { ProgressView() }
        else if auth.isSignedIn      { HomeView() }
        else                         { RavonAuthFlow() }   // shared sign-in / sign-up / OTP UI
    }
}

let service     = SupabaseService.shared
let restaurants = try await service.fetchRestaurants()
let orderId     = try await service.createOrder(
    restaurantId: restaurant.id, addressId: address.id,
    items: cartItems, notes: "Без лука, пожалуйста"
)

try await RealtimeService.shared.subscribeToOrder(orderId: orderId)
```

## How an order moves through the system

1. **Customer places the order.** The consumer app builds a cart and calls `validateCart(...)` — a server-truth gate that re-prices and re-checks availability — then `createOrder(...)`, which runs the atomic `create_order` RPC in Postgres. State: `created`.
2. **Merchant accepts.** The merchant app's realtime queue (`subscribeToRestaurantOrders`) shows the ticket instantly. They call `acceptOrder(estimatedPrepMinutes:)` → `startPreparing()` → `markOrderReady()`. State walks `accepted → preparing → ready`.
3. **Courier claims it.** Online drivers see it via `subscribeToAvailableOrders`; the first to call `claimOrder(...)` wins the row (race-safe, resolved in Postgres). State: `assigned`.
4. **Pickup.** The courier drives over (`courierArrivedAtRestaurant()`), then `pickUpOrder(pickupCode:)` verifies a code before the food is handed off. State: `courier_arrived_restaurant → picked_up`.
5. **Delivery, streamed live.** `startDelivering()` flips the state to `delivering`, and `CourierLocationStreamer` begins pushing GPS at a cadence tuned to the active status — which the customer watches move on their map via `subscribeToCourierLocation`.
6. **Handoff.** At the door, `deliverOrder(deliveryCode:)` verifies a second code and uploads photo proof to Storage. State: `delivered`. Earnings are recorded and appear in the courier's `fetchEarningsSummary(...)`.
7. **Escalation paths, when reality intervenes.** No-shows, restaurant delays, post-pickup problems, and hybrid cancellations (with cooldowns) each have typed methods and their own terminal states — `cancelled_by_customer`, `cancelled_by_restaurant`, `cancelled_by_courier`, `cancelled_by_system` — so nothing ends up in an ambiguous limbo.

Every transition is backed by the tested state machine in `Order.swift`, so all three apps read the same order the same way.

## Public API surface

**`RavonCore`** — `configure(supabaseURL:supabaseAnonKey:)`, injected once at launch.

**`AuthService`** — `@MainActor`, `ObservableObject`, `.shared`. Published: `session`, `isLoaded`, `userRole`; convenience `isSignedIn`, `userId`, `userEmail`, `accessToken`, `supabaseClient`.

| Area | Methods |
| --- | --- |
| Session | `loadSession()` |
| Sign up / in / out | `signUp(email:password:fullName:role:)`, `signIn(email:password:)`, `signOut()` |
| Email OTP | `verifySignUpOTP(email:token:)`, `resendSignUpOTP(email:)` |
| Recovery | `requestPasswordRecovery(email:)`, `verifyRecoveryOTP(email:token:)` |
| Password | `setNewPassword(_:)`, `changePassword(current:new:)` |

**`SupabaseService`** — `@MainActor`, `.shared`, ~60 operations grouped by domain: **Profile**, **Restaurants** (+ server-truth orderability), **Menu**, **Addresses**, **Orders** (consumer/merchant/courier views), **order creation via RPC**, **cart validation**, **order lifecycle** (accept / prepare / ready / reject / pickup / deliver / cancel + escalation), **courier location & status**, **order claiming**, **earnings**, **restaurant hours**, **modifiers**, and **merchant menu management**.

**`RealtimeService`** — `ObservableObject`. `subscribeToOrder`, `subscribeToRestaurantOrders`, `subscribeToCourierOrders`, `subscribeToMenuChanges`, `subscribeToRestaurantStatus`, `subscribeToCourierLocation`, `subscribeToAvailableOrders`, `subscribeToChat` — each with a matching `unsubscribe…`, plus `unsubscribeAll()`.

**`CourierLocationStreamer`** — `submit(...)`, `setActiveOrderStatus(_:)`, `cadence(for:)`, `movementFilterMeters(for:)`, `reset()`.

## Design system

Defined in `UI/Theme.swift` and the shared `UI/Auth/` components, so all three apps look like one product.

| Token | Value | Use |
| --- | --- | --- |
| `ravonRed` | `#FF3008` | Primary brand / CTAs |
| `ravonDark` | `#1A1A2E` | Dark surfaces & text |
| `ravonGray` | — | Secondary text / dividers |

Components: `RavonPrimaryButton`, `PressableButtonStyle`, `RavonTextField` (UIKit-backed, guarded), a `CardStyle` modifier, and a full shared auth UI (`RavonSignInView`, `RavonSignUpView`, `RavonOTPView`, `RavonForgotPasswordView`, `RavonNewPasswordView`, `RavonPasswordStrengthMeter`). UI language is Russian (Cyrillic).

## Security model

A mobile client is fundamentally untrusted — anyone can call the API with the anon key outside the app. RavonCore is built with that in mind:

- 🔓 **The anon key is public client config, not a secret.** Every RLS policy and every RPC reachable with `anon` must be safe against direct API access. The client is treated as hostile.
- 🚫 **The `service_role` key never appears in this repo** — not in source, docs, binaries, or config, even in a private repo. It's git-ignored defensively.
- 🛡️ **Authorization lives in Postgres**, not in Swift. Client-side validation (cart re-pricing, transition checks) is convenience; the authoritative checks are RLS policies and `SECURITY DEFINER` RPCs, verified against the live database — not just the client.
- 🙈 **Credentials are injected, never committed.** `.env`, `Secrets.plist`, `*.xcconfig`, `service_role*`, and similar are listed in `.gitignore`. This repository ships **credential-free** — fork it and nothing live comes with it.

## Testing

**73 unit tests across 22 suites**, run with `swift test`. Coverage targets the logic that must not regress across three apps:

- Auth error mapping, email validation, password strength, OTP cooldown
- Cart validation and the pre-checkout truth gate
- Order state modeling, ETA computation, scheduled orders, soft-delete coding
- Courier earnings tiers, cancellation rules, delivery codes, heartbeat escalation, reassignment & race-condition coding
- Restaurant orderability hints, operating hours & next-open-time, menu category templates
- Chat RLS coding, no-show/delay coding, insert-struct round-tripping

## What's intentionally out of scope

- **This package is client-only.** The Supabase schema, RLS policies, and RPC bodies live in the backend project, not here. RavonCore assumes they exist and are correct.
- **No payment gateway integration yet.** Tips and totals are modeled; charging a card is a future backend concern.
- **UI language is Russian only.** There is no localization/translation layer in the current build.
- **App shells live elsewhere.** Screens, navigation, and app icons for the three apps are in their own repositories — this is the shared core, deliberately UI-light beyond the theme kit and auth flow.
- **Authoritative security is the database's job.** Any check that actually matters is enforced server-side; don't treat the Swift validation here as a security boundary.

## Conventions

- **Commits:** `type: description` — `feat`, `fix`, `refactor`, `chore`, etc.
- **Access control:** everything consumed by apps is `public`; prefer `Sendable`.
- **Services:** `@MainActor` singletons via `.shared`.
- **Platform guards:** UIKit-only code lives behind `#if canImport(UIKit)`.
- **Build:** `swift build` · **Test:** `swift test`.

## Credits

- [Supabase](https://supabase.com) — Postgres, Auth, Realtime, and Storage in one backend.
- [supabase-swift](https://github.com/supabase/supabase-swift) — the official Swift client this package wraps.
- Built with Swift · SwiftUI · Supabase — для Таджикистана 🇹🇯

<div align="center">

**RavonCore** — the shared spine of the Ravon delivery platform.

</div>
