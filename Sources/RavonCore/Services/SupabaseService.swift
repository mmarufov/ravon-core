import Foundation
import Supabase

/// The apps' database queries and RPCs. Auth is `AuthService`, and live subscriptions
/// are `RealtimeService`.
///
/// The methods are grouped by domain, one extension per file:
/// `SupabaseService+Orders.swift`, `+Courier`, `+Restaurants`, `+Menu`, `+Profile`,
/// `+Addresses`, `+Chat` and `+Images`. This file holds only the state they share.
@MainActor
public final class SupabaseService {
    public static let shared = SupabaseService()

    var client: SupabaseClient { AuthService.shared.supabaseClient }

    public init() {}

    struct IdRow: Decodable { let id: UUID }
    static let isoFormatter = ISO8601DateFormatter()
}
