import Foundation

public enum OrderStatus: String, Codable, CaseIterable, Sendable {
    case created
    case accepted
    case preparing
    case ready
    case assigned
    case delivering
    case delivered
    case cancelled

    public var displayName: String {
        switch self {
        case .created:    return "Создан"
        case .accepted:   return "Принят"
        case .preparing:  return "Готовится"
        case .ready:      return "Готов"
        case .assigned:   return "Назначен курьер"
        case .delivering: return "В пути"
        case .delivered:  return "Доставлен"
        case .cancelled:  return "Отменён"
        }
    }

    public var isActive: Bool {
        switch self {
        case .delivered, .cancelled: return false
        default: return true
        }
    }

    public var stepIndex: Int {
        switch self {
        case .created:    return 0
        case .accepted:   return 1
        case .preparing:  return 2
        case .ready:      return 3
        case .assigned:   return 4
        case .delivering: return 5
        case .delivered:  return 6
        case .cancelled:  return -1
        }
    }
}

public struct Order: Codable, Identifiable, Sendable {
    public let id: UUID
    public let userId: UUID
    public let restaurantId: UUID
    public let addressId: UUID?
    public let courierId: UUID?
    public let status: OrderStatus
    public let subtotal: Double
    public let deliveryFee: Double
    public let total: Double
    public let deliveryAddressSnapshot: AddressSnapshot?
    public let notes: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let restaurant: Restaurant?
    public let orderItems: [OrderItem]?

    public init(id: UUID, userId: UUID, restaurantId: UUID, addressId: UUID? = nil, courierId: UUID? = nil, status: OrderStatus, subtotal: Double, deliveryFee: Double, total: Double, deliveryAddressSnapshot: AddressSnapshot? = nil, notes: String? = nil, createdAt: Date, updatedAt: Date, restaurant: Restaurant? = nil, orderItems: [OrderItem]? = nil) {
        self.id = id
        self.userId = userId
        self.restaurantId = restaurantId
        self.addressId = addressId
        self.courierId = courierId
        self.status = status
        self.subtotal = subtotal
        self.deliveryFee = deliveryFee
        self.total = total
        self.deliveryAddressSnapshot = deliveryAddressSnapshot
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.restaurant = restaurant
        self.orderItems = orderItems
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case restaurantId = "restaurant_id"
        case addressId = "address_id"
        case courierId = "courier_id"
        case status, subtotal
        case deliveryFee = "delivery_fee"
        case total
        case deliveryAddressSnapshot = "delivery_address_snapshot"
        case notes
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case restaurant = "restaurants"
        case orderItems = "order_items"
    }
}

public struct OrderItem: Codable, Identifiable, Sendable {
    public let id: UUID
    public let orderId: UUID
    public let menuItemId: UUID
    public let quantity: Int
    public let unitPrice: Double
    public let totalPrice: Double
    public let itemName: String

    public init(id: UUID, orderId: UUID, menuItemId: UUID, quantity: Int, unitPrice: Double, totalPrice: Double, itemName: String) {
        self.id = id
        self.orderId = orderId
        self.menuItemId = menuItemId
        self.quantity = quantity
        self.unitPrice = unitPrice
        self.totalPrice = totalPrice
        self.itemName = itemName
    }

    enum CodingKeys: String, CodingKey {
        case id
        case orderId = "order_id"
        case menuItemId = "menu_item_id"
        case quantity
        case unitPrice = "unit_price"
        case totalPrice = "total_price"
        case itemName = "item_name"
    }
}

public struct OrderStatusHistory: Codable, Identifiable, Sendable {
    public let id: UUID
    public let orderId: UUID
    public let status: OrderStatus
    public let changedBy: UUID?
    public let notes: String?
    public let createdAt: Date

    public init(id: UUID, orderId: UUID, status: OrderStatus, changedBy: UUID? = nil, notes: String? = nil, createdAt: Date) {
        self.id = id
        self.orderId = orderId
        self.status = status
        self.changedBy = changedBy
        self.notes = notes
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case orderId = "order_id"
        case status
        case changedBy = "changed_by"
        case notes
        case createdAt = "created_at"
    }
}
