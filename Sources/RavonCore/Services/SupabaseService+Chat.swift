import Foundation
import Supabase

extension SupabaseService {
    // MARK: - Chat Messages

    public func sendMessage(orderId: UUID, body: String) async throws -> ChatMessage {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        let insert = ChatMessageInsert(orderId: orderId, senderId: uid, body: body)
        return try await client.from("chat_messages")
            .insert(insert)
            .select()
            .single()
            .execute()
            .value
    }

    public func fetchMessages(orderId: UUID) async throws -> [ChatMessage] {
        guard AuthService.shared.userId != nil else {
            throw ServiceError.notAuthenticated
        }
        return try await client.from("chat_messages")
            .select()
            .eq("order_id", value: orderId.uuidString)
            .order("created_at")
            .execute()
            .value
    }

    public func markMessagesAsRead(orderId: UUID) async throws {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        try await client.from("chat_messages")
            .update(["read_at": AnyJSON.string(Self.isoFormatter.string(from: Date()))])
            .eq("order_id", value: orderId.uuidString)
            .neq("sender_id", value: uid.uuidString)
            .is("read_at", value: nil)
            .execute()
    }

    public func fetchUnreadCount(orderId: UUID) async throws -> Int {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        let rows: [IdRow] = try await client.from("chat_messages")
            .select("id")
            .eq("order_id", value: orderId.uuidString)
            .neq("sender_id", value: uid.uuidString)
            .is("read_at", value: nil)
            .execute()
            .value
        return rows.count
    }
}
