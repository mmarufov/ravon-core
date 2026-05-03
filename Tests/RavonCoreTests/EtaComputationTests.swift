import XCTest
@testable import RavonCore

final class EtaComputationTests: XCTestCase {
    func test_orderEta_decodesFromOrdersRow() throws {
        // Synthesize a "next year" ISO date so the warning logic sees a future SLA.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let future = formatter.string(from: Date(timeIntervalSinceNow: 60 * 60))
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "eta_minutes": 7,
          "expected_action_by": "\(future)",
          "courier_delay_reason_code": null,
          "courier_delay_explained_at": null,
          "courier_no_show_warned_at": null,
          "courier_no_show_escalated_at": null,
          "status": "delivering"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let eta = try decoder.decode(OrderEta.self, from: json)
        XCTAssertEqual(eta.etaMinutes, 7)
        XCTAssertEqual(eta.status, .delivering)
        XCTAssertFalse(eta.delayWarningActive) // future timestamp
        XCTAssertFalse(eta.escalated)
    }

    func test_orderEta_decodesNullEta() throws {
        // Right after claim, before first heartbeat, eta_minutes is NULL.
        let json = #"""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "eta_minutes": null,
          "expected_action_by": null,
          "courier_delay_reason_code": null,
          "courier_delay_explained_at": null,
          "courier_no_show_warned_at": null,
          "courier_no_show_escalated_at": null,
          "status": "assigned"
        }
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let eta = try decoder.decode(OrderEta.self, from: json)
        XCTAssertNil(eta.etaMinutes)
        XCTAssertNil(eta.expectedActionBy)
        XCTAssertEqual(eta.status, .assigned)
        XCTAssertFalse(eta.delayWarningActive)
    }

    func test_orderEta_courierDelayReasonRoundTrip() {
        let eta = OrderEta(
            orderId: UUID(),
            etaMinutes: 3,
            expectedActionBy: Date(timeIntervalSinceNow: 60),
            courierDelayReasonCode: CourierDelayReason.traffic.rawValue,
            courierDelayExplainedAt: Date(),
            courierNoShowWarnedAt: nil,
            courierNoShowEscalatedAt: nil,
            status: .delivering
        )
        XCTAssertEqual(eta.courierDelayReasonCode, "traffic")
        XCTAssertEqual(CourierDelayReason(rawValue: eta.courierDelayReasonCode!), .traffic)
    }
}
