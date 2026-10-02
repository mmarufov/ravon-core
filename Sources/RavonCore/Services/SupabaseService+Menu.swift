import Foundation
import Supabase

extension SupabaseService {
    // MARK: - Menu

    /// Consumer view: only available, non-soft-deleted categories.
    public func fetchMenuCategories(restaurantId: UUID) async throws -> [MenuCategory] {
        try await client.from("menu_categories")
            .select()
            .eq("restaurant_id", value: restaurantId.uuidString)
            .eq("is_available", value: true)
            .is("deleted_at", value: nil)
            .order("sort_order")
            .execute()
            .value
    }

    /// Consumer view: only available, non-soft-deleted items.
    public func fetchMenuItems(restaurantId: UUID) async throws -> [MenuItem] {
        try await client.from("menu_items")
            .select()
            .eq("restaurant_id", value: restaurantId.uuidString)
            .eq("is_available", value: true)
            .is("deleted_at", value: nil)
            .order("sort_order")
            .execute()
            .value
    }

    // MARK: - Modifiers

    /// Fetch modifier groups for a specific menu item (consumer view, via junction table)
    public func fetchModifierGroups(menuItemId: UUID) async throws -> [ModifierGroup] {
        let junctions: [MenuItemModifierGroup] = try await client.from("menu_item_modifier_groups")
            .select()
            .eq("menu_item_id", value: menuItemId.uuidString)
            .execute()
            .value
        guard !junctions.isEmpty else { return [] }
        let groupIds = junctions.map { $0.modifierGroupId.uuidString }
        return try await client.from("modifier_groups")
            .select("*, modifier_options(*)")
            .in("id", values: groupIds)
            .order("sort_order")
            .execute()
            .value
    }

    /// Fetch all modifier groups for a restaurant (merchant management view)
    public func fetchAllModifierGroups(restaurantId: UUID) async throws -> [ModifierGroup] {
        try await client.from("modifier_groups")
            .select("*, modifier_options(*)")
            .eq("restaurant_id", value: restaurantId.uuidString)
            .order("sort_order")
            .execute()
            .value
    }

    // MARK: - Merchant Menu Management

    /// Fetch all menu items including unavailable AND soft-deleted ones (merchant view).
    /// Merchant UI greys out soft-deleted rows and offers a restore action within the 30-day grace.
    public func fetchAllMenuItems(restaurantId: UUID) async throws -> [MenuItem] {
        try await client.from("menu_items")
            .select()
            .eq("restaurant_id", value: restaurantId.uuidString)
            .order("sort_order")
            .execute()
            .value
    }

    /// Merchant view of categories (includes hidden + soft-deleted within grace).
    public func fetchAllMenuCategories(restaurantId: UUID) async throws -> [MenuCategory] {
        try await client.from("menu_categories")
            .select()
            .eq("restaurant_id", value: restaurantId.uuidString)
            .order("sort_order")
            .execute()
            .value
    }

    /// Show/hide a category to consumers without deleting it. Items inside an unavailable
    /// category are also hidden (consumer query filters categories first).
    public func toggleMenuCategoryAvailability(id: UUID, isAvailable: Bool) async throws {
        try await client.from("menu_categories")
            .update(["is_available": AnyJSON.bool(isAvailable)])
            .eq("id", value: id.uuidString)
            .execute()
    }

    public func toggleMenuItemAvailability(id: UUID, isAvailable: Bool) async throws {
        try await client.from("menu_items")
            .update(["is_available": AnyJSON.bool(isAvailable)])
            .eq("id", value: id.uuidString)
            .execute()
    }

    public func updateStock(menuItemId: UUID, count: Int?) async throws {
        let value: AnyJSON = count.map { AnyJSON.integer($0) } ?? .null
        try await client.from("menu_items")
            .update(["stock_count": value])
            .eq("id", value: menuItemId.uuidString)
            .execute()
    }

    public func updateMenuItem(
        id: UUID,
        name: String? = nil,
        description: String? = nil,
        price: Double? = nil,
        isAvailable: Bool? = nil,
        sortOrder: Int? = nil,
        stockCount: Int? = nil
    ) async throws {
        var updates: [String: AnyJSON] = [:]
        if let name { updates["name"] = .string(name) }
        if let description { updates["description"] = .string(description) }
        if let price { updates["price"] = .double(price) }
        if let isAvailable { updates["is_available"] = .bool(isAvailable) }
        if let sortOrder { updates["sort_order"] = .integer(sortOrder) }
        if let stockCount { updates["stock_count"] = .integer(stockCount) }
        guard !updates.isEmpty else { return }
        try await client.from("menu_items")
            .update(updates)
            .eq("id", value: id.uuidString)
            .execute()
    }

    // MARK: - Menu Category CRUD

    public func createMenuCategory(_ insert: MenuCategoryInsert) async throws -> MenuCategory {
        try await client.from("menu_categories")
            .insert(insert)
            .select()
            .single()
            .execute()
            .value
    }

    public func updateMenuCategory(id: UUID, name: String? = nil, sortOrder: Int? = nil) async throws {
        var updates: [String: AnyJSON] = [:]
        if let name { updates["name"] = .string(name) }
        if let sortOrder { updates["sort_order"] = .integer(sortOrder) }
        guard !updates.isEmpty else { return }
        try await client.from("menu_categories")
            .update(updates)
            .eq("id", value: id.uuidString)
            .execute()
    }

