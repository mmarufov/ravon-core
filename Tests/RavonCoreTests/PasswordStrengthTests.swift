#if canImport(UIKit)
import XCTest
@testable import RavonCore

final class PasswordStrengthTests: XCTestCase {
    typealias Strength = RavonPasswordStrengthMeter.Strength

    func testEmpty() {
        XCTAssertEqual(Strength.evaluate(""), .empty)
    }

    func testTooShort() {
        XCTAssertEqual(Strength.evaluate("abc"), .weak)
        XCTAssertEqual(Strength.evaluate("abcdef7"), .weak) // 7 chars
    }

    func testWeak_singleClass() {
        XCTAssertEqual(Strength.evaluate("aaaaaaaa"), .weak) // 8 chars, lowercase only
        XCTAssertEqual(Strength.evaluate("12345678"), .weak) // digits only
    }

    func testMedium_twoClasses() {
        // 10 chars, lower + digit
        XCTAssertEqual(Strength.evaluate("hello12345"), .medium)
        // 8 chars, two classes — too short to elevate
        XCTAssertEqual(Strength.evaluate("hello123"), .weak)
    }

    func testMedium_threeClassesUnder12() {
        // 8 chars, three classes — capped to medium
        XCTAssertEqual(Strength.evaluate("Hello123"), .medium)
    }

    func testStrong_threeClassesAt12() {
        XCTAssertEqual(Strength.evaluate("Hello1234567"), .strong)
    }

    func testStrong_fourClasses() {
        XCTAssertEqual(Strength.evaluate("Hello!2345"), .strong)
    }
}
#endif
