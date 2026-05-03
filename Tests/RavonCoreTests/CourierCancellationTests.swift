import XCTest
@testable import RavonCore

final class CourierCancellationTests: XCTestCase {
    func test_consumerAllowed_isStableSubset() {
        XCTAssertTrue(CancellationReason.consumerAllowed.contains(.consumerChangedMind))
        XCTAssertTrue(CancellationReason.consumerAllowed.contains(.consumerDuplicate))
        XCTAssertFalse(CancellationReason.consumerAllowed.contains(.courierVehicleIssue))
        XCTAssertFalse(CancellationReason.consumerAllowed.contains(.systemFraudSuspected))
    }

    func test_courierAllowed_matchesServerWhitelist() {
        let expected: Set<CancellationReason> = [
            .courierVehicleIssue, .courierSafetyIssue,
            .courierRestaurantClosed, .courierItemsUnavailable,
            .restaurantTooLongWait,
        ]
        XCTAssertEqual(CancellationReason.courierAllowed, expected)
    }

    func test_courierAllowed_excludesPostPickupCases() {
        // Post-pickup cancellations route through report_problem_post_pickup,
        // so courierNonResponsive must NOT be a self-cancel reason.
        XCTAssertFalse(CancellationReason.courierAllowed.contains(.courierNonResponsive))
    }

    func test_consumerCanCancel_matchesServerStatusGate() {
        // Server's cancel_order_by_consumer rejects post-pickup statuses.
        XCTAssertTrue(OrderStatus.created.consumerCanCancel)
        XCTAssertTrue(OrderStatus.assigned.consumerCanCancel)
        XCTAssertTrue(OrderStatus.courierArrivedRestaurant.consumerCanCancel)
        XCTAssertFalse(OrderStatus.pickedUp.consumerCanCancel)
        XCTAssertFalse(OrderStatus.delivering.consumerCanCancel)
        XCTAssertFalse(OrderStatus.courierArrivedCustomer.consumerCanCancel)
        XCTAssertFalse(OrderStatus.delivered.consumerCanCancel)
    }

    func test_courierCanCancel_matchesHybridScope() {
        XCTAssertTrue(OrderStatus.assigned.courierCanCancel)
        XCTAssertTrue(OrderStatus.courierArrivedRestaurant.courierCanCancel)
        XCTAssertFalse(OrderStatus.pickedUp.courierCanCancel)
        XCTAssertFalse(OrderStatus.delivering.courierCanCancel)
        XCTAssertFalse(OrderStatus.courierArrivedCustomer.courierCanCancel)
    }

    func test_cancelledByCourier_isTerminalAndCancelled() {
        XCTAssertTrue(OrderStatus.cancelledByCourier.isTerminal)
        XCTAssertTrue(OrderStatus.cancelledByCourier.isCancelled)
        XCTAssertFalse(OrderStatus.cancelledByCourier.isActive)
        XCTAssertFalse(OrderStatus.cancelledByCourier.isChatActive)
    }

    func test_serviceErrorDecoder_parsesStructuredReason() {
        let synthetic = "PostgrestError(message: ..., detail: \"{\\\"reason\\\":\\\"WRONG_DELIVERY_CODE\\\"}\", code: P0001)"
        let mapped = ServiceError.from(serverError: NSError(domain: "test", code: 0, userInfo: [
            NSLocalizedDescriptionKey: synthetic
        ]))
        if case .wrongDeliveryCode = mapped { /* ok */ } else {
            XCTFail("Expected .wrongDeliveryCode, got \(String(describing: mapped))")
        }
    }

    func test_serviceErrorDecoder_handlesPostPickupCancel() {
        let blob = "ERROR: cancel_after_pickup_not_allowed\nDETAIL: {\"reason\":\"CANCEL_AFTER_PICKUP_NOT_ALLOWED\",\"status\":\"picked_up\"}"
        let mapped = ServiceError.from(serverError: NSError(domain: "test", code: 0, userInfo: [
            NSLocalizedDescriptionKey: blob
        ]))
        if case .cancelAfterPickupNotAllowed = mapped { /* ok */ } else {
            XCTFail("Expected .cancelAfterPickupNotAllowed, got \(String(describing: mapped))")
        }
    }

    func test_serviceErrorDecoder_returnsNilForUnstructured() {
        let mapped = ServiceError.from(serverError: NSError(domain: "test", code: 0, userInfo: [
            NSLocalizedDescriptionKey: "Generic server error with no detail"
        ]))
        XCTAssertNil(mapped)
    }
}
