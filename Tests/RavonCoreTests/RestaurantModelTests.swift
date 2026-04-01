import Testing
import Foundation
@testable import RavonCore

@Suite("RestaurantStatus")
struct RestaurantStatusTests {

    @Test("Encoding each case produces correct rawValue")
    func encoding() throws {
        let encoder = JSONEncoder()
        for status in [RestaurantStatus.draft, .active, .paused, .closed] {
            let data = try encoder.encode(status)
            let string = String(data: data, encoding: .utf8)!
            #expect(string == "\"\(status.rawValue)\"")
        }
    }

    @Test("Decoding valid rawValues")
    func decoding() throws {
        let decoder = JSONDecoder()
        for raw in ["draft", "active", "paused", "closed"] {
            let data = "\"\(raw)\"".data(using: .utf8)!
            let status = try decoder.decode(RestaurantStatus.self, from: data)
            #expect(status.rawValue == raw)
        }
    }

    @Test("Decoding unknown string throws")
    func unknownThrows() throws {
        let decoder = JSONDecoder()
        let data = "\"unknown\"".data(using: .utf8)!
        #expect(throws: (any Error).self) {
            try decoder.decode(RestaurantStatus.self, from: data)
        }
    }
}

@Suite("Restaurant backwards compat")
struct RestaurantBackwardsCompatTests {

    @Test("Decoding with nullable ownerId")
    func nullableOwnerId() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "name": "Test",
            "cuisine_type": "uzbek",
            "rating": 4.5,
            "delivery_time_min": 30,
            "delivery_fee": 5.0,
            "min_order_amount": 10.0,
            "is_active": true,
            "is_accepting_orders": true,
            "owner_id": null,
            "restaurant_status": "active"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        let restaurant = try decoder.decode(Restaurant.self, from: json)
        #expect(restaurant.ownerId == nil)
        #expect(restaurant.restaurantStatus == .active)
        #expect(restaurant.isActive == true)
    }

    @Test("Decoding with ownerId present")
    func withOwnerId() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "name": "Test",
            "cuisine_type": "uzbek",
            "rating": 4.5,
            "delivery_time_min": 30,
            "delivery_fee": 5.0,
            "min_order_amount": 10.0,
            "is_active": true,
            "is_accepting_orders": true,
            "owner_id": "00000000-0000-0000-0000-000000000099",
            "restaurant_status": "draft"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        let restaurant = try decoder.decode(Restaurant.self, from: json)
        #expect(restaurant.ownerId == UUID(uuidString: "00000000-0000-0000-0000-000000000099"))
        #expect(restaurant.restaurantStatus == .draft)
    }
}
