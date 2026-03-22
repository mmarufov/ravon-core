import Foundation

public struct ModifierGroup: Codable, Identifiable, Sendable {
    public let id: UUID
    public let restaurantId: UUID
    public let name: String
    public let isRequired: Bool
    public let minSelections: Int
    public let maxSelections: Int
    public let sortOrder: Int
    public let options: [ModifierOption]?

    public init(
        id: UUID, restaurantId: UUID, name: String,
        isRequired: Bool, minSelections: Int, maxSelections: Int,
        sortOrder: Int, options: [ModifierOption]? = nil
    ) {
        self.id = id
        self.restaurantId = restaurantId
        self.name = name
        self.isRequired = isRequired
        self.minSelections = minSelections
        self.maxSelections = maxSelections
        self.sortOrder = sortOrder
        self.options = options
    }

    enum CodingKeys: String, CodingKey {
        case id
        case restaurantId = "restaurant_id"
        case name
        case isRequired = "is_required"
        case minSelections = "min_selections"
        case maxSelections = "max_selections"
        case sortOrder = "sort_order"
        case options = "modifier_options"
    }
}

public struct ModifierOption: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let groupId: UUID
    public let name: String
    public let priceAdjustment: Double
    public let isAvailable: Bool
    public let sortOrder: Int

    public init(
        id: UUID, groupId: UUID, name: String,
        priceAdjustment: Double, isAvailable: Bool, sortOrder: Int
    ) {
        self.id = id
        self.groupId = groupId
        self.name = name
        self.priceAdjustment = priceAdjustment
        self.isAvailable = isAvailable
        self.sortOrder = sortOrder
    }

    enum CodingKeys: String, CodingKey {
        case id
        case groupId = "group_id"
        case name
        case priceAdjustment = "price_adjustment"
        case isAvailable = "is_available"
        case sortOrder = "sort_order"
    }
}

public struct MenuItemModifierGroup: Codable, Sendable {
    public let menuItemId: UUID
    public let modifierGroupId: UUID

    public init(menuItemId: UUID, modifierGroupId: UUID) {
        self.menuItemId = menuItemId
        self.modifierGroupId = modifierGroupId
    }

    enum CodingKeys: String, CodingKey {
        case menuItemId = "menu_item_id"
        case modifierGroupId = "modifier_group_id"
    }
}

public struct OrderItemModifier: Codable, Identifiable, Sendable {
    public let id: UUID
    public let orderItemId: UUID
    public let modifierOptionId: UUID
    public let modifierGroupName: String
    public let modifierOptionName: String
    public let priceAdjustment: Double

    public init(
        id: UUID, orderItemId: UUID, modifierOptionId: UUID,
        modifierGroupName: String, modifierOptionName: String,
        priceAdjustment: Double
    ) {
        self.id = id
        self.orderItemId = orderItemId
        self.modifierOptionId = modifierOptionId
        self.modifierGroupName = modifierGroupName
        self.modifierOptionName = modifierOptionName
        self.priceAdjustment = priceAdjustment
    }

    enum CodingKeys: String, CodingKey {
        case id
        case orderItemId = "order_item_id"
        case modifierOptionId = "modifier_option_id"
        case modifierGroupName = "modifier_group_name"
        case modifierOptionName = "modifier_option_name"
        case priceAdjustment = "price_adjustment"
    }
}
