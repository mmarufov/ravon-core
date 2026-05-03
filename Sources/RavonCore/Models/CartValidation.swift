import Foundation

/// Why the restaurant as a whole is or isn't orderable right now (or at the requested scheduled time).
public enum OrderabilityReason: Codable, Hashable, Sendable {
    case ok
    case restaurantClosed
    case restaurantPaused
    case restaurantNotAccepting(until: Date?)
    case outOfHours(opensAt: Date?)
    case overloaded
    case minOrderNotMet(need: Double)

    private enum CodingKeys: String, CodingKey {
        case kind
        case until
        case opensAt = "opens_at"
        case need
    }

    private enum Kind: String, Codable {
        case ok = "OK"
        case restaurantClosed = "RESTAURANT_CLOSED"
        case restaurantPaused = "RESTAURANT_PAUSED"
        case restaurantNotAccepting = "RESTAURANT_NOT_ACCEPTING"
        case outOfHours = "OUT_OF_HOURS"
        case overloaded = "OVERLOADED"
        case minOrderNotMet = "MIN_ORDER_NOT_MET"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .ok:                     self = .ok
        case .restaurantClosed:       self = .restaurantClosed
        case .restaurantPaused:       self = .restaurantPaused
        case .restaurantNotAccepting: self = .restaurantNotAccepting(until: try c.decodeIfPresent(Date.self, forKey: .until))
        case .outOfHours:             self = .outOfHours(opensAt: try c.decodeIfPresent(Date.self, forKey: .opensAt))
        case .overloaded:             self = .overloaded
        case .minOrderNotMet:         self = .minOrderNotMet(need: try c.decode(Double.self, forKey: .need))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok:
            try c.encode(Kind.ok, forKey: .kind)
        case .restaurantClosed:
            try c.encode(Kind.restaurantClosed, forKey: .kind)
        case .restaurantPaused:
            try c.encode(Kind.restaurantPaused, forKey: .kind)
        case .restaurantNotAccepting(let until):
            try c.encode(Kind.restaurantNotAccepting, forKey: .kind)
            try c.encodeIfPresent(until, forKey: .until)
        case .outOfHours(let opensAt):
            try c.encode(Kind.outOfHours, forKey: .kind)
            try c.encodeIfPresent(opensAt, forKey: .opensAt)
        case .overloaded:
            try c.encode(Kind.overloaded, forKey: .kind)
        case .minOrderNotMet(let need):
            try c.encode(Kind.minOrderNotMet, forKey: .kind)
            try c.encode(need, forKey: .need)
        }
    }

    public var localizedMessage: String {
        switch self {
        case .ok:                                return ""
        case .restaurantClosed:                  return "Ресторан закрыт"
        case .restaurantPaused:                  return "Ресторан приостановлен"
        case .restaurantNotAccepting(let until):
            if let until { return "Ресторан не принимает заказы до \(Self.timeFmt.string(from: until))" }
            return "Ресторан не принимает заказы"
        case .outOfHours(let opensAt):
            if let opensAt { return "Откроется в \(Self.timeFmt.string(from: opensAt))" }
            return "Сейчас закрыто"
        case .overloaded:                        return "Ресторан перегружен заказами"
        case .minOrderNotMet(let need):          return "Минимальная сумма заказа: \(Int(need)) ₽"
        }
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone(identifier: "Asia/Dushanbe")
        return f
    }()
}

/// Per-line-item status returned by `validate_cart`.
public enum CartItemStatus: Codable, Hashable, Sendable {
    case ok
    case unavailable
    case insufficientStock(have: Int)
    case deleted
    case priceChanged(oldPrice: Double, newPrice: Double)

    private enum CodingKeys: String, CodingKey {
        case status
        case have
        case oldPrice = "old_price"
        case newPrice = "new_price"
    }

    private enum Kind: String, Codable {
        case ok = "OK"
        case unavailable = "UNAVAILABLE"
        case insufficientStock = "INSUFFICIENT_STOCK"
        case deleted = "DELETED"
        case priceChanged = "PRICE_CHANGED"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .status)
        switch kind {
        case .ok:                 self = .ok
        case .unavailable:        self = .unavailable
        case .insufficientStock:  self = .insufficientStock(have: try c.decode(Int.self, forKey: .have))
        case .deleted:            self = .deleted
        case .priceChanged:
            self = .priceChanged(
                oldPrice: try c.decode(Double.self, forKey: .oldPrice),
                newPrice: try c.decode(Double.self, forKey: .newPrice)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok:                                  try c.encode(Kind.ok, forKey: .status)
        case .unavailable:                         try c.encode(Kind.unavailable, forKey: .status)
        case .insufficientStock(let have):
            try c.encode(Kind.insufficientStock, forKey: .status)
            try c.encode(have, forKey: .have)
        case .deleted:                             try c.encode(Kind.deleted, forKey: .status)
        case .priceChanged(let old, let new):
            try c.encode(Kind.priceChanged, forKey: .status)
            try c.encode(old, forKey: .oldPrice)
            try c.encode(new, forKey: .newPrice)
        }
    }

    public var isOk: Bool { if case .ok = self { return true }; return false }
}

public struct CartItemValidation: Codable, Hashable, Sendable {
    public let menuItemId: UUID
    public let status: CartItemStatus

    public init(menuItemId: UUID, status: CartItemStatus) {
        self.menuItemId = menuItemId
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.menuItemId = try c.decode(UUID.self, forKey: .menuItemId)
        self.status = try CartItemStatus(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(menuItemId, forKey: .menuItemId)
        try status.encode(to: encoder)
    }

    enum CodingKeys: String, CodingKey {
        case menuItemId = "menu_item_id"
    }
}

/// Full structured response from `validate_cart` RPC.
public struct CartValidationResult: Codable, Sendable {
    public let orderable: Bool
    public let reason: OrderabilityReason
    public let items: [CartItemValidation]
    public let subtotal: Double
    public let minOrderAmount: Double
    public let minOrderMet: Bool

    public init(
        orderable: Bool, reason: OrderabilityReason,
        items: [CartItemValidation], subtotal: Double,
        minOrderAmount: Double, minOrderMet: Bool
    ) {
        self.orderable = orderable
        self.reason = reason
        self.items = items
        self.subtotal = subtotal
        self.minOrderAmount = minOrderAmount
        self.minOrderMet = minOrderMet
    }

    public var hasItemIssues: Bool { items.contains { !$0.status.isOk } }

    public var itemsByStatus: [UUID: CartItemStatus] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.menuItemId, $0.status) })
    }

    enum CodingKeys: String, CodingKey {
        case orderable, reason, items, subtotal
        case minOrderAmount = "min_order_amount"
        case minOrderMet = "min_order_met"
    }
}
