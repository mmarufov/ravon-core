import Testing
import Foundation
@testable import RavonCore

@Suite("Insert Struct CodingKeys")
struct InsertStructTests {

    private func encodedKeys(_ value: some Encodable) throws -> Set<String> {
        let data = try JSONEncoder().encode(value)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return Set(dict.keys)
    }

    @Test("RestaurantInsert produces correct snake_case keys")
    func restaurantInsert() throws {
        let insert = RestaurantInsert(
            name: "Test", cuisineType: "uzbek",
            deliveryFee: 5.0, minOrderAmount: 10.0, deliveryTimeMin: 30
        )
        let keys = try encodedKeys(insert)
        #expect(keys.contains("cuisine_type"))
        #expect(keys.contains("delivery_fee"))
        #expect(keys.contains("min_order_amount"))
        #expect(keys.contains("delivery_time_min"))
        #expect(!keys.contains("cuisineType"))
        #expect(!keys.contains("owner_id")) // DB sets this
    }

    @Test("MenuCategoryInsert produces correct snake_case keys")
    func menuCategoryInsert() throws {
        let insert = MenuCategoryInsert(
            restaurantId: UUID(), name: "Салаты", sortOrder: 1
        )
        let keys = try encodedKeys(insert)
        #expect(keys.contains("restaurant_id"))
        #expect(keys.contains("sort_order"))
        #expect(!keys.contains("restaurantId"))
    }

    @Test("MenuItemInsert produces correct snake_case keys")
    func menuItemInsert() throws {
        let insert = MenuItemInsert(
            restaurantId: UUID(), categoryId: UUID(),
            name: "Плов", price: 12.0, imageUrl: "http://test.jpg"
        )
        let keys = try encodedKeys(insert)
        #expect(keys.contains("restaurant_id"))
        #expect(keys.contains("category_id"))
        #expect(keys.contains("image_url"))
        #expect(keys.contains("is_available"))
        #expect(keys.contains("sort_order"))
        #expect(!keys.contains("categoryId"))
    }

    @Test("ModifierGroupInsert produces correct snake_case keys")
    func modifierGroupInsert() throws {
        let insert = ModifierGroupInsert(
            restaurantId: UUID(), name: "Соус"
        )
        let keys = try encodedKeys(insert)
        #expect(keys.contains("restaurant_id"))
        #expect(keys.contains("is_required"))
        #expect(keys.contains("min_selections"))
        #expect(keys.contains("max_selections"))
        #expect(keys.contains("sort_order"))
    }

    @Test("ModifierOptionInsert produces correct snake_case keys")
    func modifierOptionInsert() throws {
        let insert = ModifierOptionInsert(
            groupId: UUID(), name: "Кетчуп"
        )
        let keys = try encodedKeys(insert)
        #expect(keys.contains("group_id"))
        #expect(keys.contains("price_adjustment"))
        #expect(keys.contains("sort_order"))
        #expect(!keys.contains("groupId"))
    }
}
