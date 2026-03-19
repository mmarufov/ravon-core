import Foundation
import Supabase

public struct OrderChangeEvent: Sendable {
    public let orderId: UUID
    public let oldStatus: OrderStatus?
    public let newStatus: OrderStatus
    public let record: [String: AnyJSON]

    public init(orderId: UUID, oldStatus: OrderStatus?, newStatus: OrderStatus, record: [String: AnyJSON]) {
        self.orderId = orderId
        self.oldStatus = oldStatus
        self.newStatus = newStatus
        self.record = record
    }
}

public struct MenuItemChangeEvent: Sendable {
    public let menuItemId: UUID
    public let restaurantId: UUID
    public let isAvailable: Bool

    public init(menuItemId: UUID, restaurantId: UUID, isAvailable: Bool) {
        self.menuItemId = menuItemId
        self.restaurantId = restaurantId
        self.isAvailable = isAvailable
    }
}

@MainActor
public final class RealtimeService: ObservableObject {
    public static let shared = RealtimeService()

    private var client: SupabaseClient { AuthService.shared.supabaseClient }

    private var orderChannel: RealtimeChannelV2?
    private var menuChannel: RealtimeChannelV2?
    private var orderTask: Task<Void, Never>?
    private var menuTask: Task<Void, Never>?

    @Published public private(set) var lastOrderChange: OrderChangeEvent?
    @Published public private(set) var lastMenuItemChange: MenuItemChangeEvent?

    public init() {}

    // MARK: - Order Subscriptions

    /// Subscribe to changes on a specific order (consumer tracking their order)
    public func subscribeToOrder(orderId: UUID) async throws {
        await unsubscribeFromOrders()
        let channel = client.channel("order-\(orderId.uuidString)")
        let changes = channel.postgresChange(
            UpdateAction.self,
            schema: "public",
            table: "orders",
            filter: .eq("id", value: orderId)
        )
        try await channel.subscribeWithError()
        orderChannel = channel

        orderTask = Task { [weak self] in
            for await change in changes {
                guard let self, !Task.isCancelled else { return }
                let newStatus = change.record["status"]
                    .flatMap({ if case .string(let s) = $0 { return s } else { return nil } })
                    .flatMap({ OrderStatus(rawValue: $0) })
                let oldStatus = change.oldRecord["status"]
                    .flatMap({ if case .string(let s) = $0 { return s } else { return nil } })
                    .flatMap({ OrderStatus(rawValue: $0) })
                if let newStatus {
                    await MainActor.run {
                        self.lastOrderChange = OrderChangeEvent(
                            orderId: orderId,
                            oldStatus: oldStatus,
                            newStatus: newStatus,
                            record: change.record
                        )
                    }
                }
            }
        }
    }

    /// Subscribe to all orders for a restaurant (merchant dashboard)
    public func subscribeToRestaurantOrders(restaurantId: UUID) async throws {
        await unsubscribeFromOrders()
        let channel = client.channel("restaurant-orders-\(restaurantId.uuidString)")
        let changes = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "orders",
            filter: .eq("restaurant_id", value: restaurantId)
        )
        try await channel.subscribeWithError()
        orderChannel = channel

