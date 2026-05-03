import XCTest
@testable import RavonCore

/// Race-related state machine assertions. The actual concurrency tests run
/// against the live DB (see verification section); these confirm the Swift
/// model correctly mirrors the server's status guards.
final class RaceConditionCodingTests: XCTestCase {
    func test_pickedUp_blocksConsumerCancel_blocksCourierCancel() {
        XCTAssertFalse(OrderStatus.pickedUp.consumerCanCancel)
        XCTAssertFalse(OrderStatus.pickedUp.courierCanCancel)
    }

    func test_assignedAndAtRestaurant_allowBothCancels() {
        XCTAssertTrue(OrderStatus.assigned.consumerCanCancel)
        XCTAssertTrue(OrderStatus.assigned.courierCanCancel)
        XCTAssertTrue(OrderStatus.courierArrivedRestaurant.consumerCanCancel)
        XCTAssertTrue(OrderStatus.courierArrivedRestaurant.courierCanCancel)
    }

    func test_terminalStates_blockEverything() {
        for s: OrderStatus in [
            .delivered, .cancelled, .rejected,
            .cancelledByCustomer, .cancelledByRestaurant,
            .cancelledBySystem, .cancelledByCourier
        ] {
            XCTAssertFalse(s.consumerCanCancel, "\(s) is terminal — consumer must not be able to cancel")
            XCTAssertFalse(s.courierCanCancel,  "\(s) is terminal — courier must not be able to cancel")
            XCTAssertFalse(s.isChatActive,      "\(s) is terminal — chat should be inactive")
            XCTAssertTrue(s.isTerminal,         "\(s) should report isTerminal=true")
        }
    }

    func test_orderEta_handlesEscalatedFlag() {
        let now = Date()
        let eta = OrderEta(
            orderId: UUID(),
            etaMinutes: 5,
            expectedActionBy: now.addingTimeInterval(-300), // 5 min past SLA
            courierDelayReasonCode: nil,
            courierDelayExplainedAt: nil,
            courierNoShowWarnedAt: now.addingTimeInterval(-240),
            courierNoShowEscalatedAt: now.addingTimeInterval(-120),
            status: .delivering
        )
        XCTAssertTrue(eta.delayWarningActive)
        XCTAssertTrue(eta.escalated)
    }
}
