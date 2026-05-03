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

    // Heartbeat / ghost-detection fields (Workstream A).
    public let lastHeartbeatAt: Date
    public let lastMovedAt: Date
    public let accuracyMeters: Double?
    public let ghostStrikes: Int
    public let strikesResetAt: Date

    public var status: CourierStatus {
        if !isOnline { return .offline }
        return currentOrderId != nil ? .delivering : .online
    }

    public init(
        courierId: UUID, latitude: Double, longitude: Double,
        heading: Double? = nil, speed: Double? = nil,
        isOnline: Bool, currentOrderId: UUID? = nil, lastUpdated: Date,
        lastHeartbeatAt: Date,
        lastMovedAt: Date,
        accuracyMeters: Double? = nil,
        ghostStrikes: Int = 0,
        strikesResetAt: Date
    ) {
        self.courierId = courierId
        self.latitude = latitude
        self.longitude = longitude
        self.heading = heading
        self.speed = speed
        self.isOnline = isOnline
        self.currentOrderId = currentOrderId
        self.lastUpdated = lastUpdated
        self.lastHeartbeatAt = lastHeartbeatAt
        self.lastMovedAt = lastMovedAt
        self.accuracyMeters = accuracyMeters
        self.ghostStrikes = ghostStrikes
        self.strikesResetAt = strikesResetAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.courierId       = try c.decode(UUID.self,   forKey: .courierId)
        self.latitude        = try c.decode(Double.self, forKey: .latitude)
        self.longitude       = try c.decode(Double.self, forKey: .longitude)
        self.heading         = try c.decodeIfPresent(Double.self, forKey: .heading)
        self.speed           = try c.decodeIfPresent(Double.self, forKey: .speed)
        self.isOnline        = try c.decode(Bool.self,   forKey: .isOnline)
        self.currentOrderId  = try c.decodeIfPresent(UUID.self, forKey: .currentOrderId)
        self.lastUpdated     = try c.decode(Date.self,   forKey: .lastUpdated)
        self.lastHeartbeatAt = try c.decodeIfPresent(Date.self, forKey: .lastHeartbeatAt) ?? self.lastUpdated
        self.lastMovedAt     = try c.decodeIfPresent(Date.self, forKey: .lastMovedAt)     ?? self.lastUpdated
        self.accuracyMeters  = try c.decodeIfPresent(Double.self, forKey: .accuracyMeters)
        self.ghostStrikes    = try c.decodeIfPresent(Int.self, forKey: .ghostStrikes) ?? 0
        self.strikesResetAt  = try c.decodeIfPresent(Date.self, forKey: .strikesResetAt) ?? self.lastUpdated
    }

    enum CodingKeys: String, CodingKey {
        case courierId = "courier_id"
        case latitude, longitude, heading, speed
        case isOnline = "is_online"
        case currentOrderId = "current_order_id"
        case lastUpdated = "last_updated"
        case lastHeartbeatAt = "last_heartbeat_at"
        case lastMovedAt = "last_moved_at"
        case accuracyMeters = "accuracy_meters"
        case ghostStrikes = "ghost_strikes"
        case strikesResetAt = "strikes_reset_at"
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
