import Foundation

public struct Profile: Codable, Identifiable, Sendable {
    public let id: UUID
    public var fullName: String
    public var phone: String?
    public var role: UserRole
    public var avatarUrl: String?
    /// When non-nil and in the future, the user is suspended.
    /// Set by the courier escalation ladder after 3 ghost strikes (Workstream A).
    public var isSuspendedUntil: Date?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID, fullName: String, phone: String? = nil,
        role: UserRole, avatarUrl: String? = nil,
        isSuspendedUntil: Date? = nil,
        createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.fullName = fullName
        self.phone = phone
        self.role = role
        self.avatarUrl = avatarUrl
        self.isSuspendedUntil = isSuspendedUntil
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.fullName = try c.decode(String.self, forKey: .fullName)
        self.phone = try c.decodeIfPresent(String.self, forKey: .phone)
        self.role = try c.decode(UserRole.self, forKey: .role)
        self.avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        self.isSuspendedUntil = try c.decodeIfPresent(Date.self, forKey: .isSuspendedUntil)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    public var isSuspended: Bool {
        guard let until = isSuspendedUntil else { return false }
        return until > Date()
    }

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case phone, role
        case avatarUrl = "avatar_url"
        case isSuspendedUntil = "is_suspended_until"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