        orderTask = Task { [weak self] in
            for await change in changes {
                guard let self, !Task.isCancelled else { return }
                switch change {
                case .insert(let action):
                    let status = action.record["status"]
                        .flatMap({ if case .string(let s) = $0 { return s } else { return nil } })
                        .flatMap({ OrderStatus(rawValue: $0) })
                    let id = action.record["id"]
                        .flatMap({ if case .string(let s) = $0 { return s } else { return nil } })
                        .flatMap({ UUID(uuidString: $0) })
                    if let status, let id {
                        await MainActor.run {
                            self.lastOrderChange = OrderChangeEvent(
                                orderId: id, oldStatus: nil, newStatus: status, record: action.record
                            )
                        }
                    }
                case .update(let action):
                    let newStatus = action.record["status"]
                        .flatMap({ if case .string(let s) = $0 { return s } else { return nil } })
                        .flatMap({ OrderStatus(rawValue: $0) })
                    let oldStatus = action.oldRecord["status"]
                        .flatMap({ if case .string(let s) = $0 { return s } else { return nil } })
                        .flatMap({ OrderStatus(rawValue: $0) })
                    let id = action.record["id"]
                        .flatMap({ if case .string(let s) = $0 { return s } else { return nil } })
                        .flatMap({ UUID(uuidString: $0) })
                    if let newStatus, let id {
                        await MainActor.run {
                            self.lastOrderChange = OrderChangeEvent(
                                orderId: id, oldStatus: oldStatus, newStatus: newStatus, record: action.record
                            )
                        }
                    }
                case .delete:
                    break
                }
            }
        }
    }

    /// Subscribe to orders assigned to a courier
    public func subscribeToCourierOrders(courierId: UUID) async throws {
        await unsubscribeFromOrders()
        let channel = client.channel("courier-orders-\(courierId.uuidString)")
        let changes = channel.postgresChange(
            UpdateAction.self,
            schema: "public",
            table: "orders",
            filter: .eq("courier_id", value: courierId)
        )
        try await channel.subscribeWithError()
        orderChannel = channel

        orderTask = Task { [weak self] in
            for await change in changes {
                guard let self, !Task.isCancelled else { return }
                let newStatus = change.record["status"]
                    .flatMap({ if case .string(let s) = $0 { return s } else { return nil } })
                    .flatMap({ OrderStatus(rawValue: $0) })
                let oldStatus = change.oldRecord["status"]
                    .flatMap({ if case .string(let s) = $0 { return s } else { return nil } })
                    .flatMap({ OrderStatus(rawValue: $0) })
                let id = change.record["id"]
                    .flatMap({ if case .string(let s) = $0 { return s } else { return nil } })
                    .flatMap({ UUID(uuidString: $0) })
                if let newStatus, let id {
                    await MainActor.run {
                        self.lastOrderChange = OrderChangeEvent(
                            orderId: id, oldStatus: oldStatus, newStatus: newStatus, record: change.record
                        )
                    }
                }
            }
        }
    }

    // MARK: - Menu Item Subscriptions

    /// Subscribe to menu item availability changes for a restaurant
    public func subscribeToMenuChanges(restaurantId: UUID) async throws {
        await unsubscribeFromMenu()
        let channel = client.channel("menu-\(restaurantId.uuidString)")
        let changes = channel.postgresChange(
            UpdateAction.self,
            schema: "public",
            table: "menu_items",
            filter: .eq("restaurant_id", value: restaurantId)
        )
        try await channel.subscribeWithError()
        menuChannel = channel

        menuTask = Task { [weak self] in
            for await change in changes {
                guard let self, !Task.isCancelled else { return }
                let itemId = change.record["id"]
                    .flatMap({ if case .string(let s) = $0 { return s } else { return nil } })
                    .flatMap({ UUID(uuidString: $0) })
                let isAvailable = change.record["is_available"]
                    .flatMap({ if case .bool(let b) = $0 { return b } else { return nil } })
                if let itemId, let isAvailable {
                    await MainActor.run {
                        self.lastMenuItemChange = MenuItemChangeEvent(
                            menuItemId: itemId, restaurantId: restaurantId, isAvailable: isAvailable
                        )
                    }
                }
            }
        }
    }

    // MARK: - Unsubscribe

    public func unsubscribeFromOrders() async {
        orderTask?.cancel()
        orderTask = nil
        if let channel = orderChannel {
            await client.removeChannel(channel)
            orderChannel = nil
        }
    }

    public func unsubscribeFromMenu() async {
        menuTask?.cancel()
        menuTask = nil
        if let channel = menuChannel {
            await client.removeChannel(channel)
            menuChannel = nil
        }
    }

    public func unsubscribeAll() async {
        await unsubscribeFromOrders()
        await unsubscribeFromMenu()
    }
}
