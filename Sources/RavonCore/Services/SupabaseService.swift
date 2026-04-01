import Foundation
import Supabase

public enum ServiceError: LocalizedError, Sendable {
    case notAuthenticated
    case invalidResponse
    case orderNotFound
    case invalidStatusTransition
    case unauthorized
    case invalidVerificationCode
    case orderAlreadyClaimed
    case restaurantClosed
    case restaurantNotAccepting
    case restaurantOverloaded
    case insufficientStock
    case cancelNotAllowed
    case merchantAlreadyHasRestaurant
    case onboardingIncomplete
    case imageTooLarge
    case unsupportedImageFormat
    case categoryNotEmpty

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:              return "Пользователь не авторизован"
        case .invalidResponse:               return "Ошибка ответа сервера"
        case .orderNotFound:                 return "Заказ не найден"
        case .invalidStatusTransition:       return "Недопустимый переход статуса"
        case .unauthorized:                  return "Недостаточно прав"
        case .invalidVerificationCode:       return "Неверный код подтверждения"
        case .orderAlreadyClaimed:           return "Заказ уже занят другим курьером"
        case .restaurantClosed:              return "Ресторан сейчас закрыт"
        case .restaurantNotAccepting:        return "Ресторан не принимает заказы"
        case .restaurantOverloaded:          return "Ресторан перегружен заказами"
        case .insufficientStock:             return "Недостаточно товара на складе"
        case .cancelNotAllowed:              return "Отмена невозможна — заказ уже забран курьером"
        case .merchantAlreadyHasRestaurant:  return "У вас уже есть ресторан"
        case .onboardingIncomplete:          return "Заполните все данные перед открытием"
        case .imageTooLarge:                 return "Изображение слишком большое (макс. 5 МБ)"
        case .unsupportedImageFormat:        return "Неподдерживаемый формат изображения"
        case .categoryNotEmpty:              return "Удалите все блюда из категории перед удалением"
        }
    }
}

@MainActor
public final class SupabaseService {
    public static let shared = SupabaseService()

    private var client: SupabaseClient { AuthService.shared.supabaseClient }

    public init() {}

    private struct IdRow: Decodable { let id: UUID }
    private static let isoFormatter = ISO8601DateFormatter()

    // MARK: - Profile

    public func fetchProfile() async throws -> Profile {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        return try await client.from("profiles")
            .select()
            .eq("id", value: uid.uuidString)
            .single()
            .execute()
            .value
    }

    public func updateProfile(fullName: String, phone: String?) async throws {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        var updates: [String: AnyJSON] = [
            "full_name": .string(fullName),
        ]
        updates["phone"] = phone.map { .string($0) } ?? .null
        try await client.from("profiles")
            .update(updates)
            .eq("id", value: uid.uuidString)
            .execute()
    }

    // MARK: - Restaurants

    public func fetchRestaurants() async throws -> [Restaurant] {
        try await client.from("restaurants")
            .select()
            .eq("is_active", value: true)
            .eq("restaurant_status", value: RestaurantStatus.active.rawValue)
            .order("rating", ascending: false)
            .execute()
            .value
    }

    public func fetchRestaurant(id: UUID) async throws -> Restaurant {
        try await client.from("restaurants")
            .select()
            .eq("id", value: id.uuidString)
            .single()
            .execute()
            .value
    }

    // MARK: - Menu

    public func fetchMenuCategories(restaurantId: UUID) async throws -> [MenuCategory] {
        try await client.from("menu_categories")
            .select()
            .eq("restaurant_id", value: restaurantId.uuidString)
            .order("sort_order")
            .execute()
            .value
    }

    public func fetchMenuItems(restaurantId: UUID) async throws -> [MenuItem] {
        try await client.from("menu_items")
            .select()
            .eq("restaurant_id", value: restaurantId.uuidString)
            .eq("is_available", value: true)
            .order("sort_order")
            .execute()
            .value
    }

    // MARK: - Addresses

    public func fetchAddresses() async throws -> [Address] {
        try await client.from("addresses")
            .select()
            .order("is_default", ascending: false)
            .execute()
            .value
    }

