import Foundation

/// Author role on a chat message — denormalized on `chat_messages.sender_role`
/// (see migration 15). The `system` role is set explicitly by SECURITY DEFINER
/// RPCs and the courier escalation cron when posting automated notices; apps
/// should render system messages distinctly.
public enum ChatRole: String, Codable, Sendable, CaseIterable {
    case consumer
    case courier
    case merchant
    case system
}

public struct ChatMessage: Codable, Identifiable, Sendable {
    public let id: UUID
    public let orderId: UUID
    public let senderId: UUID
    public let senderRole: ChatRole?
    public let body: String
    public let readAt: Date?
    public let createdAt: Date

    public var isRead: Bool { readAt != nil }
    public func isSentBy(_ userId: UUID) -> Bool { senderId == userId }
    public var isSystem: Bool { senderRole == .system }

    public init(
        id: UUID, orderId: UUID, senderId: UUID,
        senderRole: ChatRole? = nil,
        body: String, readAt: Date? = nil, createdAt: Date
    ) {
        self.id = id
        self.orderId = orderId
        self.senderId = senderId
        self.senderRole = senderRole
        self.body = body
        self.readAt = readAt
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.orderId = try c.decode(UUID.self, forKey: .orderId)
        self.senderId = try c.decode(UUID.self, forKey: .senderId)
        self.senderRole = try c.decodeIfPresent(ChatRole.self, forKey: .senderRole)
        self.body = try c.decode(String.self, forKey: .body)
        self.readAt = try c.decodeIfPresent(Date.self, forKey: .readAt)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case orderId = "order_id"
        case senderId = "sender_id"
        case senderRole = "sender_role"
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
