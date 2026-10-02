import Foundation
import Supabase

extension SupabaseService {
    // MARK: - Addresses

    public func fetchAddresses() async throws -> [Address] {
        try await client.from("addresses")
            .select()
            .order("is_default", ascending: false)
            .execute()
            .value
    }

    public func createAddress(_ address: AddressInsert) async throws -> Address {
        try await client.from("addresses")
            .insert(address)
            .select()
            .single()
            .execute()
            .value
    }

    public func deleteAddress(id: UUID) async throws {
        try await client.from("addresses")
            .delete()
            .eq("id", value: id.uuidString)
            .execute()
    }
}
