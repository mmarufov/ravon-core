import Foundation

public enum RavonCore {
    @MainActor
    public static func configure(
        supabaseURL: URL,
        supabaseAnonKey: String
    ) {
        SupabaseService.shared.configure(
            supabaseURL: supabaseURL,
            supabaseAnonKey: supabaseAnonKey
        )
    }
}
