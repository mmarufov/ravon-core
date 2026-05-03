import XCTest
@testable import RavonCore

final class NoShowAndDelayCodingTests: XCTestCase {
    func test_order_decodesNoShowFields() throws {
        let json = #"""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "user_id": "22222222-2222-2222-2222-222222222222",
          "restaurant_id": "33333333-3333-3333-3333-333333333333",
          "address_id": null,
          "courier_id": null,
          "status": "delivered",
          "subtotal": 100,
          "delivery_fee": 20,
          "total": 120,
          "delivery_address_snapshot": null,
          "notes": null,
          "created_at": "2026-05-03T10:00:00Z",
          "updated_at": "2026-05-03T10:30:00Z",
          "no_show": true,
          "no_show_started_at": "2026-05-03T10:25:00Z",
          "restaurant_delay_min": 15
        }
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let order = try decoder.decode(Order.self, from: json)
        XCTAssertTrue(order.noShow)
        XCTAssertNotNil(order.noShowStartedAt)
        XCTAssertEqual(order.restaurantDelayMin, 15)
    }

    func test_order_defaultsZeroDelayAndFalseNoShow() throws {
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
        XCTAssertFalse(order.noShow)
        XCTAssertEqual(order.restaurantDelayMin, 0)
    }

    func test_courierDelayReason_localized() {
        XCTAssertEqual(CourierDelayReason.traffic.localizedDisplayName, "Пробки")
        XCTAssertEqual(CourierDelayReason.restaurantSlow.localizedDisplayName, "Ресторан задерживает")
        XCTAssertEqual(CourierDelayReason.customerUnreachable.localizedDisplayName, "Клиент не отвечает")
    }

    func test_address_decodesDefaultDeliveryMode() throws {
        let json = #"""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "user_id": "22222222-2222-2222-2222-222222222222",
          "label": "Дом",
          "street": "ул. Рудаки 100",
          "apartment": "5",
          "city": "Душанбе",
          "latitude": 38.5598,
          "longitude": 68.7870,
          "is_default": true,
          "default_delivery_mode": "leave_at_door",
          "created_at": "2026-04-01T10:00:00Z"
        }
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let addr = try decoder.decode(Address.self, from: json)
        XCTAssertEqual(addr.defaultDeliveryMode, .leaveAtDoor)
    }

    func test_address_defaultsToHandToMe_whenMissing() throws {
        let json = #"""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "user_id": "22222222-2222-2222-2222-222222222222",
          "label": "Дом",
          "street": "ул. Рудаки 100",
          "apartment": null,
          "city": "Душанбе",
          "latitude": 38.5598,
          "longitude": 68.7870,
          "is_default": true,
          "created_at": "2026-04-01T10:00:00Z"
        }
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let addr = try decoder.decode(Address.self, from: json)
        XCTAssertEqual(addr.defaultDeliveryMode, .handToMe)
    }
}
