#if canImport(UIKit)
import Combine
import Foundation
import SwiftUI

/// State machine driving every screen in `RavonAuthFlow`. Lives in
/// RavonCore so all 3 apps share identical transitions / error handling.
@MainActor
public final class AuthFlowViewModel: ObservableObject {
    public enum Step: Equatable {
        case signIn
        case signUp
        case otpSignUp(email: String)
        case forgotEmail
        case otpRecovery(email: String)
        case newPasswordAfterRecovery
    }

    @Published public var step: Step = .signIn
    @Published public var prefilledEmail: String = ""

    /// Inline error rendered at the top of the current screen.
    @Published public var inlineError: AuthError?

    /// Banner CTA shown above forms — used to suggest "you already have an
    /// account, click to sign in" without losing the typed email.
    @Published public var inlineBanner: BannerCTA?

    /// Resend cooldown end-date keyed by `email + step` so the timer survives
    /// re-entering the OTP screen (e.g. user goes back to fix the email then
    /// returns).
    @Published public var resendCooldownUntil: [String: Date] = [:]

    /// Counts how many times the user has resent OTP for this email so we can
    /// apply 60s → 120s → 300s back-off.
    private var resendCount: [String: Int] = [:]

    public let role: UserRole

    private let auth: AuthService

    public init(role: UserRole, auth: AuthService = .shared) {
        self.role = role
        self.auth = auth
    }

    // MARK: - Public actions

    public func go(to step: Step) {
        inlineError = nil
        inlineBanner = nil
        self.step = step
    }

    public func presentSignIn(prefillEmail: String? = nil) {
        if let e = prefillEmail { prefilledEmail = e }
        go(to: .signIn)
    }

    public func presentSignUp() {
        go(to: .signUp)
    }

    public func presentForgotPassword(prefillEmail: String? = nil) {
        if let e = prefillEmail { prefilledEmail = e }
        go(to: .forgotEmail)
    }

    public func dismissBanner() { inlineBanner = nil }

    public func clearInlineError() { inlineError = nil }

    // MARK: - Sign in

    public func performSignIn(email: String, password: String) async -> Bool {
        inlineError = nil
        do {
            try await auth.signIn(email: email, password: password)
            return true
        } catch let e as AuthError {
            switch e {
            case .emailNotConfirmed:
                // Auto-jump into OTP confirmation, prefilling the email
                // and quietly resending so the user immediately sees a code.
                prefilledEmail = email
                Task { try? await auth.resendSignUpOTP(email: email) }
                bumpResendCount(for: email, step: "signup")
                go(to: .otpSignUp(email: email))
                return false
            default:
                inlineError = e
                return false
            }
        } catch {
            inlineError = AuthError.from(error)
            return false
        }
    }

    // MARK: - Sign up

    public func performSignUp(email: String, password: String, fullName: String) async -> Bool {
        inlineError = nil
        inlineBanner = nil

        do {
            try await auth.signUp(email: email, password: password, fullName: fullName, role: role)
            prefilledEmail = email
            startResendCooldown(for: email, step: "signup")
            go(to: .otpSignUp(email: email))
            return true
        } catch let e as AuthError {
            if case .emailAlreadyInUse = e {
                inlineBanner = .init(
                    text: "Аккаунт с такой почтой уже существует.",
                    action: .signInWith(email: email)
                )
            } else {
                inlineError = e
            }
            return false
        } catch {
            inlineError = AuthError.from(error)
            return false
        }
    }

    // MARK: - OTP — sign-up

    public func performVerifySignUp(email: String, code: String) async -> Bool {
        inlineError = nil
        do {
            try await auth.verifySignUpOTP(email: email, token: code)
            return true
        } catch let e as AuthError {
            inlineError = e
            return false
        } catch {
            inlineError = AuthError.from(error)
            return false
        }
    }

    public func performResendSignUp(email: String) async {
        inlineError = nil
        do {
            try await auth.resendSignUpOTP(email: email)
            bumpResendCount(for: email, step: "signup")
            startResendCooldown(for: email, step: "signup")
        } catch let e as AuthError {
            inlineError = e
        } catch {
            inlineError = AuthError.from(error)
        }
    }

    // MARK: - Forgot password

    public func performRequestRecovery(email: String) async -> Bool {
        inlineError = nil
        do {
            try await auth.requestPasswordRecovery(email: email)
            prefilledEmail = email
            startResendCooldown(for: email, step: "recovery")
            go(to: .otpRecovery(email: email))
            return true
        } catch let e as AuthError {
            inlineError = e
            return false
        } catch {
            inlineError = AuthError.from(error)
            return false
        }
    }

    public func performVerifyRecovery(email: String, code: String) async -> Bool {
        inlineError = nil
        do {
            try await auth.verifyRecoveryOTP(email: email, token: code)
            go(to: .newPasswordAfterRecovery)
            return true
        } catch let e as AuthError {
            inlineError = e
            return false
        } catch {
            inlineError = AuthError.from(error)
            return false
        }
    }

    public func performResendRecovery(email: String) async {
        inlineError = nil
        do {
            try await auth.requestPasswordRecovery(email: email)
            bumpResendCount(for: email, step: "recovery")
            startResendCooldown(for: email, step: "recovery")
        } catch let e as AuthError {
            inlineError = e
        } catch {
            inlineError = AuthError.from(error)
        }
    }

    public func performSetNewPassword(_ password: String) async -> Bool {
        inlineError = nil
        do {
            try await auth.setNewPassword(password)
            return true
        } catch let e as AuthError {
            inlineError = e
            return false
        } catch {
            inlineError = AuthError.from(error)
            return false
        }
    }

    // MARK: - Resend cooldown helpers

    public func resendCooldownRemaining(email: String, step: String) -> TimeInterval {
        let key = email.lowercased() + ":" + step
        guard let until = resendCooldownUntil[key] else { return 0 }
        return max(0, until.timeIntervalSinceNow)
    }

    private func bumpResendCount(for email: String, step: String) {
        let key = email.lowercased() + ":" + step
        resendCount[key, default: 0] += 1
    }

    private func startResendCooldown(for email: String, step: String) {
        let key = email.lowercased() + ":" + step
        let n = resendCount[key, default: 0]
        let seconds: TimeInterval = Self.cooldownSeconds(for: n)
        resendCooldownUntil[key] = Date().addingTimeInterval(seconds)
    }

    /// 0 → 60s, 1 → 60s, 2 → 120s, 3+ → 300s.
    /// Public so unit tests can verify the back-off.
    public nonisolated static func cooldownSeconds(for resendIndex: Int) -> TimeInterval {
        switch resendIndex {
        case ..<2: return 60
        case 2: return 120
        default: return 300
        }
    }
}

public extension AuthFlowViewModel {
    struct BannerCTA: Equatable {
        public enum Action: Equatable {
            case signInWith(email: String)
        }
        public let text: String
        public let action: Action
    }
}
#endif
