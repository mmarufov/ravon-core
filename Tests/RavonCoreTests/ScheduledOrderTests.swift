import Testing
import Foundation
@testable import RavonCore

@Suite("OrderStatus scheduled")
struct ScheduledOrderStatusTests {
    @Test("scheduled raw value is 'scheduled'")
    func raw() {
        #expect(OrderStatus.scheduled.rawValue == "scheduled")
    }

    @Test("isScheduled true only for scheduled")
    func flag() {
        #expect(OrderStatus.scheduled.isScheduled)
        #expect(!OrderStatus.created.isScheduled)
        #expect(!OrderStatus.delivered.isScheduled)
    }

    @Test("scheduled is not terminal, not cancelled, not chat-active")
    func properties() {
        #expect(!OrderStatus.scheduled.isTerminal)
        #expect(!OrderStatus.scheduled.isCancelled)
        #expect(!OrderStatus.scheduled.isChatActive)
    }

    @Test("Decoding scheduled rawValue")
    func decode() throws {
        let data = "\"scheduled\"".data(using: .utf8)!
        let s = try JSONDecoder().decode(OrderStatus.self, from: data)
        #expect(s == .scheduled)
    }

    @Test("Display name in Russian")
    func display() {
        #expect(OrderStatus.scheduled.displayName == "Запланирован")
    }
}

@Suite("Order with scheduledFor decoding")
struct OrderScheduledForDecodingTests {
    private let dec: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    @Test("Decode scheduled order with future scheduled_for")
    func scheduledOrder() throws {
        let json = #"""
        {
          "id":"00000000-0000-0000-0000-000000000100",
          "user_id":"00000000-0000-0000-0000-000000000001",
          "restaurant_id":"00000000-0000-0000-0000-000000000020",
          "address_id":"00000000-0000-0000-0000-000000000030",
          "courier_id":null,
          "status":"scheduled",
          "subtotal":500.0,
          "delivery_fee":0.0,
          "total":500.0,
          "delivery_address_snapshot":null,
          "notes":null,
          "created_at":"2026-05-03T10:00:00Z",
          "updated_at":"2026-05-03T10:00:00Z",
          "scheduled_for":"2026-05-04T04:00:00Z"
        }
        """#
        let o = try dec.decode(Order.self, from: json.data(using: .utf8)!)
        #expect(o.status == .scheduled)
        #expect(o.scheduledFor != nil)
    }

    @Test("Decode legacy order (no scheduled_for) defaults to nil")
    func legacy() throws {
        let json = #"""
        {
          "id":"00000000-0000-0000-0000-000000000100",
          "user_id":"00000000-0000-0000-0000-000000000001",
          "restaurant_id":"00000000-0000-0000-0000-000000000020",
          "address_id":null,
          "courier_id":null,
          "status":"created",
          "subtotal":500.0,
          "delivery_fee":0.0,
          "total":500.0,
          "delivery_address_snapshot":null,
          "notes":null,
          "created_at":"2026-05-03T10:00:00Z",
          "updated_at":"2026-05-03T10:00:00Z"
        }
        """#
        let o = try dec.decode(Order.self, from: json.data(using: .utf8)!)
        #expect(o.scheduledFor == nil)
        #expect(o.status == .created)
    }
}
