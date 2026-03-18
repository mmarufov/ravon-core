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

    public init() {
        precondition(RavonCore.isConfigured, "Call RavonCore.configure() before using AuthService")
        client = SupabaseClient(supabaseURL: RavonCore.supabaseURL, supabaseKey: RavonCore.supabaseAnonKey)
        Task { await loadSession() }
    }

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

    public func signUp(email: String, password: String, fullName: String, role: UserRole) async throws {
        try await client.auth.signUp(
            email: email,
            password: password,
            data: [
                "full_name": .string(fullName),
                "role": .string(role.rawValue)
            ]
        )
        await loadSession()
    }

    public func signIn(email: String, password: String) async throws {
        try await client.auth.signIn(email: email, password: password)
        await loadSession()
    }

    public func signOut() async throws {
        try await client.auth.signOut()
        session = nil
        userRole = nil
    }
}
