import Foundation

public struct MenuCategory: Codable, Identifiable, Sendable {
    public let id: UUID
    public let restaurantId: UUID
    public let name: String
    public let sortOrder: Int

    public init(id: UUID, restaurantId: UUID, name: String, sortOrder: Int) {
        self.id = id
        self.restaurantId = restaurantId
        self.name = name
        self.sortOrder = sortOrder
    }

    enum CodingKeys: String, CodingKey {
        case id
        case restaurantId = "restaurant_id"
        case name
        case sortOrder = "sort_order"
    }
}

// MARK: - Menu Category Insert

public struct MenuCategoryInsert: Encodable, Sendable {
    public let restaurantId: UUID
    public let name: String
    public let sortOrder: Int

    public init(restaurantId: UUID, name: String, sortOrder: Int) {
        self.restaurantId = restaurantId
        self.name = name
        self.sortOrder = sortOrder
    }

    enum CodingKeys: String, CodingKey {
        case name
        case restaurantId = "restaurant_id"
        case sortOrder = "sort_order"
    }
}
