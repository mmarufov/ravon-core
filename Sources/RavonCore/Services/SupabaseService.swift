import Foundation
import Supabase

public enum ServiceError: LocalizedError, Sendable {
    case notAuthenticated
    case invalidResponse
    case orderNotFound
    case invalidStatusTransition
    case unauthorized
    case invalidVerificationCode

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:        return "Пользователь не авторизован"
        case .invalidResponse:         return "Ошибка ответа сервера"
        case .orderNotFound:           return "Заказ не найден"
        case .invalidStatusTransition: return "Недопустимый переход статуса"
        case .unauthorized:            return "Недостаточно прав"
        case .invalidVerificationCode: return "Неверный код подтверждения"
        }
    }
}

@MainActor
public final class SupabaseService {
    public static let shared = SupabaseService()

    private var client: SupabaseClient { AuthService.shared.supabaseClient }

    public init() {}

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
        try await client.from("profiles")
            .update([
                "full_name": fullName,
                "phone": phone ?? ""
            ])
            .eq("id", value: uid.uuidString)
            .execute()
    }

    // MARK: - Restaurants

    public func fetchRestaurants() async throws -> [Restaurant] {
        try await client.from("restaurants")
            .select()
            .eq("is_active", value: true)
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

    /// Update order status (used by Merchant and Courier apps)
    public func updateOrderStatus(orderId: UUID, status: OrderStatus) async throws {
        try await client.from("orders")
            .update(["status": status.rawValue])
            .eq("id", value: orderId.uuidString)
            .execute()
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
        try await client.from("orders")
            .update([
                "status": AnyJSON.string(OrderStatus.accepted.rawValue),
                "estimated_prep_time": AnyJSON.integer(estimatedPrepMinutes),
                "accepted_at": AnyJSON.string(ISO8601DateFormatter().string(from: Date())),
            ])
            .eq("id", value: orderId.uuidString)
            .execute()
    }

    public func rejectOrder(orderId: UUID, reason: String) async throws {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        try await client.from("orders")
            .update([
                "status": AnyJSON.string(OrderStatus.rejected.rawValue),
                "cancellation_reason": AnyJSON.string(reason),
                "cancelled_by": AnyJSON.string(uid.uuidString),
                "rejected_at": AnyJSON.string(ISO8601DateFormatter().string(from: Date())),
            ])
            .eq("id", value: orderId.uuidString)
            .execute()
    }

    public func markOrderReady(orderId: UUID) async throws {
        try await client.from("orders")
            .update(["status": AnyJSON.string(OrderStatus.ready.rawValue)])
            .eq("id", value: orderId.uuidString)
            .execute()
    }

    // MARK: - Order Lifecycle (Courier)

    public func courierArrivedAtRestaurant(orderId: UUID) async throws {
        try await client.from("orders")
            .update(["status": AnyJSON.string(OrderStatus.courierArrivedRestaurant.rawValue)])
            .eq("id", value: orderId.uuidString)
            .execute()
    }

    public func pickUpOrder(orderId: UUID, verificationCode: String) async throws {
        let order: Order = try await client.from("orders")
            .select("*")
            .eq("id", value: orderId.uuidString)
            .single()
            .execute()
            .value
        guard order.verificationCode == verificationCode else {
            throw ServiceError.invalidVerificationCode
        }
        try await client.from("orders")
            .update([
                "status": AnyJSON.string(OrderStatus.pickedUp.rawValue),
                "picked_up_at": AnyJSON.string(ISO8601DateFormatter().string(from: Date())),
            ])
            .eq("id", value: orderId.uuidString)
            .execute()
    }

    public func courierArrivedAtCustomer(orderId: UUID) async throws {
        try await client.from("orders")
            .update(["status": AnyJSON.string(OrderStatus.courierArrivedCustomer.rawValue)])
            .eq("id", value: orderId.uuidString)
            .execute()
    }

    public func deliverOrder(orderId: UUID) async throws {
        try await client.from("orders")
            .update([
                "status": AnyJSON.string(OrderStatus.delivered.rawValue),
                "delivered_at": AnyJSON.string(ISO8601DateFormatter().string(from: Date())),
            ])
            .eq("id", value: orderId.uuidString)
            .execute()
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
        try await client.from("orders")
            .update(updates)
            .eq("id", value: orderId.uuidString)
            .execute()
    }

    // MARK: - Order Lifecycle (Shared)

    public func assignCourier(orderId: UUID, courierId: UUID) async throws {
        try await client.from("orders")
            .update([
                "status": AnyJSON.string(OrderStatus.assigned.rawValue),
                "courier_id": AnyJSON.string(courierId.uuidString),
            ])
            .eq("id", value: orderId.uuidString)
            .execute()
    }

    public func addTip(orderId: UUID, amount: Double) async throws {
        try await client.from("orders")
            .update(["tip_amount": AnyJSON.double(amount)])
            .eq("id", value: orderId.uuidString)
            .execute()
    }
}
