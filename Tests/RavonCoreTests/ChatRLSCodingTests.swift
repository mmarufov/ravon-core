import XCTest
@testable import RavonCore

/// Codable + status-gate behaviour for chat. Server-side RLS is verified by SQL
/// in `.context/migrations/15_chat_rls_and_sender_role.sql`; this file confirms
/// the Swift-side gate (`OrderStatus.isChatActive`) matches the RLS predicate.
final class ChatRLSCodingTests: XCTestCase {
    func test_isChatActive_matchesServerActiveSet() {
        let active: [OrderStatus] = [
            .assigned, .courierArrivedRestaurant, .pickedUp, .delivering, .courierArrivedCustomer
        ]
        let inactive: [OrderStatus] = [
            .scheduled, .created, .accepted, .preparing, .ready,
            .delivered, .cancelled, .rejected,
            .cancelledByCustomer, .cancelledByRestaurant, .cancelledBySystem, .cancelledByCourier
        ]
        for s in active   { XCTAssertTrue(s.isChatActive,  "\(s) should be chat-active") }
        for s in inactive { XCTAssertFalse(s.isChatActive, "\(s) should NOT be chat-active") }
    }

    func test_chatMessage_decodes_withReadAt() throws {
        let json = #"""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "order_id": "22222222-2222-2222-2222-222222222222",
          "sender_id": "33333333-3333-3333-3333-333333333333",
          "body": "Я уже в пути",
          "read_at": "2026-05-03T10:31:00Z",
          "created_at": "2026-05-03T10:30:00Z"
        }
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let msg = try decoder.decode(ChatMessage.self, from: json)
        XCTAssertNotNil(msg.readAt)
        XCTAssertTrue(msg.isRead)
        XCTAssertEqual(msg.body, "Я уже в пути")
    }

    func test_chatMessage_decodes_unreadFromSystem() throws {
        // System messages from the escalation ladder.
        let json = #"""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "order_id": "22222222-2222-2222-2222-222222222222",
          "sender_id": "00000000-0000-0000-0000-000000000000",
          "body": "Курьер не отвечает, мы пытаемся с ним связаться.",
          "read_at": null,
          "created_at": "2026-05-03T10:32:00Z"
        }
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let msg = try decoder.decode(ChatMessage.self, from: json)
        XCTAssertNil(msg.readAt)
        XCTAssertFalse(msg.isRead)
    }
}
