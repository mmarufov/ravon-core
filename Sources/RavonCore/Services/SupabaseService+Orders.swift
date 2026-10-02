import Foundation
import Supabase

extension SupabaseService {
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
        public let p_scheduled_for: Date?

        public init(p_restaurant_id: UUID, p_address_id: UUID, p_items: [OrderItemParam], p_notes: String?, p_scheduled_for: Date? = nil) {
            self.p_restaurant_id = p_restaurant_id
            self.p_address_id = p_address_id
            self.p_items = p_items
            self.p_notes = p_notes
            self.p_scheduled_for = p_scheduled_for
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

    /// Place an order. Pass `scheduledFor` (in the future, within next 7 days, within restaurant hours)
    /// to create a `scheduled` order — held by the platform until activation.
    public func createOrder(
        restaurantId: UUID,
        addressId: UUID,
        items: [(menuItemId: UUID, quantity: Int)],
        notes: String?,
        scheduledFor: Date? = nil
    ) async throws -> UUID {
        let itemsParam = items.map { item in
            OrderItemParam(menu_item_id: item.menuItemId, quantity: item.quantity)
        }
        let params = CreateOrderParams(
            p_restaurant_id: restaurantId,
            p_address_id: addressId,
            p_items: itemsParam,
            p_notes: notes,
            p_scheduled_for: scheduledFor
        )
        let result: String = try await client.rpc("create_order", params: params).execute().value
        guard let uuid = UUID(uuidString: result) else {
            throw ServiceError.invalidResponse
        }
        return uuid
    }

    // MARK: - Cart validation (pre-checkout truth gate)

    public struct ValidateCartParams: Encodable, Sendable {
        public let p_restaurant_id: UUID
        public let p_items: [OrderItemParam]
        public let p_scheduled_for: Date?
    }

    /// Server-side validation of cart contents. Called inside the consumer's
    /// confirm-tap loading screen before `createOrder`. Read-only, locks no rows,
    /// idempotent. Returns a structured payload the UI can render diffs from.
    public func validateCart(
        restaurantId: UUID,
        items: [(menuItemId: UUID, quantity: Int)],
        scheduledFor: Date? = nil
    ) async throws -> CartValidationResult {
        let params = ValidateCartParams(
            p_restaurant_id: restaurantId,
            p_items: items.map { OrderItemParam(menu_item_id: $0.menuItemId, quantity: $0.quantity) },
            p_scheduled_for: scheduledFor
        )
        return try await client.rpc("validate_cart", params: params).execute().value
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

    // MARK: - Order Lifecycle (Consumer)

    public func cancelOrder(orderId: UUID, reason: String?) async throws {
        struct Params: Encodable { let p_order_id: UUID; let p_reason: String? }
        try await client.rpc("cancel_order_by_consumer", params: Params(
            p_order_id: orderId, p_reason: reason
        )).execute()
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
        guard amount >= 0 else { return }
        struct Params: Encodable { let p_order_id: UUID; let p_amount: Double }
        try await client.rpc("add_tip", params: Params(
            p_order_id: orderId, p_amount: amount
        )).execute()
    }
}
