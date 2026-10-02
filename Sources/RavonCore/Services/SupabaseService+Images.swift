import Foundation
import Supabase

extension SupabaseService {
    // MARK: - Image Upload

    private static let maxImageSize = 5 * 1024 * 1024 // 5 MB
    private static let allowedImageFormats = ["jpg", "jpeg", "png", "webp"]

    /// Upload restaurant image to Supabase Storage, returns public URL string
    public func uploadRestaurantImage(restaurantId: UUID, imageData: Data, fileExtension: String) async throws -> String {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        try validateImage(data: imageData, fileExtension: fileExtension)
        let path = "\(uid.uuidString)/\(restaurantId.uuidString).\(fileExtension)"
        try await client.storage.from("restaurant-images")
            .upload(path, data: imageData, options: .init(contentType: "image/\(fileExtension)", upsert: true))
        let publicURL = try client.storage.from("restaurant-images").getPublicURL(path: path)
        // Update restaurant image_url
        try await client.from("restaurants")
            .update(["image_url": AnyJSON.string(publicURL.absoluteString)])
            .eq("id", value: restaurantId.uuidString)
            .execute()
        return publicURL.absoluteString
    }

    /// Upload menu item image to Supabase Storage, returns public URL string
    public func uploadMenuItemImage(menuItemId: UUID, imageData: Data, fileExtension: String) async throws -> String {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        try validateImage(data: imageData, fileExtension: fileExtension)
        let path = "\(uid.uuidString)/\(menuItemId.uuidString).\(fileExtension)"
        try await client.storage.from("menu-item-images")
            .upload(path, data: imageData, options: .init(contentType: "image/\(fileExtension)", upsert: true))
        let publicURL = try client.storage.from("menu-item-images").getPublicURL(path: path)
        // Update menu item image_url
        try await client.from("menu_items")
            .update(["image_url": AnyJSON.string(publicURL.absoluteString)])
            .eq("id", value: menuItemId.uuidString)
            .execute()
        return publicURL.absoluteString
    }

    /// Delete an image from storage
    public func deleteImage(bucket: String, path: String) async throws {
        try await client.storage.from(bucket).remove(paths: [path])
    }

    private func validateImage(data: Data, fileExtension: String) throws {
        guard data.count <= Self.maxImageSize else {
            throw ServiceError.imageTooLarge
        }
        guard Self.allowedImageFormats.contains(fileExtension.lowercased()) else {
            throw ServiceError.unsupportedImageFormat
        }
    }
}
