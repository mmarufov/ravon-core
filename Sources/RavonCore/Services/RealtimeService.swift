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

public struct CourierLocationEvent: Sendable {
    public let courierId: UUID
    public let latitude: Double
    public let longitude: Double
    public let heading: Double?
    public let speed: Double?

    public init(courierId: UUID, latitude: Double, longitude: Double, heading: Double?, speed: Double?) {
        self.courierId = courierId
        self.latitude = latitude
        self.longitude = longitude
        self.heading = heading
        self.speed = speed
    }
}

public struct ChatMessageEvent: Sendable {
    public let message: ChatMessage

    public init(message: ChatMessage) {
        self.message = message
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
    private var courierLocationChannel: RealtimeChannelV2?
    private var orderTask: Task<Void, Never>?
    private var menuTask: Task<Void, Never>?
    private var courierLocationTask: Task<Void, Never>?
    private var chatChannel: RealtimeChannelV2?
    private var chatTask: Task<Void, Never>?

    @Published public private(set) var lastOrderChange: OrderChangeEvent?
    @Published public private(set) var lastMenuItemChange: MenuItemChangeEvent?
    @Published public private(set) var lastCourierLocationChange: CourierLocationEvent?
    @Published public private(set) var lastChatMessage: ChatMessageEvent?

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

    // MARK: - Courier Location Subscriptions

    /// Subscribe to a courier's location updates (consumer tracking delivery on map)
    public func subscribeToCourierLocation(courierId: UUID) async throws {
        await unsubscribeFromCourierLocation()
        let channel = client.channel("courier-location-\(courierId.uuidString)")
        let changes = channel.postgresChange(
            UpdateAction.self,
            schema: "public",
            table: "courier_locations",
            filter: .eq("courier_id", value: courierId)
        )
        try await channel.subscribeWithError()
        courierLocationChannel = channel

        courierLocationTask = Task { [weak self] in
            for await change in changes {
                guard let self, !Task.isCancelled else { return }
                let lat = change.record["latitude"]
                    .flatMap({ if case .double(let d) = $0 { return d } else { return nil } })
                let lng = change.record["longitude"]
                    .flatMap({ if case .double(let d) = $0 { return d } else { return nil } })
                let heading = change.record["heading"]
                    .flatMap({ if case .double(let d) = $0 { return d } else { return nil } })
                let speed = change.record["speed"]
                    .flatMap({ if case .double(let d) = $0 { return d } else { return nil } })
                if let lat, let lng {
                    await MainActor.run {
                        self.lastCourierLocationChange = CourierLocationEvent(
                            courierId: courierId,
                            latitude: lat,
                            longitude: lng,
                            heading: heading,
                            speed: speed
                        )
                    }
                }
            }
        }
    }

    // MARK: - Chat Message Subscriptions

    /// Subscribe to new messages for a specific order (consumer or courier in active chat)
    public func subscribeToChat(orderId: UUID) async throws {
        await unsubscribeFromChat()
        let channel = client.channel("chat-\(orderId.uuidString)")
        let changes = channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "chat_messages",
            filter: .eq("order_id", value: orderId)
        )
        try await channel.subscribeWithError()
        chatChannel = channel

        chatTask = Task { [weak self] in
            for await change in changes {
                guard let self, !Task.isCancelled else { return }
                let id = change.record["id"]
                    .flatMap({ if case .string(let s) = $0 { return s } else { return nil } })
                    .flatMap({ UUID(uuidString: $0) })
                let senderId = change.record["sender_id"]
                    .flatMap({ if case .string(let s) = $0 { return s } else { return nil } })
                    .flatMap({ UUID(uuidString: $0) })
                let body = change.record["body"]
                    .flatMap({ if case .string(let s) = $0 { return s } else { return nil } })
                let createdAtStr = change.record["created_at"]
                    .flatMap({ if case .string(let s) = $0 { return s } else { return nil } })

                if let id, let senderId, let body {
                    let createdAt = createdAtStr
                        .flatMap({ ISO8601DateFormatter().date(from: $0) }) ?? Date()
                    let message = ChatMessage(
                        id: id,
                        orderId: orderId,
                        senderId: senderId,
                        body: body,
                        createdAt: createdAt
                    )
                    await MainActor.run {
                        self.lastChatMessage = ChatMessageEvent(message: message)
                    }
                }
            }
        }
    }

    // MARK: - Unsubscribe

    public func unsubscribeFromCourierLocation() async {
        courierLocationTask?.cancel()
        courierLocationTask = nil
        if let channel = courierLocationChannel {
            await client.removeChannel(channel)
            courierLocationChannel = nil
        }
    }

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

    public func unsubscribeFromChat() async {
        chatTask?.cancel()
        chatTask = nil
        if let channel = chatChannel {
            await client.removeChannel(channel)
            chatChannel = nil
        }
    }

    public func unsubscribeAll() async {
        await unsubscribeFromOrders()
        await unsubscribeFromMenu()
        await unsubscribeFromCourierLocation()
        await unsubscribeFromChat()
    }
}
