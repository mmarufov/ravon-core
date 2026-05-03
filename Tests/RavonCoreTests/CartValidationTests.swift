import Testing
import Foundation
@testable import RavonCore

@Suite("CartItemStatus codable")
struct CartItemStatusCodableTests {
    private func roundtrip(_ json: String) throws -> CartItemStatus {
        let data = json.data(using: .utf8)!
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(CartItemStatus.self, from: data)
    }

    @Test("Decode OK")
    func ok() throws {
        let v = try roundtrip(#"{"status":"OK"}"#)
        #expect(v.isOk)
        if case .ok = v {} else { Issue.record("expected .ok") }
    }

    @Test("Decode UNAVAILABLE")
    func unavailable() throws {
        let v = try roundtrip(#"{"status":"UNAVAILABLE"}"#)
        if case .unavailable = v {} else { Issue.record("expected .unavailable") }
    }

    @Test("Decode INSUFFICIENT_STOCK")
    func insufficient() throws {
        let v = try roundtrip(#"{"status":"INSUFFICIENT_STOCK","have":2}"#)
        if case .insufficientStock(let have) = v {
            #expect(have == 2)
        } else {
            Issue.record("expected .insufficientStock")
        }
    }

    @Test("Decode DELETED")
    func deleted() throws {
        let v = try roundtrip(#"{"status":"DELETED"}"#)
        if case .deleted = v {} else { Issue.record("expected .deleted") }
    }

    @Test("Decode PRICE_CHANGED")
    func priceChanged() throws {
        let v = try roundtrip(#"{"status":"PRICE_CHANGED","old_price":50.0,"new_price":60.0}"#)
        if case .priceChanged(let old, let new) = v {
            #expect(old == 50.0)
            #expect(new == 60.0)
        } else {
            Issue.record("expected .priceChanged")
        }
    }
}

@Suite("OrderabilityReason codable")
struct OrderabilityReasonCodableTests {
    private let dec: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    @Test("Decode RESTAURANT_CLOSED")
    func closed() throws {
        let r = try dec.decode(OrderabilityReason.self, from: #"{"kind":"RESTAURANT_CLOSED"}"#.data(using: .utf8)!)
        if case .restaurantClosed = r {} else { Issue.record("expected closed") }
    }

    @Test("Decode RESTAURANT_NOT_ACCEPTING with until")
    func notAccepting() throws {
        let r = try dec.decode(
            OrderabilityReason.self,
            from: #"{"kind":"RESTAURANT_NOT_ACCEPTING","until":"2026-05-03T18:00:00Z"}"#.data(using: .utf8)!
        )
        if case .restaurantNotAccepting(let until) = r {
            #expect(until != nil)
        } else { Issue.record("expected notAccepting") }
    }

    @Test("Decode OUT_OF_HOURS with opens_at")
    func outOfHours() throws {
        let r = try dec.decode(
            OrderabilityReason.self,
            from: #"{"kind":"OUT_OF_HOURS","opens_at":"2026-05-03T04:00:00Z"}"#.data(using: .utf8)!
        )
        if case .outOfHours(let opens) = r {
            #expect(opens != nil)
        } else { Issue.record("expected outOfHours") }
    }

    @Test("Decode MIN_ORDER_NOT_MET")
    func minOrder() throws {
        let r = try dec.decode(OrderabilityReason.self, from: #"{"kind":"MIN_ORDER_NOT_MET","need":50.0}"#.data(using: .utf8)!)
        if case .minOrderNotMet(let need) = r {
            #expect(need == 50.0)
        } else { Issue.record("expected minOrderNotMet") }
    }
}

@Suite("CartValidationResult")
struct CartValidationResultTests {
    private let dec: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    @Test("Decode happy path")
    func happy() throws {
        let json = #"""
        {
          "orderable": true,
          "reason": {"kind":"OK"},
          "items": [
            {"menu_item_id":"00000000-0000-0000-0000-000000000001","status":"OK"}
          ],
          "subtotal": 800.0,
          "min_order_amount": 500.0,
          "min_order_met": true
        }
        """#
        let r = try dec.decode(CartValidationResult.self, from: json.data(using: .utf8)!)
        #expect(r.orderable)
        #expect(r.minOrderMet)
        #expect(!r.hasItemIssues)
        #expect(r.items.count == 1)
    }

    @Test("Decode mixed-issues cart")
    func mixed() throws {
        let json = #"""
        {
          "orderable": false,
          "reason": {"kind":"OUT_OF_HOURS","opens_at":"2026-05-03T04:00:00Z"},
          "items": [
            {"menu_item_id":"00000000-0000-0000-0000-000000000001","status":"OK"},
            {"menu_item_id":"00000000-0000-0000-0000-000000000002","status":"INSUFFICIENT_STOCK","have":2},
            {"menu_item_id":"00000000-0000-0000-0000-000000000003","status":"DELETED"},
            {"menu_item_id":"00000000-0000-0000-0000-000000000004","status":"PRICE_CHANGED","old_price":50.0,"new_price":60.0}
          ],
          "subtotal": 480.0,
          "min_order_amount": 500.0,
          "min_order_met": false
        }
        """#
        let r = try dec.decode(CartValidationResult.self, from: json.data(using: .utf8)!)
        #expect(!r.orderable)
        #expect(!r.minOrderMet)
        #expect(r.hasItemIssues)
        #expect(r.items.count == 4)
        let map = r.itemsByStatus
        #expect(map.values.contains { if case .insufficientStock = $0 { return true } else { return false } })
        #expect(map.values.contains { if case .deleted = $0 { return true } else { return false } })
    }
}
