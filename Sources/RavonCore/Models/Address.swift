import Foundation

public struct Address: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let userId: UUID
    public var label: String
    public var street: String
    public var apartment: String?
    public var city: String
    public var latitude: Double?
    public var longitude: Double?
    public var isDefault: Bool
    public let createdAt: Date

    public init(id: UUID, userId: UUID, label: String, street: String, apartment: String? = nil, city: String, latitude: Double? = nil, longitude: Double? = nil, isDefault: Bool, createdAt: Date) {
        self.id = id
        self.userId = userId
        self.label = label
        self.street = street
        self.apartment = apartment
        self.city = city
        self.latitude = latitude
        self.longitude = longitude
        self.isDefault = isDefault
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case label, street, apartment, city, latitude, longitude
        case isDefault = "is_default"
        case createdAt = "created_at"
    }
}

public struct AddressInsert: Encodable, Sendable {
    public let userId: UUID
    public let label: String
    public let street: String
    public let apartment: String?
    public let city: String
    public let latitude: Double?
    public let longitude: Double?
    public let isDefault: Bool

    public init(userId: UUID, label: String, street: String, apartment: String? = nil, city: String, latitude: Double? = nil, longitude: Double? = nil, isDefault: Bool) {
        self.userId = userId
        self.label = label
        self.street = street
        self.apartment = apartment
        self.city = city
        self.latitude = latitude
        self.longitude = longitude
        self.isDefault = isDefault
    }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case label, street, apartment, city, latitude, longitude
        case isDefault = "is_default"
    }
}

public struct AddressSnapshot: Codable, Hashable, Sendable {
    public let label: String?
    public let street: String?
    public let apartment: String?
    public let city: String?
    public let latitude: Double?
    public let longitude: Double?

    public init(label: String? = nil, street: String? = nil, apartment: String? = nil, city: String? = nil, latitude: Double? = nil, longitude: Double? = nil) {
        self.label = label
        self.street = street
        self.apartment = apartment
        self.city = city
        self.latitude = latitude
        self.longitude = longitude
    }
}
