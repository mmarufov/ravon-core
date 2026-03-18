import Foundation

public struct Profile: Codable, Identifiable, Sendable {
    public let id: UUID
    public var fullName: String
    public var phone: String?
    public var role: UserRole
    public var avatarUrl: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID, fullName: String, phone: String? = nil, role: UserRole, avatarUrl: String? = nil, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.fullName = fullName
        self.phone = phone
        self.role = role
        self.avatarUrl = avatarUrl
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case phone, role
        case avatarUrl = "avatar_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
