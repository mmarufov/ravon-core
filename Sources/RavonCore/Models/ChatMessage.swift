import Foundation

public struct ChatMessage: Codable, Identifiable, Sendable {
    public let id: UUID
    public let orderId: UUID
    public let senderId: UUID
    public let body: String
    public let readAt: Date?
    public let createdAt: Date

    public var isRead: Bool { readAt != nil }
    public func isSentBy(_ userId: UUID) -> Bool { senderId == userId }

    public init(
        id: UUID, orderId: UUID, senderId: UUID,
        body: String, readAt: Date? = nil, createdAt: Date
    ) {
        self.id = id
        self.orderId = orderId
        self.senderId = senderId
        self.body = body
        self.readAt = readAt
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case orderId = "order_id"
        case senderId = "sender_id"
        case body
        case readAt = "read_at"
        case createdAt = "created_at"
    }
}

public struct ChatMessageInsert: Encodable, Sendable {
    public let orderId: UUID
    public let senderId: UUID
    public let body: String

    public init(orderId: UUID, senderId: UUID, body: String) {
        self.orderId = orderId
        self.senderId = senderId
        self.body = body
    }

    enum CodingKeys: String, CodingKey {
        case orderId = "order_id"
        case senderId = "sender_id"
        case body
    }
}
