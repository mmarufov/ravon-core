import Foundation

// MARK: - Restaurant Status

public enum RestaurantStatus: String, Codable, Sendable {
    case draft
    case active
    case paused
    case closed
}

// MARK: - Restaurant

public struct Restaurant: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let description: String?
    public let imageUrl: String?
    public let cuisineType: String
    public let rating: Double
    public let deliveryTimeMin: Int
    public let deliveryFee: Double
    public let minOrderAmount: Double
    public let address: String?
    public let latitude: Double?
    public let longitude: Double?
    public let openingTime: String?
    public let closingTime: String?
    public let maxConcurrentOrders: Int?
    public let isAcceptingOrders: Bool
    public let acceptingOrdersUntil: Date?
    public let ownerId: UUID?
    public let restaurantStatus: RestaurantStatus

    public init(
        id: UUID, name: String, description: String? = nil, imageUrl: String? = nil,
        cuisineType: String, rating: Double, deliveryTimeMin: Int,
        deliveryFee: Double, minOrderAmount: Double,
        address: String? = nil, latitude: Double? = nil, longitude: Double? = nil,
        openingTime: String? = nil, closingTime: String? = nil,
        maxConcurrentOrders: Int? = nil, isAcceptingOrders: Bool = true,
        acceptingOrdersUntil: Date? = nil,
        ownerId: UUID? = nil, restaurantStatus: RestaurantStatus = .active
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.imageUrl = imageUrl
        self.cuisineType = cuisineType
        self.rating = rating
        self.deliveryTimeMin = deliveryTimeMin
        self.deliveryFee = deliveryFee
        self.minOrderAmount = minOrderAmount
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.openingTime = openingTime
        self.closingTime = closingTime
        self.maxConcurrentOrders = maxConcurrentOrders
        self.isAcceptingOrders = isAcceptingOrders
        self.acceptingOrdersUntil = acceptingOrdersUntil
        self.ownerId = ownerId
        self.restaurantStatus = restaurantStatus
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.imageUrl = try c.decodeIfPresent(String.self, forKey: .imageUrl)
        self.cuisineType = try c.decode(String.self, forKey: .cuisineType)
        self.rating = try c.decode(Double.self, forKey: .rating)
        self.deliveryTimeMin = try c.decode(Int.self, forKey: .deliveryTimeMin)
        self.deliveryFee = try c.decode(Double.self, forKey: .deliveryFee)
        self.minOrderAmount = try c.decode(Double.self, forKey: .minOrderAmount)
        self.address = try c.decodeIfPresent(String.self, forKey: .address)
        self.latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        self.longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        self.openingTime = try c.decodeIfPresent(String.self, forKey: .openingTime)
        self.closingTime = try c.decodeIfPresent(String.self, forKey: .closingTime)
        self.maxConcurrentOrders = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentOrders)
        self.isAcceptingOrders = try c.decodeIfPresent(Bool.self, forKey: .isAcceptingOrders) ?? true
        self.acceptingOrdersUntil = try c.decodeIfPresent(Date.self, forKey: .acceptingOrdersUntil)
        self.ownerId = try c.decodeIfPresent(UUID.self, forKey: .ownerId)
        self.restaurantStatus = try c.decodeIfPresent(RestaurantStatus.self, forKey: .restaurantStatus) ?? .active
    }

    /// Best-effort client-side hint of whether the restaurant should appear orderable in UI.
    /// Server is the source of truth — always re-validate via `validate_cart` / `create_order`.
    /// This is only for optimistic CTA states (e.g. enabling/disabling buttons before server round-trip).
    public var isOrderableHint: Bool {
        restaurantStatus == .active && isAcceptingOrders
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case imageUrl = "image_url"
        case cuisineType = "cuisine_type"
        case rating
        case deliveryTimeMin = "delivery_time_min"
        case deliveryFee = "delivery_fee"
        case minOrderAmount = "min_order_amount"
        case address, latitude, longitude
        case openingTime = "opening_time"
        case closingTime = "closing_time"
        case maxConcurrentOrders = "max_concurrent_orders"
        case isAcceptingOrders = "is_accepting_orders"
        case acceptingOrdersUntil = "accepting_orders_until"
        case ownerId = "owner_id"
        case restaurantStatus = "restaurant_status"
    }
}

// MARK: - Restaurant Insert

public struct RestaurantInsert: Encodable, Sendable {
    public let name: String
    public let description: String?
    public let cuisineType: String
    public let address: String?
    public let latitude: Double?
    public let longitude: Double?
    public let deliveryFee: Double
    public let minOrderAmount: Double
    public let deliveryTimeMin: Int

    public init(
        name: String, description: String? = nil, cuisineType: String,
        address: String? = nil, latitude: Double? = nil, longitude: Double? = nil,
        deliveryFee: Double, minOrderAmount: Double, deliveryTimeMin: Int
    ) {
        self.name = name
        self.description = description
        self.cuisineType = cuisineType
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.deliveryFee = deliveryFee
        self.minOrderAmount = minOrderAmount
        self.deliveryTimeMin = deliveryTimeMin
    }

    enum CodingKeys: String, CodingKey {
        case name, description, address, latitude, longitude
        case cuisineType = "cuisine_type"
        case deliveryFee = "delivery_fee"
        case minOrderAmount = "min_order_amount"
        case deliveryTimeMin = "delivery_time_min"
    }
}
