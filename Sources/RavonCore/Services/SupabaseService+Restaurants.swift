import Foundation
import Supabase

extension SupabaseService {
    // MARK: - Restaurants

    /// Consumer feed: only `active` restaurants. Server view `restaurants_orderable` exposes
    /// `is_orderable_now` so the consumer can render badges (open / out-of-hours / not-accepting)
    /// without re-computing client-side. We still fetch all `active` rows so the feed shows
    /// out-of-hours restaurants greyed-out (per UX matrix), with the schedule-for-later flow.
    public func fetchRestaurants() async throws -> [Restaurant] {
        try await client.from("restaurants")
            .select()
            .eq("restaurant_status", value: RestaurantStatus.active.rawValue)
            .order("rating", ascending: false)
            .execute()
            .value
    }

    /// Single-restaurant fetch. Returns even paused/closed/soft-deleted rows so deep-links
    /// and order history can render them — UI is responsible for showing the right state.
    public func fetchRestaurant(id: UUID) async throws -> Restaurant {
        try await client.from("restaurants")
            .select()
            .eq("id", value: id.uuidString)
            .single()
            .execute()
            .value
    }

    // MARK: - Orderability (server-truth)

    public struct RestaurantOrderability: Decodable, Sendable {
        public let isOrderableNow: Bool
        public let reason: OrderabilityReason
        public let opensAt: Date?

        enum CodingKeys: String, CodingKey {
            case isOrderableNow = "is_orderable_now"
            case reason
            case opensAt = "opens_at"
        }
    }

    /// Lightweight RPC to check orderability without re-fetching the whole restaurant.
    /// Used by consumer detail screen to render the bottom CTA state.
    public func getRestaurantOrderability(restaurantId: UUID, at: Date? = nil) async throws -> RestaurantOrderability {
        struct Params: Encodable {
            let p_restaurant_id: UUID
            let p_at: Date?
        }
        return try await client.rpc("get_restaurant_orderability", params: Params(
            p_restaurant_id: restaurantId, p_at: at
        )).execute().value
    }

    // MARK: - Restaurant Hours

    public func fetchRestaurantHours(restaurantId: UUID) async throws -> [RestaurantHours] {
        try await client.from("restaurant_hours")
            .select()
            .eq("restaurant_id", value: restaurantId.uuidString)
            .order("day_of_week")
            .execute()
            .value
    }

    public func upsertRestaurantHours(_ hours: [RestaurantHoursUpsert]) async throws {
        try await client.from("restaurant_hours")
            .upsert(hours, onConflict: "restaurant_id,day_of_week")
            .execute()
    }

    /// Removed — was client-side using device local time vs DB strings (Asia/Dushanbe-naïve)
    /// and didn't handle past-midnight ranges. Use `getRestaurantOrderability(restaurantId:at:)`
    /// which calls the server `restaurant_is_orderable()` function (timezone-correct, hours +
    /// status + accepting toggle in one call). For UI-only labels like "Откроется в 09:00",
    /// use `RestaurantHours.nextOpenAt(from:)`.

    // MARK: - Merchant Restaurant Management

    public func updateRestaurant(
        id: UUID,
        name: String? = nil,
        description: String? = nil,
        address: String? = nil,
        cuisineType: String? = nil,
        deliveryFee: Double? = nil,
        minOrderAmount: Double? = nil,
        deliveryTimeMin: Int? = nil,
        maxConcurrentOrders: Int? = nil
    ) async throws {
        var updates: [String: AnyJSON] = [:]
        if let name { updates["name"] = .string(name) }
        if let description { updates["description"] = .string(description) }
        if let address { updates["address"] = .string(address) }
        if let cuisineType { updates["cuisine_type"] = .string(cuisineType) }
        if let deliveryFee { updates["delivery_fee"] = .double(deliveryFee) }
        if let minOrderAmount { updates["min_order_amount"] = .double(minOrderAmount) }
        if let deliveryTimeMin { updates["delivery_time_min"] = .integer(deliveryTimeMin) }
        if let maxConcurrentOrders { updates["max_concurrent_orders"] = .integer(maxConcurrentOrders) }
        guard !updates.isEmpty else { return }
        try await client.from("restaurants")
            .update(updates)
            .eq("id", value: id.uuidString)
            .execute()
    }

    public func toggleAcceptingOrders(restaurantId: UUID, accepting: Bool) async throws {
        try await setAcceptingOrders(restaurantId: restaurantId, accepting: accepting, until: nil)
    }

    /// Set `is_accepting_orders` with an optional auto-resume time. When `until` is set,
    /// a `pg_cron` job flips `is_accepting_orders` back to `true` and clears `accepting_orders_until`
    /// at that time. Useful for "stop accepting until 21:00" — Tajikistan merchants will
    /// otherwise forget to re-enable.
    public func setAcceptingOrders(restaurantId: UUID, accepting: Bool, until: Date?) async throws {
        struct Params: Encodable {
            let p_restaurant_id: UUID
            let p_accepting: Bool
            let p_until: Date?
        }
        try await client.rpc("set_accepting_orders", params: Params(
            p_restaurant_id: restaurantId, p_accepting: accepting, p_until: until
        )).execute()
    }

    // MARK: - Merchant Restaurant CRUD

