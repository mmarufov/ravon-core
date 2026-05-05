import Combine
import Foundation
import Supabase

@MainActor
public final class AuthService: ObservableObject {
    public static let shared = AuthService()

    @Published public private(set) var session: Session?
    @Published public private(set) var isLoaded = false
    @Published public private(set) var userRole: UserRole?

    private let client: SupabaseClient

    public var isSignedIn: Bool { session != nil }
    public var accessToken: String? { session?.accessToken }
    public var supabaseClient: SupabaseClient { client }
    public var userId: UUID? { session?.user.id }
    public var userEmail: String? { session?.user.email }

    public init() {
        precondition(RavonCore.isConfigured, "Call RavonCore.configure() before using AuthService")
        client = SupabaseClient(supabaseURL: RavonCore.supabaseURL, supabaseKey: RavonCore.supabaseAnonKey)
        Task { await loadSession() }
    }

    // MARK: - Session

    public func loadSession() async {
        do {
            session = try await client.auth.session
            if session != nil {
                await loadUserRole()
            }
        } catch {
            session = nil
        }
        isLoaded = true
    }

    private func loadUserRole() async {
        guard let uid = session?.user.id else { return }
        do {
            let profile: Profile = try await client.from("profiles")
                .select("*")
                .eq("id", value: uid.uuidString)
                .single()
                .execute()
                .value
            userRole = profile.role
        } catch {
            userRole = nil
        }
    }

    // MARK: - Sign up / sign in / sign out

    /// Creates an unconfirmed user. The Supabase project must have
    /// "Confirm email" enabled — after this call the user has NO session
    /// until they verify the OTP via `verifySignUpOTP(email:token:)`.
    /// `full_name` and `role` are persisted into `auth.users.raw_user_meta_data`
    /// and copied into `public.profiles` by the `handle_new_user` trigger.
    public func signUp(email: String, password: String, fullName: String, role: UserRole) async throws {
        do {
            try await client.auth.signUp(
                email: email,
                password: password,
                data: [
                    "full_name": .string(fullName),
                    "role": .string(role.rawValue)
                ]
            )
        } catch {
            throw AuthError.from(error)
        }
        // No loadSession() — user is not signed in until they verify OTP.
    }

    public func signIn(email: String, password: String) async throws {
        do {
            try await client.auth.signIn(email: email, password: password)
        } catch {
            throw AuthError.from(error)
        }
        await loadSession()
    }

    public func signOut() async throws {
        do {
            try await client.auth.signOut()
        } catch {
            throw AuthError.from(error)
        }
        session = nil
        userRole = nil
    }

    // MARK: - Email OTP — sign-up confirmation

    /// Verifies the 6-digit signup confirmation code. On success the user is
    /// signed in. The `handle_new_user` trigger has already created the
    /// profile row at this point, but we poll once with a 1s retry to absorb
    /// trigger latency before exposing `userRole`.
    public func verifySignUpOTP(email: String, token: String) async throws {
        do {
            _ = try await client.auth.verifyOTP(email: email, token: token, type: .signup)
        } catch {
            throw AuthError.from(error)
        }
        await loadSession()
        if userRole == nil {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await loadUserRole()
        }
    }

    /// Re-sends the 6-digit signup confirmation code. Per Supabase docs this
    /// succeeds in both cases (existing email vs. not) to avoid leaking
    /// account existence.
    public func resendSignUpOTP(email: String) async throws {
        do {
            try await client.auth.resend(email: email, type: .signup)
        } catch {
            throw AuthError.from(error)
        }
    }

    // MARK: - Password recovery (forgot password)

    /// Sends a 6-digit recovery code to the email address. The dashboard
    /// "Reset password" template must use `{{ .Token }}` so the code arrives
    /// as plain digits rather than a magic link.
    public func requestPasswordRecovery(email: String) async throws {
        do {
            try await client.auth.resetPasswordForEmail(email)
        } catch {
            throw AuthError.from(error)
        }
    }

    /// Verifies the recovery OTP. On success the user has a temporary session
    /// that allows `setNewPassword(_:)` to succeed.
    public func verifyRecoveryOTP(email: String, token: String) async throws {
        do {
            _ = try await client.auth.verifyOTP(email: email, token: token, type: .recovery)
        } catch {
            throw AuthError.from(error)
        }
        await loadSession()
    }

    // MARK: - Password change

    /// Sets a new password on the currently-signed-in user. Use this after
    /// `verifyRecoveryOTP` (forgot-password flow) or as the second step of
    /// `changePassword(current:new:)`.
    public func setNewPassword(_ newPassword: String) async throws {
        do {
            _ = try await client.auth.update(user: UserAttributes(password: newPassword))
        } catch {
            throw AuthError.from(error)
        }
    }

    /// Settings-flow change-password. Re-authenticates the user with their
    /// current password to confirm identity (Supabase has no native re-auth
    /// for password updates), then sets the new password.
    public func changePassword(current: String, new: String) async throws {
        guard let email = session?.user.email else {
            throw AuthError.invalidCredentials
        }
        do {
            try await client.auth.signIn(email: email, password: current)
        } catch {
            // Wrong current password — surface as invalidCredentials.
            throw AuthError.from(error)
        }
        try await setNewPassword(new)
    }
}
