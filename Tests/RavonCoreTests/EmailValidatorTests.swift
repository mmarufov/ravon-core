#if canImport(UIKit)
import XCTest
@testable import RavonCore

final class EmailValidatorTests: XCTestCase {
    func testValidEmails() {
        XCTAssertTrue(EmailValidator.isLikelyValid("a@b.co"))
        XCTAssertTrue(EmailValidator.isLikelyValid("user.name+tag@example.com"))
        XCTAssertTrue(EmailValidator.isLikelyValid("MUHAMMADJON@RAVON.TJ"))
    }

    func testInvalidEmails() {
        XCTAssertFalse(EmailValidator.isLikelyValid(""))
        XCTAssertFalse(EmailValidator.isLikelyValid("notanemail"))
        XCTAssertFalse(EmailValidator.isLikelyValid("@example.com"))
        XCTAssertFalse(EmailValidator.isLikelyValid("user@"))
        XCTAssertFalse(EmailValidator.isLikelyValid("user@domain"))   // no dot in domain
        XCTAssertFalse(EmailValidator.isLikelyValid("a@b"))           // too short
    }

    func testTrimsWhitespace() {
        XCTAssertTrue(EmailValidator.isLikelyValid("  user@example.com  "))
    }
}
#endif
