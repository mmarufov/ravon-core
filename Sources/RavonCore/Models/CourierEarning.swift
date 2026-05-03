import Foundation

/// Type of earning credit. Mirrors `courier_earnings.earning_type` CHECK.
public enum CourierEarningType: String, Codable, Sendable, CaseIterable {
    case full
    case partialAssigned        = "partial_assigned"
    case partialAtRestaurant    = "partial_at_restaurant"
    case partialPickedUpLost    = "partial_picked_up_lost"
    case noShowCompensation     = "no_show_compensation"
    case manualAdjustment       = "manual_adjustment"
    case clawback

    public var localizedDisplayName: String {
        switch self {
        case .full:                  return "Полная оплата"
        case .partialAssigned:       return "Частично — назначен"
        case .partialAtRestaurant:   return "Частично — у ресторана"
        case .partialPickedUpLost:   return "Заказ не доставлен (полная оплата)"
        case .noShowCompensation:    return "Клиент не вышел"
        case .manualAdjustment:      return "Корректировка вручную"
        case .clawback:              return "Удержание (нарушение)"
        }
    }
}

public struct CourierEarning: Codable, Identifiable, Sendable {
    public let id: UUID
    public let courierId: UUID
    public let orderId: UUID
    public let deliveryFee: Double
    public let tipAmount: Double
    public let totalEarned: Double
    public let earningType: CourierEarningType
    public let tierPct: Int
    public let cancellationReasonCode: String?
    public let statusAtEvent: OrderStatus?
    public let createdAt: Date

    public init(
        id: UUID, courierId: UUID, orderId: UUID,
        deliveryFee: Double, tipAmount: Double,
        totalEarned: Double,
        earningType: CourierEarningType = .full,
        tierPct: Int = 100,
        cancellationReasonCode: String? = nil,
        statusAtEvent: OrderStatus? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.courierId = courierId
        self.orderId = orderId
        self.deliveryFee = deliveryFee
        self.tipAmount = tipAmount
        self.totalEarned = totalEarned
        self.earningType = earningType
        self.tierPct = tierPct
        self.cancellationReasonCode = cancellationReasonCode
        self.statusAtEvent = statusAtEvent
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.courierId = try c.decode(UUID.self, forKey: .courierId)
        self.orderId = try c.decode(UUID.self, forKey: .orderId)
        self.deliveryFee = try c.decode(Double.self, forKey: .deliveryFee)
        self.tipAmount = try c.decode(Double.self, forKey: .tipAmount)
        self.totalEarned = try c.decode(Double.self, forKey: .totalEarned)
        self.earningType = try c.decodeIfPresent(CourierEarningType.self, forKey: .earningType) ?? .full
        self.tierPct = try c.decodeIfPresent(Int.self, forKey: .tierPct) ?? 100
        self.cancellationReasonCode = try c.decodeIfPresent(String.self, forKey: .cancellationReasonCode)
        self.statusAtEvent = try c.decodeIfPresent(OrderStatus.self, forKey: .statusAtEvent)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    public var isClawback: Bool { earningType == .clawback || tierPct < 0 }

    enum CodingKeys: String, CodingKey {
        case id
        case courierId = "courier_id"
        case orderId = "order_id"
        case deliveryFee = "delivery_fee"
        case tipAmount = "tip_amount"
        case totalEarned = "total_earned"
        case earningType = "earning_type"
        case tierPct = "tier_pct"
        case cancellationReasonCode = "cancellation_reason_code"
        case statusAtEvent = "status_at_event"
        case createdAt = "created_at"
    }
}

public struct EarningsSummary: Sendable {
    public let totalDeliveries: Int
    public let totalDeliveryFees: Double
    public let totalTips: Double
    public let totalEarned: Double
    public let totalClawbacks: Double

    public init(totalDeliveries: Int, totalDeliveryFees: Double,
                totalTips: Double, totalEarned: Double,
                totalClawbacks: Double = 0) {
        self.totalDeliveries = totalDeliveries
        self.totalDeliveryFees = totalDeliveryFees
        self.totalTips = totalTips
        self.totalEarned = totalEarned
        self.totalClawbacks = totalClawbacks
    }
}
