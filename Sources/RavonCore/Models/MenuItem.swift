import Foundation

public struct MenuItem: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let categoryId: UUID
    public let restaurantId: UUID
    public let name: String
    public let description: String?
    public let price: Double
    public let imageUrl: String?
    public let isAvailable: Bool
    public let sortOrder: Int

    public init(id: UUID, categoryId: UUID, restaurantId: UUID, name: String, description: String? = nil, price: Double, imageUrl: String? = nil, isAvailable: Bool, sortOrder: Int) {
        self.id = id
        self.categoryId = categoryId
        self.restaurantId = restaurantId
        self.name = name
        self.description = description
        self.price = price
        self.imageUrl = imageUrl
        self.isAvailable = isAvailable
        self.sortOrder = sortOrder
    }

    enum CodingKeys: String, CodingKey {
        case id
        case categoryId = "category_id"
        case restaurantId = "restaurant_id"
        case name, description, price
        case imageUrl = "image_url"
        case isAvailable = "is_available"
        case sortOrder = "sort_order"
    }
}
