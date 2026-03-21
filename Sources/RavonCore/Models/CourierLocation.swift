import Foundation

public struct CourierLocation: Codable, Identifiable, Sendable {
    public var id: UUID { courierId }
    public let courierId: UUID
    public let latitude: Double
    public let longitude: Double
    public let heading: Double?
    public let speed: Double?
    public let isOnline: Bool
    public let currentOrderId: UUID?
    public let lastUpdated: Date

    public var status: CourierStatus {
        if !isOnline { return .offline }
        return currentOrderId != nil ? .delivering : .online
    }

    public init(
        courierId: UUID, latitude: Double, longitude: Double,
        heading: Double? = nil, speed: Double? = nil,
        isOnline: Bool, currentOrderId: UUID? = nil, lastUpdated: Date
    ) {
        self.courierId = courierId
        self.latitude = latitude
        self.longitude = longitude
        self.heading = heading
        self.speed = speed
        self.isOnline = isOnline
        self.currentOrderId = currentOrderId
        self.lastUpdated = lastUpdated
    }

    enum CodingKeys: String, CodingKey {
        case courierId = "courier_id"
        case latitude, longitude, heading, speed
        case isOnline = "is_online"
        case currentOrderId = "current_order_id"
        case lastUpdated = "last_updated"
    }
}

public struct CourierLocationUpsert: Encodable, Sendable {
    public let courierId: UUID
    public let latitude: Double
    public let longitude: Double
    public let heading: Double?
    public let speed: Double?
    public let isOnline: Bool
    public let currentOrderId: UUID?

    public init(
        courierId: UUID, latitude: Double, longitude: Double,
        heading: Double? = nil, speed: Double? = nil,
        isOnline: Bool, currentOrderId: UUID? = nil
    ) {
        self.courierId = courierId
        self.latitude = latitude
        self.longitude = longitude
        self.heading = heading
        self.speed = speed
        self.isOnline = isOnline
        self.currentOrderId = currentOrderId
    }

    enum CodingKeys: String, CodingKey {
        case courierId = "courier_id"
        case latitude, longitude, heading, speed
        case isOnline = "is_online"
        case currentOrderId = "current_order_id"
    }
}

public struct NearbyCourier: Codable, Identifiable, Sendable {
    public var id: UUID { courierId }
    public let courierId: UUID
    public let latitude: Double
    public let longitude: Double
    public let heading: Double?
    public let speed: Double?
    public let distanceKm: Double
    public let lastUpdated: Date

    public init(
        courierId: UUID, latitude: Double, longitude: Double,
        heading: Double? = nil, speed: Double? = nil,
        distanceKm: Double, lastUpdated: Date
    ) {
        self.courierId = courierId
        self.latitude = latitude
        self.longitude = longitude
        self.heading = heading
        self.speed = speed
        self.distanceKm = distanceKm
        self.lastUpdated = lastUpdated
    }

    enum CodingKeys: String, CodingKey {
        case courierId = "courier_id"
        case latitude, longitude, heading, speed
        case distanceKm = "distance_km"
        case lastUpdated = "last_updated"
    }
}