    public func createAddress(_ address: AddressInsert) async throws -> Address {
        try await client.from("addresses")
            .insert(address)
            .select()
            .single()
            .execute()
            .value
    }

    public func deleteAddress(id: UUID) async throws {
        try await client.from("addresses")
            .delete()
            .eq("id", value: id.uuidString)
            .execute()
    }

    // MARK: - Orders

    public func fetchOrders() async throws -> [Order] {
        try await client.from("orders")
            .select("*, restaurants(*), order_items(*)")
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    public func fetchOrder(id: UUID) async throws -> Order {
        try await client.from("orders")
            .select("*, restaurants(*), order_items(*)")
            .eq("id", value: id.uuidString)
            .single()
            .execute()
            .value
    }

    public func fetchOrderStatusHistory(orderId: UUID) async throws -> [OrderStatusHistory] {
        try await client.from("order_status_history")
            .select()
            .eq("order_id", value: orderId.uuidString)
            .order("created_at")
            .execute()
            .value
    }

    // MARK: - Orders (Merchant / Courier)

    /// Fetch orders for a specific restaurant (used by Merchant app)
    public func fetchOrdersForRestaurant(restaurantId: UUID) async throws -> [Order] {
        try await client.from("orders")
            .select("*, order_items(*)")
            .eq("restaurant_id", value: restaurantId.uuidString)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    // MARK: - Create Order (via RPC)

    public struct CreateOrderParams: Encodable, Sendable {
        public let p_restaurant_id: UUID
        public let p_address_id: UUID
        public let p_items: [OrderItemParam]
        public let p_notes: String?

        public init(p_restaurant_id: UUID, p_address_id: UUID, p_items: [OrderItemParam], p_notes: String?) {
            self.p_restaurant_id = p_restaurant_id
            self.p_address_id = p_address_id
            self.p_items = p_items
            self.p_notes = p_notes
        }
    }

    public struct OrderItemParam: Encodable, Sendable {
        public let menu_item_id: UUID
        public let quantity: Int

        public init(menu_item_id: UUID, quantity: Int) {
            self.menu_item_id = menu_item_id
            self.quantity = quantity
        }
    }

    public func createOrder(
        restaurantId: UUID,
        addressId: UUID,
        items: [(menuItemId: UUID, quantity: Int)],
        notes: String?
    ) async throws -> UUID {
        let itemsParam = items.map { item in
            OrderItemParam(menu_item_id: item.menuItemId, quantity: item.quantity)
        }
        let params = CreateOrderParams(
            p_restaurant_id: restaurantId,
            p_address_id: addressId,
            p_items: itemsParam,
            p_notes: notes
        )
        let result: String = try await client.rpc("create_order", params: params).execute().value
        guard let uuid = UUID(uuidString: result) else {
            throw ServiceError.invalidResponse
        }
        return uuid
    }

    // MARK: - Order Lifecycle (Merchant)

    public func acceptOrder(orderId: UUID, estimatedPrepMinutes: Int) async throws {
        let results: [IdRow] = try await client.from("orders")
            .update([
                "status": AnyJSON.string(OrderStatus.accepted.rawValue),
                "estimated_prep_time": AnyJSON.integer(estimatedPrepMinutes),
                "accepted_at": AnyJSON.string(Self.isoFormatter.string(from: Date())),
            ])
            .eq("id", value: orderId.uuidString)
            .eq("status", value: OrderStatus.created.rawValue)
            .select("id")
            .execute()
            .value
        guard !results.isEmpty else { throw ServiceError.invalidStatusTransition }
    }

    public func startPreparing(orderId: UUID) async throws {
        let results: [IdRow] = try await client.from("orders")
            .update(["status": AnyJSON.string(OrderStatus.preparing.rawValue)])
            .eq("id", value: orderId.uuidString)
            .eq("status", value: OrderStatus.accepted.rawValue)
            .select("id")
            .execute()
            .value
        guard !results.isEmpty else { throw ServiceError.invalidStatusTransition }
    }

    public func rejectOrder(orderId: UUID, reason: String) async throws {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        let results: [IdRow] = try await client.from("orders")
            .update([
                "status": AnyJSON.string(OrderStatus.rejected.rawValue),
                "cancellation_reason": AnyJSON.string(reason),
                "cancelled_by": AnyJSON.string(uid.uuidString),
                "rejected_at": AnyJSON.string(Self.isoFormatter.string(from: Date())),
            ])
            .eq("id", value: orderId.uuidString)
            .eq("status", value: OrderStatus.created.rawValue)
            .select("id")
            .execute()
            .value
        guard !results.isEmpty else { throw ServiceError.invalidStatusTransition }
    }

    public func markOrderReady(orderId: UUID) async throws {
        let results: [IdRow] = try await client.from("orders")
            .update(["status": AnyJSON.string(OrderStatus.ready.rawValue)])
            .eq("id", value: orderId.uuidString)
            .in("status", values: [OrderStatus.accepted.rawValue, OrderStatus.preparing.rawValue])
            .select("id")
            .execute()
            .value
        guard !results.isEmpty else { throw ServiceError.invalidStatusTransition }
    }

    // MARK: - Order Lifecycle (Courier)

    public func courierArrivedAtRestaurant(orderId: UUID) async throws {
        let results: [IdRow] = try await client.from("orders")
            .update(["status": AnyJSON.string(OrderStatus.courierArrivedRestaurant.rawValue)])
            .eq("id", value: orderId.uuidString)
            .eq("status", value: OrderStatus.assigned.rawValue)
            .select("id")
            .execute()
            .value
        guard !results.isEmpty else { throw ServiceError.invalidStatusTransition }
    }

    public func pickUpOrder(orderId: UUID, verificationCode: String) async throws {
        // Atomic: verifies code + status in a single UPDATE WHERE
        let results: [IdRow] = try await client.from("orders")
            .update([
                "status": AnyJSON.string(OrderStatus.pickedUp.rawValue),
                "picked_up_at": AnyJSON.string(Self.isoFormatter.string(from: Date())),
            ])
            .eq("id", value: orderId.uuidString)
            .eq("status", value: OrderStatus.courierArrivedRestaurant.rawValue)
            .eq("verification_code", value: verificationCode)
            .select("id")
            .execute()
            .value
        guard !results.isEmpty else { throw ServiceError.invalidVerificationCode }
    }

    public func startDelivering(orderId: UUID) async throws {
        let results: [IdRow] = try await client.from("orders")
            .update(["status": AnyJSON.string(OrderStatus.delivering.rawValue)])
            .eq("id", value: orderId.uuidString)
            .eq("status", value: OrderStatus.pickedUp.rawValue)
            .select("id")
            .execute()
            .value
        guard !results.isEmpty else { throw ServiceError.invalidStatusTransition }
    }

    public func courierArrivedAtCustomer(orderId: UUID) async throws {
        let results: [IdRow] = try await client.from("orders")
            .update(["status": AnyJSON.string(OrderStatus.courierArrivedCustomer.rawValue)])
            .eq("id", value: orderId.uuidString)
            .eq("status", value: OrderStatus.delivering.rawValue)
            .select("id")
            .execute()
            .value
        guard !results.isEmpty else { throw ServiceError.invalidStatusTransition }
    }

    public func deliverOrder(orderId: UUID) async throws {
        let results: [IdRow] = try await client.from("orders")
            .update([
                "status": AnyJSON.string(OrderStatus.delivered.rawValue),
                "delivered_at": AnyJSON.string(Self.isoFormatter.string(from: Date())),
            ])
            .eq("id", value: orderId.uuidString)
            .eq("status", value: OrderStatus.courierArrivedCustomer.rawValue)
            .select("id")
            .execute()
            .value
        guard !results.isEmpty else { throw ServiceError.invalidStatusTransition }
        // Clear courier's active order so they return to available status
        try await clearCurrentOrder()
    }

    // MARK: - Order Lifecycle (Consumer)

    public func cancelOrder(orderId: UUID, reason: String?) async throws {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        var updates: [String: AnyJSON] = [
            "status": .string(OrderStatus.cancelledByCustomer.rawValue),
            "cancelled_by": .string(uid.uuidString),
        ]
        if let reason {
            updates["cancellation_reason"] = .string(reason)
        }
        // Only allow cancel before courier picks up the food
        let cancellableStatuses: [String] = [
            OrderStatus.created.rawValue,
            OrderStatus.accepted.rawValue,
            OrderStatus.preparing.rawValue,
            OrderStatus.ready.rawValue,
            OrderStatus.assigned.rawValue,
            OrderStatus.courierArrivedRestaurant.rawValue,
        ]
        let results: [IdRow] = try await client.from("orders")
            .update(updates)
            .eq("id", value: orderId.uuidString)
            .in("status", values: cancellableStatuses)
            .select("id")
            .execute()
            .value
        if results.isEmpty {
            // Check if the order exists but is past pickup
            let order: Order = try await client.from("orders")
                .select()
                .eq("id", value: orderId.uuidString)
                .single()
                .execute()
                .value
            if order.status == .pickedUp || order.status == .delivering || order.status == .courierArrivedCustomer {
                throw ServiceError.cancelNotAllowed
            }
            throw ServiceError.invalidStatusTransition
        }
    }

    // MARK: - Order Lifecycle (Shared)

    public func assignCourier(orderId: UUID, courierId: UUID) async throws {
        let results: [IdRow] = try await client.from("orders")
            .update([
                "status": AnyJSON.string(OrderStatus.assigned.rawValue),
                "courier_id": AnyJSON.string(courierId.uuidString),
            ])
            .eq("id", value: orderId.uuidString)
            .in("status", values: [
                OrderStatus.accepted.rawValue,
                OrderStatus.preparing.rawValue,
                OrderStatus.ready.rawValue,
            ])
            .is("courier_id", value: nil)
            .select("id")
            .execute()
            .value
        guard !results.isEmpty else { throw ServiceError.orderAlreadyClaimed }
    }

    public func addTip(orderId: UUID, amount: Double) async throws {
        guard AuthService.shared.userId != nil else {
            throw ServiceError.notAuthenticated
        }
        guard amount >= 0 else { return }
        try await client.from("orders")
            .update(["tip_amount": AnyJSON.double(amount)])
            .eq("id", value: orderId.uuidString)
            .execute()
    }

    // MARK: - Courier Location

    public func updateCourierLocation(
        latitude: Double,
        longitude: Double,
        heading: Double?,
        speed: Double?
    ) async throws {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        let upsert = CourierLocationUpsert(
            courierId: uid,
            latitude: latitude,
            longitude: longitude,
            heading: heading,
            speed: speed,
            isOnline: true
        )
        try await client.from("courier_locations")
            .upsert(upsert, onConflict: "courier_id")
            .execute()
    }

    public func fetchCourierLocation(courierId: UUID) async throws -> CourierLocation {
        try await client.from("courier_locations")
            .select()
            .eq("courier_id", value: courierId.uuidString)
            .single()
            .execute()
            .value
    }

    public func fetchNearbyCouriers(
        latitude: Double,
        longitude: Double,
        radiusKm: Double = 5.0
    ) async throws -> [NearbyCourier] {
        struct Params: Encodable {
            let p_latitude: Double
            let p_longitude: Double
            let p_radius_km: Double
        }
        return try await client.rpc("find_nearby_couriers", params: Params(
            p_latitude: latitude,
            p_longitude: longitude,
            p_radius_km: radiusKm
        )).execute().value
    }

    // MARK: - Courier Status

    public func goOnline(latitude: Double, longitude: Double) async throws {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        let upsert = CourierLocationUpsert(
            courierId: uid,
            latitude: latitude,
            longitude: longitude,
            isOnline: true
        )
        try await client.from("courier_locations")
            .upsert(upsert, onConflict: "courier_id")
            .execute()
    }

    public func goOffline() async throws {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        try await client.from("courier_locations")
            .update(["is_online": AnyJSON.bool(false)])
            .eq("courier_id", value: uid.uuidString)
            .execute()
    }

    public func fetchCourierStatus() async throws -> CourierLocation {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        return try await client.from("courier_locations")
            .select()
            .eq("courier_id", value: uid.uuidString)
            .single()
            .execute()
            .value
    }

    // MARK: - Courier Claiming

    public func claimOrder(orderId: UUID) async throws -> UUID {
        struct Params: Encodable {
            let p_order_id: UUID
        }
        let result: String = try await client.rpc("claim_order", params: Params(
            p_order_id: orderId
        )).execute().value
        guard let uuid = UUID(uuidString: result) else {
            throw ServiceError.invalidResponse
        }
        return uuid
    }

    /// Fetch all available orders without location filter (for testing / fallback)
    public func fetchAvailableOrders() async throws -> [Order] {
        try await client.from("orders")
            .select("*, restaurants(*), order_items(*)")
            .is("courier_id", value: nil)
            .in("status", values: ["accepted", "preparing", "ready"])
            .order("created_at")
            .execute()
            .value
    }

    /// Fetch available orders within radius of courier's location
    public func fetchAvailableOrders(
        latitude: Double,
        longitude: Double,
        radiusKm: Double = 10.0
    ) async throws -> [Order] {
        struct Params: Encodable {
            let p_latitude: Double
            let p_longitude: Double
            let p_radius_km: Double
        }
        return try await client.rpc("fetch_available_orders", params: Params(
            p_latitude: latitude,
            p_longitude: longitude,
            p_radius_km: radiusKm
        )).execute().value
    }

    // MARK: - Courier Active Order

    /// Fetch the courier's current active (non-terminal) order for state restoration
    public func fetchActiveOrder(courierId: UUID) async throws -> Order? {
        let terminalStatuses = [
            OrderStatus.delivered.rawValue,
            OrderStatus.cancelled.rawValue,
            OrderStatus.cancelledByCustomer.rawValue,
            OrderStatus.cancelledByRestaurant.rawValue,
            OrderStatus.cancelledBySystem.rawValue,
            OrderStatus.rejected.rawValue,
        ]
        let orders: [Order] = try await client.from("orders")
            .select("*, restaurants(*), order_items(*)")
            .eq("courier_id", value: courierId.uuidString)
            .not("status", operator: .in, value: "(\(terminalStatuses.joined(separator: ",")))")
            .order("updated_at", ascending: false)
            .limit(1)
            .execute()
            .value
        return orders.first
    }

    /// Clear current_order_id on courier_locations so courier can receive new offers
    public func clearCurrentOrder() async throws {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        try await client.from("courier_locations")
            .update(["current_order_id": AnyJSON.null])
            .eq("courier_id", value: uid.uuidString)
            .execute()
    }

    // MARK: - Courier Earnings

    public enum EarningsPeriod: Sendable {
        case today
        case week
        case month
        case all
    }

    public func fetchEarnings(period: EarningsPeriod) async throws -> [CourierEarning] {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        var query = client.from("courier_earnings")
            .select()
            .eq("courier_id", value: uid.uuidString)

        let formatter = ISO8601DateFormatter()
        switch period {
        case .today:
            let startOfDay = Calendar.current.startOfDay(for: Date())
            query = query.gte("created_at", value: formatter.string(from: startOfDay))
        case .week:
            let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
            query = query.gte("created_at", value: formatter.string(from: weekAgo))
        case .month:
            let monthAgo = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
            query = query.gte("created_at", value: formatter.string(from: monthAgo))
        case .all:
            break
        }

        return try await query
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    public func fetchEarningsSummary(period: EarningsPeriod) async throws -> EarningsSummary {
        let earnings = try await fetchEarnings(period: period)
        return EarningsSummary(
            totalDeliveries: earnings.count,
            totalDeliveryFees: earnings.reduce(0) { $0 + $1.deliveryFee },
            totalTips: earnings.reduce(0) { $0 + $1.tipAmount },
            totalEarned: earnings.reduce(0) { $0 + $1.totalEarned }
        )
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

    public func isRestaurantOpen(restaurantId: UUID) async throws -> Bool {
        let hours = try await fetchRestaurantHours(restaurantId: restaurantId)
        guard !hours.isEmpty else { return true } // No hours = always open

        let now = Date()
        let calendar = Calendar.current
        // Swift .weekday: 1=Sunday, 2=Monday, ... 7=Saturday
        // DB convention: 0=Sunday, 1=Monday, ... 6=Saturday
        let dayOfWeek = calendar.component(.weekday, from: now) - 1

        guard let todayHours = hours.first(where: { $0.dayOfWeek == dayOfWeek }) else {
            return true // No entry for today = open
        }
        if todayHours.isClosed { return false }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let currentTimeStr = formatter.string(from: now)
        return currentTimeStr >= todayHours.openingTime && currentTimeStr <= todayHours.closingTime
    }

    // MARK: - Modifiers

    /// Fetch modifier groups for a specific menu item (consumer view, via junction table)
    public func fetchModifierGroups(menuItemId: UUID) async throws -> [ModifierGroup] {
        let junctions: [MenuItemModifierGroup] = try await client.from("menu_item_modifier_groups")
            .select()
            .eq("menu_item_id", value: menuItemId.uuidString)
            .execute()
            .value
        guard !junctions.isEmpty else { return [] }
        let groupIds = junctions.map { $0.modifierGroupId.uuidString }
        return try await client.from("modifier_groups")
            .select("*, modifier_options(*)")
            .in("id", values: groupIds)
            .order("sort_order")
            .execute()
            .value
    }

    /// Fetch all modifier groups for a restaurant (merchant management view)
    public func fetchAllModifierGroups(restaurantId: UUID) async throws -> [ModifierGroup] {
        try await client.from("modifier_groups")
            .select("*, modifier_options(*)")
            .eq("restaurant_id", value: restaurantId.uuidString)
            .order("sort_order")
            .execute()
            .value
    }

    // MARK: - Merchant Menu Management

    /// Fetch all menu items including unavailable ones (merchant view)
    public func fetchAllMenuItems(restaurantId: UUID) async throws -> [MenuItem] {
        try await client.from("menu_items")
            .select()
            .eq("restaurant_id", value: restaurantId.uuidString)
            .order("sort_order")
            .execute()
            .value
    }

    public func toggleMenuItemAvailability(id: UUID, isAvailable: Bool) async throws {
        try await client.from("menu_items")
            .update(["is_available": AnyJSON.bool(isAvailable)])
            .eq("id", value: id.uuidString)
            .execute()
    }

    public func updateStock(menuItemId: UUID, count: Int?) async throws {
        let value: AnyJSON = count.map { AnyJSON.integer($0) } ?? .null
        try await client.from("menu_items")
            .update(["stock_count": value])
            .eq("id", value: menuItemId.uuidString)
            .execute()
    }

    public func updateMenuItem(
        id: UUID,
        name: String? = nil,
        description: String? = nil,
        price: Double? = nil,
        isAvailable: Bool? = nil,
        sortOrder: Int? = nil,
        stockCount: Int? = nil
    ) async throws {
        var updates: [String: AnyJSON] = [:]
        if let name { updates["name"] = .string(name) }
        if let description { updates["description"] = .string(description) }
        if let price { updates["price"] = .double(price) }
        if let isAvailable { updates["is_available"] = .bool(isAvailable) }
        if let sortOrder { updates["sort_order"] = .integer(sortOrder) }
        if let stockCount { updates["stock_count"] = .integer(stockCount) }
        guard !updates.isEmpty else { return }
        try await client.from("menu_items")
            .update(updates)
            .eq("id", value: id.uuidString)
            .execute()
    }

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
        try await client.from("restaurants")
            .update(["is_accepting_orders": AnyJSON.bool(accepting)])
            .eq("id", value: restaurantId.uuidString)
            .execute()
    }

    // MARK: - Chat Messages

    public func sendMessage(orderId: UUID, body: String) async throws -> ChatMessage {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        let insert = ChatMessageInsert(orderId: orderId, senderId: uid, body: body)
        return try await client.from("chat_messages")
            .insert(insert)
            .select()
            .single()
            .execute()
            .value
    }

    public func fetchMessages(orderId: UUID) async throws -> [ChatMessage] {
        guard AuthService.shared.userId != nil else {
            throw ServiceError.notAuthenticated
        }
        return try await client.from("chat_messages")
            .select()
            .eq("order_id", value: orderId.uuidString)
            .order("created_at")
            .execute()
            .value
    }

    public func markMessagesAsRead(orderId: UUID) async throws {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        try await client.from("chat_messages")
            .update(["read_at": AnyJSON.string(Self.isoFormatter.string(from: Date()))])
            .eq("order_id", value: orderId.uuidString)
            .neq("sender_id", value: uid.uuidString)
            .is("read_at", value: nil)
            .execute()
    }

    public func fetchUnreadCount(orderId: UUID) async throws -> Int {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        let rows: [IdRow] = try await client.from("chat_messages")
            .select("id")
            .eq("order_id", value: orderId.uuidString)
            .neq("sender_id", value: uid.uuidString)
            .is("read_at", value: nil)
            .execute()
            .value
        return rows.count
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
        let items = try await fetchAllMenuItems(restaurantId: restaurant.id)
        let hours = try await fetchRestaurantHours(restaurantId: restaurant.id)

        return OnboardingProgress(
            hasRestaurant: true,
            hasName: !restaurant.name.isEmpty,
            hasAddress: restaurant.address != nil && !restaurant.address!.isEmpty,
            hasAtLeastOneCategory: !categories.isEmpty,
            hasAtLeastOneMenuItem: !items.isEmpty,
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

    // MARK: - Menu Category CRUD

    public func createMenuCategory(_ insert: MenuCategoryInsert) async throws -> MenuCategory {
        try await client.from("menu_categories")
            .insert(insert)
            .select()
            .single()
            .execute()
            .value
    }

    public func updateMenuCategory(id: UUID, name: String? = nil, sortOrder: Int? = nil) async throws {
        var updates: [String: AnyJSON] = [:]
        if let name { updates["name"] = .string(name) }
        if let sortOrder { updates["sort_order"] = .integer(sortOrder) }
        guard !updates.isEmpty else { return }
        try await client.from("menu_categories")
            .update(updates)
            .eq("id", value: id.uuidString)
            .execute()
    }

    public func deleteMenuCategory(id: UUID) async throws {
        // Pre-check: category must be empty
        let items: [IdRow] = try await client.from("menu_items")
            .select("id")
            .eq("category_id", value: id.uuidString)
            .limit(1)
            .execute()
            .value
        guard items.isEmpty else { throw ServiceError.categoryNotEmpty }
        try await client.from("menu_categories")
            .delete()
            .eq("id", value: id.uuidString)
            .execute()
    }

    // MARK: - Menu Item CRUD

    public func createMenuItem(_ insert: MenuItemInsert) async throws -> MenuItem {
        try await client.from("menu_items")
            .insert(insert)
            .select()
            .single()
            .execute()
            .value
    }

    public func deleteMenuItem(id: UUID) async throws {
        try await client.from("menu_items")
            .delete()
            .eq("id", value: id.uuidString)
            .execute()
    }

    // MARK: - Modifier Group CRUD

    public func createModifierGroup(_ insert: ModifierGroupInsert) async throws -> ModifierGroup {
        try await client.from("modifier_groups")
            .insert(insert)
            .select("*, modifier_options(*)")
            .single()
            .execute()
            .value
    }

    public func updateModifierGroup(
        id: UUID, name: String? = nil, isRequired: Bool? = nil,
        minSelections: Int? = nil, maxSelections: Int? = nil, sortOrder: Int? = nil
    ) async throws {
        var updates: [String: AnyJSON] = [:]
        if let name { updates["name"] = .string(name) }
        if let isRequired { updates["is_required"] = .bool(isRequired) }
        if let minSelections { updates["min_selections"] = .integer(minSelections) }
        if let maxSelections { updates["max_selections"] = .integer(maxSelections) }
        if let sortOrder { updates["sort_order"] = .integer(sortOrder) }
        guard !updates.isEmpty else { return }
        try await client.from("modifier_groups")
            .update(updates)
            .eq("id", value: id.uuidString)
            .execute()
    }

    public func deleteModifierGroup(id: UUID) async throws {
        try await client.from("modifier_groups")
            .delete()
            .eq("id", value: id.uuidString)
            .execute()
    }

    // MARK: - Modifier Option CRUD

    public func createModifierOption(_ insert: ModifierOptionInsert) async throws -> ModifierOption {
        try await client.from("modifier_options")
            .insert(insert)
            .select()
            .single()
            .execute()
            .value
    }

    public func updateModifierOption(
        id: UUID, name: String? = nil, priceAdjustment: Double? = nil,
        isAvailable: Bool? = nil, sortOrder: Int? = nil
    ) async throws {
        var updates: [String: AnyJSON] = [:]
        if let name { updates["name"] = .string(name) }
        if let priceAdjustment { updates["price_adjustment"] = .double(priceAdjustment) }
        if let isAvailable { updates["is_available"] = .bool(isAvailable) }
        if let sortOrder { updates["sort_order"] = .integer(sortOrder) }
        guard !updates.isEmpty else { return }
        try await client.from("modifier_options")
            .update(updates)
            .eq("id", value: id.uuidString)
            .execute()
    }

    public func deleteModifierOption(id: UUID) async throws {
        try await client.from("modifier_options")
            .delete()
            .eq("id", value: id.uuidString)
            .execute()
    }

    // MARK: - Modifier Group ↔ Menu Item Linking

    public func linkModifierGroup(menuItemId: UUID, modifierGroupId: UUID) async throws {
        let link = MenuItemModifierGroup(menuItemId: menuItemId, modifierGroupId: modifierGroupId)
        try await client.from("menu_item_modifier_groups")
            .insert(link)
            .execute()
    }

    public func unlinkModifierGroup(menuItemId: UUID, modifierGroupId: UUID) async throws {
        try await client.from("menu_item_modifier_groups")
            .delete()
            .eq("menu_item_id", value: menuItemId.uuidString)
            .eq("modifier_group_id", value: modifierGroupId.uuidString)
            .execute()
    }

    // MARK: - Image Upload

    private static let maxImageSize = 5 * 1024 * 1024 // 5 MB
    private static let allowedImageFormats = ["jpg", "jpeg", "png", "webp"]

    /// Upload restaurant image to Supabase Storage, returns public URL string
    public func uploadRestaurantImage(restaurantId: UUID, imageData: Data, fileExtension: String) async throws -> String {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        try validateImage(data: imageData, fileExtension: fileExtension)
        let path = "\(uid.uuidString)/\(restaurantId.uuidString).\(fileExtension)"
        try await client.storage.from("restaurant-images")
            .upload(path, data: imageData, options: .init(contentType: "image/\(fileExtension)", upsert: true))
        let publicURL = try client.storage.from("restaurant-images").getPublicURL(path: path)
        // Update restaurant image_url
        try await client.from("restaurants")
            .update(["image_url": AnyJSON.string(publicURL.absoluteString)])
            .eq("id", value: restaurantId.uuidString)
            .execute()
        return publicURL.absoluteString
    }

    /// Upload menu item image to Supabase Storage, returns public URL string
    public func uploadMenuItemImage(menuItemId: UUID, imageData: Data, fileExtension: String) async throws -> String {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        try validateImage(data: imageData, fileExtension: fileExtension)
        let path = "\(uid.uuidString)/\(menuItemId.uuidString).\(fileExtension)"
        try await client.storage.from("menu-item-images")
            .upload(path, data: imageData, options: .init(contentType: "image/\(fileExtension)", upsert: true))
        let publicURL = try client.storage.from("menu-item-images").getPublicURL(path: path)
        // Update menu item image_url
        try await client.from("menu_items")
            .update(["image_url": AnyJSON.string(publicURL.absoluteString)])
            .eq("id", value: menuItemId.uuidString)
            .execute()
        return publicURL.absoluteString
    }

    /// Delete an image from storage
    public func deleteImage(bucket: String, path: String) async throws {
        try await client.storage.from(bucket).remove(paths: [path])
    }

    private func validateImage(data: Data, fileExtension: String) throws {
        guard data.count <= Self.maxImageSize else {
            throw ServiceError.imageTooLarge
        }
        guard Self.allowedImageFormats.contains(fileExtension.lowercased()) else {
            throw ServiceError.unsupportedImageFormat
        }
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
