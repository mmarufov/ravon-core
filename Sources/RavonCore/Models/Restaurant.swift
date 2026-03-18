import Foundation

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
    public let isActive: Bool
    public let address: String?

    public init(id: UUID, name: String, description: String? = nil, imageUrl: String? = nil, cuisineType: String, rating: Double, deliveryTimeMin: Int, deliveryFee: Double, minOrderAmount: Double, isActive: Bool, address: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.imageUrl = imageUrl
        self.cuisineType = cuisineType
        self.rating = rating
        self.deliveryTimeMin = deliveryTimeMin
        self.deliveryFee = deliveryFee
        self.minOrderAmount = minOrderAmount
        self.isActive = isActive
        self.address = address
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case imageUrl = "image_url"
        case cuisineType = "cuisine_type"
        case rating
        case deliveryTimeMin = "delivery_time_min"
        case deliveryFee = "delivery_fee"
        case minOrderAmount = "min_order_amount"
        case isActive = "is_active"
        case address
    }
}
