import Testing
import Foundation
@testable import RavonCore

@Suite("Restaurant.isOrderableHint")
struct RestaurantOrderabilityHintTests {
    private func make(status: RestaurantStatus, accepting: Bool) -> Restaurant {
        Restaurant(
            id: UUID(), name: "Test",
            cuisineType: "tajik", rating: 4.5,
            deliveryTimeMin: 30, deliveryFee: 0, minOrderAmount: 0,
            isAcceptingOrders: accepting,
            restaurantStatus: status
        )
    }

    @Test("active + accepting → hint true")
    func activeAccepting() {
        #expect(make(status: .active, accepting: true).isOrderableHint)
    }

    @Test("active + not accepting → hint false")
    func activeNotAccepting() {
        #expect(!make(status: .active, accepting: false).isOrderableHint)
    }

    @Test("paused → hint false even if accepting")
    func paused() {
        #expect(!make(status: .paused, accepting: true).isOrderableHint)
    }

    @Test("closed → hint false")
    func closed() {
        #expect(!make(status: .closed, accepting: true).isOrderableHint)
    }

    @Test("draft → hint false")
    func draft() {
        #expect(!make(status: .draft, accepting: true).isOrderableHint)
    }
}

@Suite("Restaurant decoding with new acceptingOrdersUntil")
struct RestaurantUntilDecodingTests {
    @Test("Decode legacy row (no accepting_orders_until) defaults nil")
    func legacy() throws {
        let json = #"""
        {
          "id":"00000000-0000-0000-0000-000000000020",
          "name":"R",
          "description":null,
          "image_url":null,
          "cuisine_type":"tajik",
          "rating":4.5,
          "delivery_time_min":30,
          "delivery_fee":0,
          "min_order_amount":0,
          "address":null,
          "latitude":null,
          "longitude":null,
          "opening_time":null,
          "closing_time":null,
          "max_concurrent_orders":null,
          "is_accepting_orders":true,
          "owner_id":null,
          "restaurant_status":"active"
        }
        """#
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let r = try dec.decode(Restaurant.self, from: json.data(using: .utf8)!)
        #expect(r.acceptingOrdersUntil == nil)
        #expect(r.isAcceptingOrders)
    }

    @Test("Decode with accepting_orders_until set")
    func withUntil() throws {
        let json = #"""
        {
          "id":"00000000-0000-0000-0000-000000000020",
          "name":"R",
          "description":null,
          "image_url":null,
          "cuisine_type":"tajik",
          "rating":4.5,
          "delivery_time_min":30,
          "delivery_fee":0,
          "min_order_amount":0,
          "address":null,
          "latitude":null,
          "longitude":null,
          "opening_time":null,
          "closing_time":null,
          "max_concurrent_orders":null,
          "is_accepting_orders":false,
          "accepting_orders_until":"2026-05-03T16:00:00Z",
          "owner_id":null,
          "restaurant_status":"active"
        }
        """#
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let r = try dec.decode(Restaurant.self, from: json.data(using: .utf8)!)
        #expect(r.acceptingOrdersUntil != nil)
        #expect(!r.isAcceptingOrders)
    }
}
