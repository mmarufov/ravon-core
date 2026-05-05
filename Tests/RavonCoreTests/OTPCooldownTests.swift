#if canImport(UIKit)
import XCTest
@testable import RavonCore

final class OTPCooldownTests: XCTestCase {
    func testBackoffSchedule() {
        // 0 sends → 60s
        XCTAssertEqual(AuthFlowViewModel.cooldownSeconds(for: 0), 60)
        // 1 send → 60s
        XCTAssertEqual(AuthFlowViewModel.cooldownSeconds(for: 1), 60)
        // 2 sends → 120s
        XCTAssertEqual(AuthFlowViewModel.cooldownSeconds(for: 2), 120)
        // 3+ sends → 300s
        XCTAssertEqual(AuthFlowViewModel.cooldownSeconds(for: 3), 300)
        XCTAssertEqual(AuthFlowViewModel.cooldownSeconds(for: 10), 300)
    }
}
#endif