    /// Create a new restaurant for the authenticated merchant (1 per merchant enforced by DB unique index)
    public func createRestaurant(_ insert: RestaurantInsert) async throws -> Restaurant {
        guard AuthService.shared.userId != nil else {
            throw ServiceError.notAuthenticated
        }
        // Pre-check: does this merchant already have a restaurant?
        if let _ = try await fetchMyRestaurant() {
            throw ServiceError.merchantAlreadyHasRestaurant
        }
        return try await client.from("restaurants")
            .insert(insert)
            .select()
            .single()
            .execute()
            .value
    }

    /// Fetch the authenticated merchant's restaurant (nil if none yet)
    public func fetchMyRestaurant() async throws -> Restaurant? {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        let restaurants: [Restaurant] = try await client.from("restaurants")
            .select()
            .eq("owner_id", value: uid.uuidString)
            .limit(1)
            .execute()
            .value
        return restaurants.first
    }

    // MARK: - Restaurant Lifecycle

    /// Activate restaurant (draft → active). Checks onboarding completeness.
    public func activateRestaurant(id: UUID) async throws {
        let progress = try await fetchOnboardingProgress()
        guard progress.isReadyToGoLive else {
            throw ServiceError.onboardingIncomplete
        }
        let results: [IdRow] = try await client.from("restaurants")
            .update(["restaurant_status": AnyJSON.string(RestaurantStatus.active.rawValue)])
            .eq("id", value: id.uuidString)
            .eq("restaurant_status", value: RestaurantStatus.draft.rawValue)
            .select("id")
            .execute()
            .value
        guard !results.isEmpty else { throw ServiceError.invalidStatusTransition }
    }

    /// Resume restaurant (paused → active). No onboarding check needed.
    public func resumeRestaurant(id: UUID) async throws {
        let results: [IdRow] = try await client.from("restaurants")
            .update(["restaurant_status": AnyJSON.string(RestaurantStatus.active.rawValue)])
            .eq("id", value: id.uuidString)
            .eq("restaurant_status", value: RestaurantStatus.paused.rawValue)
            .select("id")
            .execute()
            .value
        guard !results.isEmpty else { throw ServiceError.invalidStatusTransition }
    }

    /// Pause restaurant (active → paused)
    public func pauseRestaurant(id: UUID) async throws {
        let results: [IdRow] = try await client.from("restaurants")
            .update(["restaurant_status": AnyJSON.string(RestaurantStatus.paused.rawValue)])
            .eq("id", value: id.uuidString)
            .eq("restaurant_status", value: RestaurantStatus.active.rawValue)
            .select("id")
            .execute()
            .value
        guard !results.isEmpty else { throw ServiceError.invalidStatusTransition }
    }

    /// Close restaurant permanently (active or paused → closed)
    public func closeRestaurant(id: UUID) async throws {
        let results: [IdRow] = try await client.from("restaurants")
            .update(["restaurant_status": AnyJSON.string(RestaurantStatus.closed.rawValue)])
            .eq("id", value: id.uuidString)
            .in("restaurant_status", values: [RestaurantStatus.active.rawValue, RestaurantStatus.paused.rawValue])
            .select("id")
            .execute()
            .value
        guard !results.isEmpty else { throw ServiceError.invalidStatusTransition }
    }

    // MARK: - Onboarding Progress

    /// Fetch onboarding progress for the merchant's restaurant
    public func fetchOnboardingProgress() async throws -> OnboardingProgress {
        guard let restaurant = try await fetchMyRestaurant() else {
            return OnboardingProgress()
        }
        let categories = try await fetchMenuCategories(restaurantId: restaurant.id)
        let liveItems: [MenuItem] = try await client.from("menu_items")
            .select()
            .eq("restaurant_id", value: restaurant.id.uuidString)
            .eq("is_available", value: true)
            .gt("price", value: 0)
            .execute()
            .value
        let hours = try await fetchRestaurantHours(restaurantId: restaurant.id)

        return OnboardingProgress(
            hasRestaurant: true,
            hasName: !restaurant.name.isEmpty,
            hasAddress: restaurant.address != nil && !restaurant.address!.isEmpty,
            hasAtLeastOneCategory: !categories.isEmpty,
            hasAtLeastOneMenuItem: !liveItems.isEmpty,
            hasHoursConfigured: !hours.isEmpty
        )
    }

    /// Preview restaurant as consumer sees it (available items only, sorted categories)
    public func fetchRestaurantPreview(restaurantId: UUID) async throws -> (Restaurant, [MenuCategory], [MenuItem]) {
        let restaurant = try await fetchRestaurant(id: restaurantId)
        let categories = try await fetchMenuCategories(restaurantId: restaurantId)
        let items = try await fetchMenuItems(restaurantId: restaurantId)
        return (restaurant, categories, items)
    }

    // MARK: - Merchant Stats

    /// Fetch basic dashboard stats for merchant's restaurant (server-side RPC)
    public func fetchMerchantStats(restaurantId: UUID) async throws -> MerchantStats {
        struct Params: Encodable {
            let p_restaurant_id: UUID
        }
        return try await client.rpc("get_merchant_stats", params: Params(
            p_restaurant_id: restaurantId
        )).execute().value
    }
}
