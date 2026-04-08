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
    public let ownerId: UUID?
    public let restaurantStatus: RestaurantStatus

    public init(
        id: UUID, name: String, description: String? = nil, imageUrl: String? = nil,
        cuisineType: String, rating: Double, deliveryTimeMin: Int,
        deliveryFee: Double, minOrderAmount: Double,
        address: String? = nil, latitude: Double? = nil, longitude: Double? = nil,
        openingTime: String? = nil, closingTime: String? = nil,
        maxConcurrentOrders: Int? = nil, isAcceptingOrders: Bool = true,
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
        self.ownerId = ownerId
        self.restaurantStatus = restaurantStatus
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
