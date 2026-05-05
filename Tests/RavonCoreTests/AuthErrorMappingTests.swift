import XCTest
@testable import RavonCore

final class AuthErrorMappingTests: XCTestCase {

    private struct StringError: Error, CustomStringConvertible {
        let description: String
    }

    func testEmailAlreadyInUse_byCode() {
        let err = StringError(description: #"AuthError(message: "User already registered", error_code: "user_already_exists", status: 422)"#)
        XCTAssertEqual(AuthError.from(err), .emailAlreadyInUse)
    }

    func testEmailAlreadyInUse_byMessage() {
        let err = StringError(description: "User already registered")
        XCTAssertEqual(AuthError.from(err), .emailAlreadyInUse)
    }

    func testEmailNotConfirmed() {
        let err = StringError(description: #"error_code: "email_not_confirmed""#)
        XCTAssertEqual(AuthError.from(err), .emailNotConfirmed)
    }

    func testInvalidCredentials_byCode() {
        let err = StringError(description: #"error_code: "invalid_credentials""#)
        XCTAssertEqual(AuthError.from(err), .invalidCredentials)
    }

    func testInvalidCredentials_byMessage() {
        let err = StringError(description: "Invalid login credentials")
        XCTAssertEqual(AuthError.from(err), .invalidCredentials)
    }

    func testOTPExpired() {
        let err = StringError(description: #"error_code: "otp_expired", message: "Token has expired or is invalid""#)
        XCTAssertEqual(AuthError.from(err), .otpExpired)
    }

    func testRateLimited() {
        let err = StringError(description: #"error_code: "over_email_send_rate_limit""#)
        if case .rateLimited = AuthError.from(err) { /* ok */ } else {
            XCTFail("expected rateLimited")
        }
    }

    func testWeakPassword() {
        let err = StringError(description: #"error_code: "weak_password""#)
        XCTAssertEqual(AuthError.from(err), .weakPassword(minLength: 8))
    }

    func testHTTP429FallsBackToRateLimited() {
        let err = StringError(description: "HTTPStatusCode(rawValue: 429), Status code: 429")
        if case .rateLimited = AuthError.from(err) { /* ok */ } else {
            XCTFail("expected rateLimited from 429")
        }
    }

    func testNetworkErrorDetectedFromURLError() {
        let err = URLError(.notConnectedToInternet)
        XCTAssertEqual(AuthError.from(err), .networkError)
    }

    func testUnknownFallback() {
        let err = StringError(description: "Something completely unrecognized happened")
        if case .unknown = AuthError.from(err) { /* ok */ } else {
            XCTFail("expected unknown")
        }
    }
}
