import XCTest
@testable import RavonCore

final class DeliveryCodeTests: XCTestCase {
    func test_deliveryMode_rawValuesMatchServerCheck() {
        XCTAssertEqual(DeliveryMode.handToMe.rawValue, "hand_to_me")
        XCTAssertEqual(DeliveryMode.leaveAtDoor.rawValue, "leave_at_door")
    }

    func test_deliveryMode_requirements() {
        XCTAssertTrue(DeliveryMode.handToMe.requiresDeliveryCode)
        XCTAssertFalse(DeliveryMode.handToMe.requiresProofImage)
        XCTAssertTrue(DeliveryMode.leaveAtDoor.requiresProofImage)
        XCTAssertFalse(DeliveryMode.leaveAtDoor.requiresDeliveryCode)
    }

    func test_order_decodesBothCodes() throws {
        let json = #"""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "user_id": "22222222-2222-2222-2222-222222222222",
          "restaurant_id": "33333333-3333-3333-3333-333333333333",
          "address_id": null,
          "courier_id": null,
          "status": "ready",
          "subtotal": 100,
          "delivery_fee": 20,
          "total": 120,
          "delivery_address_snapshot": null,
          "notes": null,
          "created_at": "2026-05-03T10:00:00Z",
          "updated_at": "2026-05-03T10:00:00Z",
          "verification_code": "1234",
          "delivery_verification_code": "5678",
          "delivery_mode": "hand_to_me",
          "delivery_proof_url": null
        }
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let order = try decoder.decode(Order.self, from: json)
        XCTAssertEqual(order.pickupVerificationCode, "1234")
        XCTAssertEqual(order.deliveryVerificationCode, "5678")
        XCTAssertEqual(order.deliveryMode, .handToMe)
        XCTAssertNil(order.deliveryProofUrl)
    }

    func test_order_leaveAtDoorWithProof() throws {
        let json = #"""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "user_id": "22222222-2222-2222-2222-222222222222",
          "restaurant_id": "33333333-3333-3333-3333-333333333333",
          "address_id": null,
          "courier_id": null,
          "status": "delivered",
          "subtotal": 100,
          "delivery_fee": 20,
          "total": 120,
          "delivery_address_snapshot": null,
          "notes": null,
          "created_at": "2026-05-03T10:00:00Z",
          "updated_at": "2026-05-03T10:30:00Z",
          "verification_code": "1234",
          "delivery_verification_code": "5678",
          "delivery_mode": "leave_at_door",
          "delivery_proof_url": "abc-123/proof.jpg"
        }
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let order = try decoder.decode(Order.self, from: json)
        XCTAssertEqual(order.deliveryMode, .leaveAtDoor)
        XCTAssertEqual(order.deliveryProofUrl, "abc-123/proof.jpg")
    }

    func test_order_backCompat_missingNewFields() throws {
        // Old order rows (pre-Umbrella II) don't have the new fields.
        let json = #"""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "user_id": "22222222-2222-2222-2222-222222222222",
          "restaurant_id": "33333333-3333-3333-3333-333333333333",
          "address_id": null,
          "courier_id": null,
          "status": "ready",
          "subtotal": 100,
          "delivery_fee": 20,
          "total": 120,
          "delivery_address_snapshot": null,
          "notes": null,
          "created_at": "2026-05-03T10:00:00Z",
          "updated_at": "2026-05-03T10:00:00Z",
          "verification_code": "1234"
        }
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let order = try decoder.decode(Order.self, from: json)
        XCTAssertEqual(order.pickupVerificationCode, "1234")
        XCTAssertNil(order.deliveryVerificationCode)
        XCTAssertEqual(order.deliveryMode, .handToMe) // default
        XCTAssertEqual(order.reassignCount, 0)
        XCTAssertEqual(order.excludedCourierIds, [])
        XCTAssertFalse(order.noShow)
        XCTAssertEqual(order.restaurantDelayMin, 0)
    }

    func test_deprecatedAlias_stillReadsPickupCode() {
        let order = Order(
            id: UUID(), userId: UUID(), restaurantId: UUID(),
            status: .ready, subtotal: 100, deliveryFee: 20, total: 120,
            createdAt: Date(), updatedAt: Date(),
            pickupVerificationCode: "1234", deliveryVerificationCode: "5678"
        )
        // Deprecated alias used by legacy app code.
        let depr: () -> String? = { _ = order.verificationCode; return order.verificationCode }
        XCTAssertEqual(depr(), "1234")
    }
}
