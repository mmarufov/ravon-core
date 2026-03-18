# RavonCore — Shared Swift Package

## What This Is

RavonCore is the shared Swift package used by all 3 Ravon apps (consumer, merchant, courier). It contains models, services, auth, theme, and Supabase integration that every app needs.

## Tech Stack

- Swift Package (SPM)
- Supabase Swift SDK (dependency)
- iOS 17+ / macOS 14+
- Swift 5.9+

## Architecture

This package provides:
- **Models**: Restaurant, MenuItem, MenuCategory, Order, OrderItem, OrderStatusHistory, Address, AddressInsert, AddressSnapshot, Profile, UserRole (consumer/courier/merchant), OrderStatus
- **Services**: AuthService (Supabase auth, session, sign in/up/out), SupabaseService (all DB queries, order creation via RPC, order status updates), ServiceError
- **Config**: `RavonCore.configure(supabaseURL:supabaseAnonKey:)` — each app calls this at launch
- **UI/Theme**: Brand colors (ravonRed #FF3008, ravonDark, ravonGray), CardStyle modifier, PressableButtonStyle, RavonPrimaryButton, RavonTextField

## Key Patterns

- All types must be `public` (consumed by external apps)
- All types should be `Sendable` where possible
- Services are `@MainActor` singletons with `.shared`
- AuthService owns the SupabaseClient instance; SupabaseService accesses it via `AuthService.shared.supabaseClient`
- Config is injectable — apps call `RavonCore.configure()` before using services
- UIKit-dependent code (RavonTextField) must be wrapped in `#if canImport(UIKit)`

## Supabase Database Tables

- `profiles` — user profiles with role (consumer/courier/merchant)
- `restaurants` — restaurant listings
- `menu_categories` — categories per restaurant
- `menu_items` — items with prices, availability
- `addresses` — user delivery addresses
- `orders` — orders with status, totals, address snapshot
- `order_items` — line items in orders
- `order_status_history` — audit trail of status changes

## RPC Functions

- `create_order(p_restaurant_id, p_address_id, p_items, p_notes)` — creates order atomically

## Supabase Config

- URL: `https://imcintoicxvmvzwpmxpr.supabase.co`
- All 3 apps use the same Supabase project. Row-level security handles access per role.
- Each app provides its own credentials via `RavonCore.configure()` at launch.

## Commit Messages

Use `type: description` format (feat, fix, refactor, chore, etc).

## Design

- Brand color: Ravon Red `#FF3008`
- Dark palette: ravonDark `#1A1A2E`
- UI language: Russian (Cyrillic)
