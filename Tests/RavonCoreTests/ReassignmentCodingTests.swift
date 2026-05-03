import XCTest
@testable import RavonCore

final class ReassignmentCodingTests: XCTestCase {
    func test_order_decodesReassignmentColumns() throws {
        let json = #"""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "user_id": "22222222-2222-2222-2222-222222222222",
          "restaurant_id": "33333333-3333-3333-3333-333333333333",
          "address_id": null,
          "courier_id": null,
          "status": "ready",
          "subtotal": 100,
          "delivery_fee": 20,
          "total": 120,
          "delivery_address_snapshot": null,
          "notes": null,
          "created_at": "2026-05-03T10:00:00Z",
          "updated_at": "2026-05-03T10:30:00Z",
          "reassign_count": 2,
          "excluded_courier_ids": [
            "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
          ]
        }
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let order = try decoder.decode(Order.self, from: json)
        XCTAssertEqual(order.reassignCount, 2)
        XCTAssertEqual(order.excludedCourierIds.count, 2)
        XCTAssertEqual(order.excludedCourierIds[0],
                       UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
    }

    func test_order_excludedCourierIds_defaultsToEmpty() throws {
        let json = #"""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "user_id": "22222222-2222-2222-2222-222222222222",
          "restaurant_id": "33333333-3333-3333-3333-333333333333",
          "address_id": null,
          "courier_id": null,
          "status": "ready",
          "subtotal": 100,
          "delivery_fee": 20,
          "total": 120,
          "delivery_address_snapshot": null,
          "notes": null,
          "created_at": "2026-05-03T10:00:00Z",
          "updated_at": "2026-05-03T10:00:00Z"
        }
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let order = try decoder.decode(Order.self, from: json)
        XCTAssertEqual(order.excludedCourierIds, [])
        XCTAssertEqual(order.reassignCount, 0)
    }

    func test_courierLocation_decodesGhostStrikes() throws {
        let json = #"""
        {
          "courier_id": "11111111-1111-1111-1111-111111111111",
          "latitude": 38.5598,
          "longitude": 68.7870,
          "heading": null,
          "speed": null,
          "is_online": true,
          "current_order_id": null,
          "last_updated": "2026-05-03T10:00:00Z",
          "last_heartbeat_at": "2026-05-03T10:00:01Z",
          "last_moved_at": "2026-05-03T09:55:00Z",
          "accuracy_meters": 12.5,
          "ghost_strikes": 1,
          "strikes_reset_at": "2026-05-01T00:00:00Z"
        }
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let cl = try decoder.decode(CourierLocation.self, from: json)
        XCTAssertEqual(cl.ghostStrikes, 1)
        XCTAssertEqual(cl.accuracyMeters, 12.5)
        XCTAssertNotNil(cl.lastHeartbeatAt)
        XCTAssertNotNil(cl.lastMovedAt)
    }

    func test_courierLocation_backCompat_oldRowsDecode() throws {
        // Rows that pre-date migration 08 don't have heartbeat columns.
        // Decoder defaults them to last_updated.
        let json = #"""
        {
          "courier_id": "11111111-1111-1111-1111-111111111111",
          "latitude": 38.5598,
          "longitude": 68.7870,
          "heading": null,
          "speed": null,
          "is_online": true,
          "current_order_id": null,
          "last_updated": "2026-04-01T10:00:00Z"
        }
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let cl = try decoder.decode(CourierLocation.self, from: json)
        XCTAssertEqual(cl.ghostStrikes, 0)
        XCTAssertNil(cl.accuracyMeters)
        XCTAssertEqual(cl.lastHeartbeatAt, cl.lastUpdated)
    }
}
