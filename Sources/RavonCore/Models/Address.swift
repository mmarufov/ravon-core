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
    /// Per-address default mode for new orders. Read by the
    /// `orders_sync_delivery_mode` BEFORE INSERT trigger.
    public var defaultDeliveryMode: DeliveryMode
    public let createdAt: Date

    public init(
        id: UUID, userId: UUID, label: String, street: String,
        apartment: String? = nil, city: String,
        latitude: Double? = nil, longitude: Double? = nil,
        isDefault: Bool,
        defaultDeliveryMode: DeliveryMode = .handToMe,
        createdAt: Date
    ) {
        self.id = id
        self.userId = userId
        self.label = label
        self.street = street
        self.apartment = apartment
        self.city = city
        self.latitude = latitude
        self.longitude = longitude
        self.isDefault = isDefault
        self.defaultDeliveryMode = defaultDeliveryMode
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.userId = try c.decode(UUID.self, forKey: .userId)
        self.label = try c.decode(String.self, forKey: .label)
        self.street = try c.decode(String.self, forKey: .street)
        self.apartment = try c.decodeIfPresent(String.self, forKey: .apartment)
        self.city = try c.decode(String.self, forKey: .city)
        self.latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        self.longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        self.isDefault = try c.decode(Bool.self, forKey: .isDefault)
        self.defaultDeliveryMode = try c.decodeIfPresent(DeliveryMode.self, forKey: .defaultDeliveryMode) ?? .handToMe
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case label, street, apartment, city, latitude, longitude
        case isDefault = "is_default"
        case defaultDeliveryMode = "default_delivery_mode"
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
    public let defaultDeliveryMode: DeliveryMode?

    public init(
        userId: UUID, label: String, street: String,
        apartment: String? = nil, city: String,
        latitude: Double? = nil, longitude: Double? = nil,
        isDefault: Bool,
        defaultDeliveryMode: DeliveryMode? = nil
    ) {
        self.userId = userId
        self.label = label
        self.street = street
        self.apartment = apartment
        self.city = city
        self.latitude = latitude
        self.longitude = longitude
        self.isDefault = isDefault
        self.defaultDeliveryMode = defaultDeliveryMode
    }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case label, street, apartment, city, latitude, longitude
        case isDefault = "is_default"
        case defaultDeliveryMode = "default_delivery_mode"
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
