import Foundation

public struct CourierEarning: Codable, Identifiable, Sendable {
    public let id: UUID
    public let courierId: UUID
    public let orderId: UUID
    public let deliveryFee: Double
    public let tipAmount: Double
    public let totalEarned: Double
    public let createdAt: Date

    public init(
        id: UUID, courierId: UUID, orderId: UUID,
        deliveryFee: Double, tipAmount: Double,
        totalEarned: Double, createdAt: Date
    ) {
        self.id = id
        self.courierId = courierId
        self.orderId = orderId
        self.deliveryFee = deliveryFee
        self.tipAmount = tipAmount
        self.totalEarned = totalEarned
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case courierId = "courier_id"
        case orderId = "order_id"
        case deliveryFee = "delivery_fee"
        case tipAmount = "tip_amount"
        case totalEarned = "total_earned"
        case createdAt = "created_at"
    }
}

public struct EarningsSummary: Sendable {
    public let totalDeliveries: Int
    public let totalDeliveryFees: Double
    public let totalTips: Double
    public let totalEarned: Double

    public init(totalDeliveries: Int, totalDeliveryFees: Double,
                totalTips: Double, totalEarned: Double) {
        self.totalDeliveries = totalDeliveries
        self.totalDeliveryFees = totalDeliveryFees
        self.totalTips = totalTips
        self.totalEarned = totalEarned
    }
}
