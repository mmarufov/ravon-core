import Foundation

public struct MenuCategory: Codable, Identifiable, Sendable {
    public let id: UUID
    public let restaurantId: UUID
    public let name: String
    public let sortOrder: Int
    public let isAvailable: Bool
    public let deletedAt: Date?

    public init(id: UUID, restaurantId: UUID, name: String, sortOrder: Int, isAvailable: Bool = true, deletedAt: Date? = nil) {
        self.id = id
        self.restaurantId = restaurantId
        self.name = name
        self.sortOrder = sortOrder
        self.isAvailable = isAvailable
        self.deletedAt = deletedAt
    }

    public var isSoftDeleted: Bool { deletedAt != nil }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.restaurantId = try c.decode(UUID.self, forKey: .restaurantId)
        self.name = try c.decode(String.self, forKey: .name)
        self.sortOrder = try c.decode(Int.self, forKey: .sortOrder)
        self.isAvailable = try c.decodeIfPresent(Bool.self, forKey: .isAvailable) ?? true
        self.deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case restaurantId = "restaurant_id"
        case name
        case sortOrder = "sort_order"
        case isAvailable = "is_available"
        case deletedAt = "deleted_at"
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
