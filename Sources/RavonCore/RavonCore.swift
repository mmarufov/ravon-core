public enum RavonCore {
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