    /// Soft-delete: sets `deleted_at`. Cron purges rows older than 30 days.
    /// Pre-check: category must be empty of non-deleted items.
    public func deleteMenuCategory(id: UUID) async throws {
        let items: [IdRow] = try await client.from("menu_items")
            .select("id")
            .eq("category_id", value: id.uuidString)
            .is("deleted_at", value: nil)
            .limit(1)
            .execute()
            .value
        guard items.isEmpty else { throw ServiceError.categoryNotEmpty }
        try await client.from("menu_categories")
            .update(["deleted_at": AnyJSON.string(Self.isoFormatter.string(from: Date()))])
            .eq("id", value: id.uuidString)
            .execute()
    }

    /// Restore a soft-deleted category (reverses `deleteMenuCategory` if within 30-day grace).
    public func restoreMenuCategory(id: UUID) async throws {
        try await client.from("menu_categories")
            .update(["deleted_at": AnyJSON.null])
            .eq("id", value: id.uuidString)
            .execute()
    }

    // MARK: - Menu Item CRUD

    public func createMenuItem(_ insert: MenuItemInsert) async throws -> MenuItem {
        try await client.from("menu_items")
            .insert(insert)
            .select()
            .single()
            .execute()
            .value
    }

    /// Soft-delete: sets `deleted_at`. The item disappears from consumer fetches
    /// (`fetchMenuItems` filters `deleted_at IS NULL`) but remains for order history.
    /// A daily cron hard-deletes rows where `deleted_at < now() - interval '30 days'`.
    /// Order rows are protected by `ON DELETE SET NULL` + the `OrderItem` snapshot fields.
    public func deleteMenuItem(id: UUID) async throws {
        try await client.from("menu_items")
            .update(["deleted_at": AnyJSON.string(Self.isoFormatter.string(from: Date()))])
            .eq("id", value: id.uuidString)
            .execute()
    }

    /// Restore a soft-deleted menu item (reverses `deleteMenuItem` if within 30-day grace).
    public func restoreMenuItem(id: UUID) async throws {
        try await client.from("menu_items")
            .update(["deleted_at": AnyJSON.null])
            .eq("id", value: id.uuidString)
            .execute()
    }

    // MARK: - Modifier Group CRUD

    public func createModifierGroup(_ insert: ModifierGroupInsert) async throws -> ModifierGroup {
        try await client.from("modifier_groups")
            .insert(insert)
            .select("*, modifier_options(*)")
            .single()
            .execute()
            .value
    }

    public func updateModifierGroup(
        id: UUID, name: String? = nil, isRequired: Bool? = nil,
        minSelections: Int? = nil, maxSelections: Int? = nil, sortOrder: Int? = nil
    ) async throws {
        var updates: [String: AnyJSON] = [:]
        if let name { updates["name"] = .string(name) }
        if let isRequired { updates["is_required"] = .bool(isRequired) }
        if let minSelections { updates["min_selections"] = .integer(minSelections) }
        if let maxSelections { updates["max_selections"] = .integer(maxSelections) }
        if let sortOrder { updates["sort_order"] = .integer(sortOrder) }
        guard !updates.isEmpty else { return }
        try await client.from("modifier_groups")
            .update(updates)
            .eq("id", value: id.uuidString)
            .execute()
    }

    public func deleteModifierGroup(id: UUID) async throws {
        try await client.from("modifier_groups")
            .delete()
            .eq("id", value: id.uuidString)
            .execute()
    }

    // MARK: - Modifier Option CRUD

    public func createModifierOption(_ insert: ModifierOptionInsert) async throws -> ModifierOption {
        try await client.from("modifier_options")
            .insert(insert)
            .select()
            .single()
            .execute()
            .value
    }

    public func updateModifierOption(
        id: UUID, name: String? = nil, priceAdjustment: Double? = nil,
        isAvailable: Bool? = nil, sortOrder: Int? = nil
    ) async throws {
        var updates: [String: AnyJSON] = [:]
        if let name { updates["name"] = .string(name) }
        if let priceAdjustment { updates["price_adjustment"] = .double(priceAdjustment) }
        if let isAvailable { updates["is_available"] = .bool(isAvailable) }
        if let sortOrder { updates["sort_order"] = .integer(sortOrder) }
        guard !updates.isEmpty else { return }
        try await client.from("modifier_options")
            .update(updates)
            .eq("id", value: id.uuidString)
            .execute()
    }

    public func deleteModifierOption(id: UUID) async throws {
        try await client.from("modifier_options")
            .delete()
            .eq("id", value: id.uuidString)
            .execute()
    }

    // MARK: - Modifier Group ↔ Menu Item Linking

    public func linkModifierGroup(menuItemId: UUID, modifierGroupId: UUID) async throws {
        let link = MenuItemModifierGroup(menuItemId: menuItemId, modifierGroupId: modifierGroupId)
        try await client.from("menu_item_modifier_groups")
            .insert(link)
            .execute()
    }

    public func unlinkModifierGroup(menuItemId: UUID, modifierGroupId: UUID) async throws {
        try await client.from("menu_item_modifier_groups")
            .delete()
            .eq("menu_item_id", value: menuItemId.uuidString)
            .eq("modifier_group_id", value: modifierGroupId.uuidString)
            .execute()
    }
}
