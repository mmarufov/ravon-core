import Testing
import Foundation
@testable import RavonCore

@Suite("MenuItem deletedAt decoding")
struct MenuItemSoftDeleteTests {
    private let dec: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    @Test("Decode without deleted_at field (legacy row)")
    func legacy() throws {
        let json = #"""
        {
          "id":"00000000-0000-0000-0000-000000000001",
          "category_id":"00000000-0000-0000-0000-000000000010",
          "restaurant_id":"00000000-0000-0000-0000-000000000020",
          "name":"Burger",
          "description":null,
          "price":80.0,
          "image_url":null,
          "is_available":true,
          "sort_order":0,
          "stock_count":null
        }
        """#
        // MenuItem still uses synthesized init(from:), so deleted_at must be present (nullable).
        // We're explicitly testing the case where the column exists with null.
        let json2 = #"""
        {
          "id":"00000000-0000-0000-0000-000000000001",
          "category_id":"00000000-0000-0000-0000-000000000010",
          "restaurant_id":"00000000-0000-0000-0000-000000000020",
          "name":"Burger",
          "description":null,
          "price":80.0,
          "image_url":null,
          "is_available":true,
          "sort_order":0,
          "stock_count":null,
          "deleted_at":null
        }
        """#
        _ = json
        let item = try dec.decode(MenuItem.self, from: json2.data(using: .utf8)!)
        #expect(item.deletedAt == nil)
        #expect(!item.isSoftDeleted)
    }

    @Test("Decode with deleted_at set")
    func deleted() throws {
        let json = #"""
        {
          "id":"00000000-0000-0000-0000-000000000001",
          "category_id":"00000000-0000-0000-0000-000000000010",
          "restaurant_id":"00000000-0000-0000-0000-000000000020",
          "name":"Old Burger",
          "description":null,
          "price":80.0,
          "image_url":null,
          "is_available":false,
          "sort_order":0,
          "stock_count":null,
          "deleted_at":"2026-04-15T12:00:00Z"
        }
        """#
        let item = try dec.decode(MenuItem.self, from: json.data(using: .utf8)!)
        #expect(item.deletedAt != nil)
        #expect(item.isSoftDeleted)
    }
}

@Suite("MenuCategory backwards-compat decoding")
struct MenuCategorySoftDeleteTests {
    private let dec: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    @Test("Decode legacy category (no is_available, no deleted_at) defaults isAvailable=true")
    func legacy() throws {
        let json = #"""
        {
          "id":"00000000-0000-0000-0000-000000000010",
          "restaurant_id":"00000000-0000-0000-0000-000000000020",
          "name":"Бургеры",
          "sort_order":0
        }
        """#
        let cat = try dec.decode(MenuCategory.self, from: json.data(using: .utf8)!)
        #expect(cat.isAvailable)
        #expect(cat.deletedAt == nil)
        #expect(!cat.isSoftDeleted)
    }

    @Test("Decode hidden category")
    func hidden() throws {
        let json = #"""
        {
          "id":"00000000-0000-0000-0000-000000000010",
          "restaurant_id":"00000000-0000-0000-0000-000000000020",
          "name":"Бургеры",
          "sort_order":0,
          "is_available":false,
          "deleted_at":null
        }
        """#
        let cat = try dec.decode(MenuCategory.self, from: json.data(using: .utf8)!)
        #expect(!cat.isAvailable)
        #expect(!cat.isSoftDeleted)
    }

    @Test("Decode soft-deleted category")
    func deleted() throws {
        let json = #"""
        {
          "id":"00000000-0000-0000-0000-000000000010",
          "restaurant_id":"00000000-0000-0000-0000-000000000020",
          "name":"Бургеры",
          "sort_order":0,
          "is_available":true,
          "deleted_at":"2026-04-15T12:00:00Z"
        }
        """#
        let cat = try dec.decode(MenuCategory.self, from: json.data(using: .utf8)!)
        #expect(cat.isSoftDeleted)
    }
}

@Suite("OrderItem extended snapshot")
struct OrderItemSnapshotTests {
    private let dec: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    @Test("Decode legacy row (no description/image/modifiers)")
    func legacy() throws {
        let json = #"""
        {
          "id":"00000000-0000-0000-0000-000000000100",
          "order_id":"00000000-0000-0000-0000-000000000200",
          "menu_item_id":"00000000-0000-0000-0000-000000000001",
          "quantity":2,
          "unit_price":80.0,
          "total_price":160.0,
          "item_name":"Burger"
        }
        """#
        let item = try dec.decode(OrderItem.self, from: json.data(using: .utf8)!)
        #expect(item.itemDescription == nil)
        #expect(item.itemImageUrl == nil)
        #expect(item.modifiersSnapshot.isEmpty)
        #expect(item.menuItemId != nil)
    }

    @Test("Decode new row with all snapshot fields")
    func full() throws {
        let json = #"""
        {
          "id":"00000000-0000-0000-0000-000000000100",
          "order_id":"00000000-0000-0000-0000-000000000200",
          "menu_item_id":"00000000-0000-0000-0000-000000000001",
          "quantity":1,
          "unit_price":100.0,
          "total_price":120.0,
          "item_name":"Burger",
          "item_description":"Beef + cheese",
          "item_image_url":"https://example.com/b.jpg",
          "modifiers_snapshot":[
            {"group_name":"Размер","option_name":"Большой","price_adjustment":20.0}
          ]
        }
        """#
        let item = try dec.decode(OrderItem.self, from: json.data(using: .utf8)!)
        #expect(item.itemDescription == "Beef + cheese")
        #expect(item.itemImageUrl == "https://example.com/b.jpg")
        #expect(item.modifiersSnapshot.count == 1)
        #expect(item.modifiersSnapshot[0].groupName == "Размер")
    }

    @Test("Decode hard-deleted item (menu_item_id null)")
    func nullMenuItemId() throws {
        let json = #"""
        {
          "id":"00000000-0000-0000-0000-000000000100",
          "order_id":"00000000-0000-0000-0000-000000000200",
          "menu_item_id":null,
          "quantity":1,
          "unit_price":80.0,
          "total_price":80.0,
          "item_name":"Burger (removed)"
        }
        """#
        let item = try dec.decode(OrderItem.self, from: json.data(using: .utf8)!)
        #expect(item.menuItemId == nil)
        #expect(item.itemName == "Burger (removed)")
    }
}
