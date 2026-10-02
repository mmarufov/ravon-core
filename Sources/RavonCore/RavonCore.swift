import Foundation
import Supabase

/// Each app provides its config at launch via `RavonCore.configure(...)`.
/// This replaces the hardcoded AppConfig so all 3 apps share the same services
/// but each can point to different Supabase projects if needed.
public enum RavonCore {
    private(set) static var supabaseURL: URL!
    private(set) static var supabaseAnonKey: String!
    private(set) static var isConfigured = false

    /// Call this once in your App's init or @main before using any services.
    /// Example:
    /// ```
    /// RavonCore.configure(
    ///     supabaseURL: URL(string: "https://xxx.supabase.co")!,
    ///     supabaseAnonKey: "eyJ..."
    /// )
    /// ```
    public static func configure(supabaseURL: URL, supabaseAnonKey: String) {
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
        self.isConfigured = true
    }
}
