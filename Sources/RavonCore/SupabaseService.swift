import Foundation

@MainActor
public final class SupabaseService {
    public static let shared = SupabaseService()

    public private(set) var supabaseURL: URL?
    public private(set) var supabaseAnonKey: String?

    private init() {}

    public func configure(
        supabaseURL: URL,
        supabaseAnonKey: String
    ) {
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
    }
}
