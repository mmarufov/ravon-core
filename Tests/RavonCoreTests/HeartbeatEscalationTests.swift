import XCTest
@testable import RavonCore

@MainActor
final class HeartbeatEscalationTests: XCTestCase {
    func test_cadence_offlineButOnlineIs30s() {
        let s = CourierLocationStreamer.shared
        XCTAssertEqual(s.cadence(for: nil), 30)
    }

    func test_cadence_assignedIs10s() {
        let s = CourierLocationStreamer.shared
        XCTAssertEqual(s.cadence(for: .assigned), 10)
    }

    func test_cadence_deliveringIs5s() {
        let s = CourierLocationStreamer.shared
        XCTAssertEqual(s.cadence(for: .delivering), 5)
        XCTAssertEqual(s.cadence(for: .pickedUp), 5)
    }

    func test_cadence_atRestaurantOrCustomerIsLowPriority() {
        let s = CourierLocationStreamer.shared
        XCTAssertEqual(s.cadence(for: .courierArrivedRestaurant), 30)
        XCTAssertEqual(s.cadence(for: .courierArrivedCustomer), 10)
    }

    func test_movementFilter_strictestWhenDelivering() {
        let s = CourierLocationStreamer.shared
        XCTAssertEqual(s.movementFilterMeters(for: .delivering), 15)
        XCTAssertEqual(s.movementFilterMeters(for: .assigned), 25)
        XCTAssertEqual(s.movementFilterMeters(for: nil), 50)
    }

    func test_movementFilter_noneAtRestaurantOrCustomer() {
        let s = CourierLocationStreamer.shared
        XCTAssertNil(s.movementFilterMeters(for: .courierArrivedRestaurant))
        XCTAssertNil(s.movementFilterMeters(for: .courierArrivedCustomer))
    }

    func test_orderEta_delayWarningActive_whenSlaPastAndUnexplained() {
        let past = Date(timeIntervalSinceNow: -60)
        let eta = OrderEta(
            orderId: UUID(),
            etaMinutes: 5,
            expectedActionBy: past,
            courierDelayReasonCode: nil,
            courierDelayExplainedAt: nil,
            courierNoShowWarnedAt: past,
            courierNoShowEscalatedAt: nil,
            status: .delivering
        )
        XCTAssertTrue(eta.delayWarningActive)
        XCTAssertFalse(eta.escalated)
    }

    func test_orderEta_warningClearedAfterExplain() {
        let past = Date(timeIntervalSinceNow: -60)
        let eta = OrderEta(
            orderId: UUID(),
            etaMinutes: 5,
            expectedActionBy: past,
            courierDelayReasonCode: "traffic",
            courierDelayExplainedAt: Date(),
            courierNoShowWarnedAt: past,
            courierNoShowEscalatedAt: nil,
            status: .delivering
        )
        XCTAssertFalse(eta.delayWarningActive)
    }

    func test_orderEta_warningInactiveBeforeSla() {
        let future = Date(timeIntervalSinceNow: 120)
        let eta = OrderEta(
            orderId: UUID(),
            etaMinutes: 5,
            expectedActionBy: future,
            courierDelayReasonCode: nil,
            courierDelayExplainedAt: nil,
            courierNoShowWarnedAt: nil,
            courierNoShowEscalatedAt: nil,
            status: .delivering
        )
        XCTAssertFalse(eta.delayWarningActive)
    }
}
