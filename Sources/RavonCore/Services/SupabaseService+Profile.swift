import Foundation
import Supabase

extension SupabaseService {
    // MARK: - Profile

    public func fetchProfile() async throws -> Profile {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        return try await client.from("profiles")
            .select()
            .eq("id", value: uid.uuidString)
            .single()
            .execute()
            .value
    }

    public func updateProfile(fullName: String, phone: String?) async throws {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        var updates: [String: AnyJSON] = [
            "full_name": .string(fullName),
        ]
        updates["phone"] = phone.map { .string($0) } ?? .null
        try await client.from("profiles")
            .update(updates)
            .eq("id", value: uid.uuidString)
            .execute()
    }
}
