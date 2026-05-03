import XCTest
@testable import RavonCore

final class CourierEarningsTierTests: XCTestCase {
    /// Mirrors the SQL `earnings_tier_for_cancel(order_status)` table.
    private func clientTier(for status: OrderStatus) -> Int {
        switch status {
        case .assigned:                   return 25
        case .courierArrivedRestaurant:   return 50
        case .pickedUp, .delivering, .courierArrivedCustomer: return 100
        default:                          return 0
        }
    }

    func test_tierTable_zeroBeforeAssigned() {
        XCTAssertEqual(clientTier(for: .created), 0)
        XCTAssertEqual(clientTier(for: .accepted), 0)
        XCTAssertEqual(clientTier(for: .preparing), 0)
        XCTAssertEqual(clientTier(for: .ready), 0)
    }

    func test_tierTable_25atAssigned() {
        XCTAssertEqual(clientTier(for: .assigned), 25)
    }

    func test_tierTable_50atRestaurant() {
        XCTAssertEqual(clientTier(for: .courierArrivedRestaurant), 50)
    }

    func test_tierTable_100postPickup() {
        XCTAssertEqual(clientTier(for: .pickedUp), 100)
        XCTAssertEqual(clientTier(for: .delivering), 100)
        XCTAssertEqual(clientTier(for: .courierArrivedCustomer), 100)
    }

    func test_courierEarning_decodesTieredFields() throws {
        let json = #"""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "courier_id": "22222222-2222-2222-2222-222222222222",
          "order_id": "33333333-3333-3333-3333-333333333333",
          "delivery_fee": 50.0,
          "tip_amount": 0,
          "total_earned": 25.0,
          "earning_type": "partial_assigned",
          "tier_pct": 25,
          "cancellation_reason_code": "CONSUMER_CHANGED_MIND",
          "status_at_event": "assigned",
          "created_at": "2026-05-03T10:00:00Z"
        }
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let earning = try decoder.decode(CourierEarning.self, from: json)
        XCTAssertEqual(earning.earningType, .partialAssigned)
        XCTAssertEqual(earning.tierPct, 25)
        XCTAssertEqual(earning.totalEarned, 25.0)
        XCTAssertEqual(earning.cancellationReasonCode, "CONSUMER_CHANGED_MIND")
        XCTAssertEqual(earning.statusAtEvent, .assigned)
        XCTAssertFalse(earning.isClawback)
    }

    func test_courierEarning_decodesClawback() throws {
        let json = #"""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "courier_id": "22222222-2222-2222-2222-222222222222",
          "order_id": "33333333-3333-3333-3333-333333333333",
          "delivery_fee": 50.0,
          "tip_amount": 0,
          "total_earned": -50.0,
          "earning_type": "clawback",
          "tier_pct": -100,
          "cancellation_reason_code": "COURIER_NON_RESPONSIVE",
          "status_at_event": "delivering",
          "created_at": "2026-05-03T10:00:00Z"
        }
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let earning = try decoder.decode(CourierEarning.self, from: json)
        XCTAssertTrue(earning.isClawback)
        XCTAssertLessThan(earning.totalEarned, 0)
    }

    func test_courierEarning_backCompat_oldRowsDecodeAsFull() throws {
        // Pre-Umbrella II rows have no earning_type / tier_pct columns.
        let json = #"""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "courier_id": "22222222-2222-2222-2222-222222222222",
          "order_id": "33333333-3333-3333-3333-333333333333",
          "delivery_fee": 100.0,
          "tip_amount": 10.0,
          "total_earned": 110.0,
          "created_at": "2026-04-01T10:00:00Z"
        }
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let earning = try decoder.decode(CourierEarning.self, from: json)
        XCTAssertEqual(earning.earningType, .full)
        XCTAssertEqual(earning.tierPct, 100)
        XCTAssertNil(earning.cancellationReasonCode)
        XCTAssertNil(earning.statusAtEvent)
    }
}
