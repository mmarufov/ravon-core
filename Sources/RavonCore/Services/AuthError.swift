import Foundation

/// Typed auth errors surfaced by `AuthService`.
///
/// Every method in `AuthService` funnels caught errors through
/// `AuthError.from(_:)` and rethrows the typed value, so call sites can
/// `catch let e as AuthError` and render appropriate UX.
public enum AuthError: LocalizedError, Sendable, Equatable {
    /// Sign-up with an email that already has a confirmed account.
    case emailAlreadyInUse
    /// Sign-in attempted before the user verified their email.
    case emailNotConfirmed
    /// Wrong email or password on sign-in.
    case invalidCredentials
    /// Password didn't pass the server-side strength check.
    case weakPassword(minLength: Int)
    /// OTP token has expired (default 10 min).
    case otpExpired
    /// OTP token didn't match what the server issued.
    case otpInvalid
    /// Hit the email-send or auth rate limit.
    case rateLimited(retryAfter: TimeInterval?)
    /// "Forgot password" or sign-in with an email that doesn't exist.
    case userNotFound
    /// Transport-level failure (offline, DNS, TLS).
    case networkError
    /// Anything else — the raw description is preserved for logs.
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .emailAlreadyInUse:
            return "Аккаунт с такой почтой уже существует. Войдите или восстановите пароль."
        case .emailNotConfirmed:
            return "Почта не подтверждена. Введите код из письма."
        case .invalidCredentials:
            return "Неверная почта или пароль."
        case .weakPassword(let n):
            return "Пароль слишком короткий — минимум \(n) символов."
        case .otpExpired:
            return "Срок действия кода истёк. Запросите новый."
        case .otpInvalid:
            return "Неверный код. Проверьте письмо ещё раз."
        case .rateLimited(let retry):
            if let r = retry, r > 0 {
                return "Слишком много попыток. Повторите через \(Int(ceil(r))) сек."
            }
            return "Слишком много попыток. Повторите через минуту."
        case .userNotFound:
            return "Аккаунт с такой почтой не найден."
        case .networkError:
            return "Нет соединения. Проверьте интернет и повторите."
        case .unknown(let s):
            return s.isEmpty ? "Произошла ошибка. Попробуйте ещё раз." : s
        }
    }

    /// Best-effort decoder over an arbitrary `Error` thrown by the Supabase
    /// Swift SDK. The SDK doesn't expose a uniform error type across versions,
    /// so we inspect `String(describing:)` for known codes/messages and fall
    /// back to `.unknown`. Network failures are detected via `URLError`.
    public static func from(_ error: Error) -> AuthError {
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet,
                 .timedOut,
                 .networkConnectionLost,
                 .cannotConnectToHost,
                 .dnsLookupFailed,
                 .secureConnectionFailed:
                return .networkError
            default:
                break
            }
        }

        let raw = String(describing: error).lowercased()

        // Codes (canonical Supabase auth error_code values).
        if raw.contains("user_already_exists") || raw.contains("user already registered") {
            return .emailAlreadyInUse
        }
        if raw.contains("email_not_confirmed") || raw.contains("email not confirmed") {
            return .emailNotConfirmed
        }
        if raw.contains("invalid_credentials") || raw.contains("invalid login credentials") {
            return .invalidCredentials
        }
        if raw.contains("otp_expired") || raw.contains("token has expired") {
            return .otpExpired
        }
        if raw.contains("over_email_send_rate_limit") || raw.contains("over_request_rate_limit") || raw.contains("rate limit") {
            return .rateLimited(retryAfter: extractRetryAfter(from: raw))
        }
        if raw.contains("weak_password") {
            return .weakPassword(minLength: 8)
        }
        if raw.contains("user_not_found") || raw.contains("no user found") {
            return .userNotFound
        }
        if raw.contains("invalid_otp") || raw.contains("token") && raw.contains("invalid") {
            return .otpInvalid
        }

        // HTTP status fallbacks visible in the description.
        if raw.contains("status code: 429") { return .rateLimited(retryAfter: nil) }
        if raw.contains("status code: 401") || raw.contains("status code: 403") {
            return .invalidCredentials
        }

        return .unknown(String(describing: error))
    }

    /// Pulls a numeric "retry after N" hint out of the error description.
    private static func extractRetryAfter(from raw: String) -> TimeInterval? {
        let pattern = #"(?:retry[_ -]?after|wait)\D{0,8}(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: raw),
              let n = Double(raw[r]) else {
            return nil
        }
        return n
    }
}
