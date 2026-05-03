import Foundation

public enum OrderStatus: String, Codable, CaseIterable, Sendable {
    case scheduled
    case created
    case accepted
    case preparing
    case ready
    case assigned
    case courierArrivedRestaurant = "courier_arrived_restaurant"
    case pickedUp = "picked_up"
    case delivering
    case courierArrivedCustomer = "courier_arrived_customer"
    case delivered
    case cancelled
    case rejected
    case cancelledByCustomer   = "cancelled_by_customer"
    case cancelledByRestaurant = "cancelled_by_restaurant"
    case cancelledBySystem     = "cancelled_by_system"
    case cancelledByCourier    = "cancelled_by_courier"

    public var displayName: String {
        switch self {
        case .scheduled:                return "Запланирован"
        case .created:                  return "Создан"
        case .accepted:                 return "Принят"
        case .preparing:                return "Готовится"
        case .ready:                    return "Готов"
        case .assigned:                 return "Назначен курьер"
        case .courierArrivedRestaurant: return "Курьер у ресторана"
        case .pickedUp:                 return "Забран курьером"
        case .delivering:               return "В пути"
        case .courierArrivedCustomer:   return "Курьер у клиента"
        case .delivered:                return "Доставлен"
        case .cancelled:                return "Отменён"
        case .rejected:                 return "Отклонён"
        case .cancelledByCustomer:      return "Отменён клиентом"
        case .cancelledByRestaurant:    return "Отменён рестораном"
        case .cancelledBySystem:        return "Отменён системой"
        case .cancelledByCourier:       return "Отменён курьером"
        }
    }

    public var isActive: Bool { !isTerminal }

    public var isTerminal: Bool {
        switch self {
        case .delivered, .cancelled, .rejected,
             .cancelledByCustomer, .cancelledByRestaurant, .cancelledBySystem,
             .cancelledByCourier:
            return true
        default:
            return false
        }
    }

    public var isCancelled: Bool {
        switch self {
        case .cancelled, .cancelledByCustomer, .cancelledByRestaurant,
             .cancelledBySystem, .cancelledByCourier:
            return true
        default:
            return false
        }
    }

    /// Active hand-off statuses where consumer ↔ courier chat is INSERT-able.
    /// (5-minute grace post-`delivered` is enforced by RLS at the DB layer.)
    public var isChatActive: Bool {
        switch self {
        case .assigned, .courierArrivedRestaurant, .pickedUp,
             .delivering, .courierArrivedCustomer:
            return true
        default:
            return false
        }
    }

    /// Statuses where the consumer can still cancel before the food is in motion.
    public var consumerCanCancel: Bool {
        switch self {
        case .scheduled, .created, .accepted, .preparing, .ready,
             .assigned, .courierArrivedRestaurant:
            return true
        default:
            return false
        }
    }

    /// Statuses where the courier can self-cancel via the whitelist (Workstream B).
    public var courierCanCancel: Bool {
        self == .assigned || self == .courierArrivedRestaurant
    }

    public var isScheduled: Bool { self == .scheduled }

    public var stepIndex: Int {
        switch self {
        case .scheduled:                return -2
        case .created:                  return 0
        case .accepted:                 return 1
        case .preparing:                return 2
        case .ready:                    return 3
        case .assigned:                 return 4
        case .courierArrivedRestaurant: return 5
        case .pickedUp:                 return 6
        case .delivering:               return 7
        case .courierArrivedCustomer:   return 8
        case .delivered:                return 9
        case .cancelled, .cancelledByCustomer,
             .cancelledByRestaurant, .cancelledBySystem,
             .cancelledByCourier:
            return -1
        case .rejected:                 return -1
        }
    }
}

public struct Order: Codable, Identifiable, Sendable {
    public let id: UUID
    public let userId: UUID
    public let restaurantId: UUID
    public let addressId: UUID?
    public let courierId: UUID?
    public let status: OrderStatus
    public let subtotal: Double
    public let deliveryFee: Double
    public let total: Double
    public let deliveryAddressSnapshot: AddressSnapshot?
    public let notes: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let restaurant: Restaurant?
    public let orderItems: [OrderItem]?
    public let estimatedDeliveryTime: Date?
    public let estimatedPrepTime: Int?
    public let cancellationReason: String?
    public let cancellationReasonCode: String?
    public let cancelledBy: UUID?

    /// Pickup verification code — shown to merchant + courier at the restaurant counter.
    /// (Renamed from `verificationCode`. CodingKey unchanged: `verification_code`.)
    public let pickupVerificationCode: String?

    /// Delivery verification code — shown to consumer in tracking screen,
    /// entered by courier in `courier_deliver_order` when delivery_mode == .handToMe.
    public let deliveryVerificationCode: String?

    public let tipAmount: Double?
    public let pickedUpAt: Date?
    public let deliveredAt: Date?
    public let acceptedAt: Date?
    public let rejectedAt: Date?
    public let scheduledFor: Date?

    /// Workstream A — SLA + ladder state.
    public let claimedAt: Date?
    public let arrivedAtRestaurantAt: Date?
    public let arrivedAtCustomerAt: Date?
    public let expectedActionBy: Date?
    public let etaMinutes: Int?
    public let courierDelayReasonCode: String?
    public let courierDelayExplainedAt: Date?
    public let courierNoShowWarnedAt: Date?
    public let courierNoShowEscalatedAt: Date?

    /// Workstream E — reassignment state.
    public let reassignCount: Int
    public let excludedCourierIds: [UUID]

    /// Workstream J — delivery mode + photo proof.
    public let deliveryMode: DeliveryMode
    public let deliveryProofUrl: String?

    /// Workstream I — customer no-show.
    public let noShow: Bool
    public let noShowStartedAt: Date?
    public let restaurantDelayMin: Int

    /// Backwards-compatibility alias for the renamed pickup code.
    /// Marked deprecated; existing app callers can migrate to `pickupVerificationCode`.
    @available(*, deprecated, renamed: "pickupVerificationCode")
    public var verificationCode: String? { pickupVerificationCode }

    public init(
        id: UUID, userId: UUID, restaurantId: UUID,
        addressId: UUID? = nil, courierId: UUID? = nil,
        status: OrderStatus, subtotal: Double, deliveryFee: Double, total: Double,
        deliveryAddressSnapshot: AddressSnapshot? = nil, notes: String? = nil,
        createdAt: Date, updatedAt: Date,
        restaurant: Restaurant? = nil, orderItems: [OrderItem]? = nil,
        estimatedDeliveryTime: Date? = nil, estimatedPrepTime: Int? = nil,
        cancellationReason: String? = nil,
        cancellationReasonCode: String? = nil,
        cancelledBy: UUID? = nil,
        pickupVerificationCode: String? = nil,
        deliveryVerificationCode: String? = nil,
        tipAmount: Double? = nil,
        pickedUpAt: Date? = nil, deliveredAt: Date? = nil,
        acceptedAt: Date? = nil, rejectedAt: Date? = nil,
        scheduledFor: Date? = nil,
        claimedAt: Date? = nil,
        arrivedAtRestaurantAt: Date? = nil,
        arrivedAtCustomerAt: Date? = nil,
        expectedActionBy: Date? = nil,
        etaMinutes: Int? = nil,
        courierDelayReasonCode: String? = nil,
        courierDelayExplainedAt: Date? = nil,
        courierNoShowWarnedAt: Date? = nil,
        courierNoShowEscalatedAt: Date? = nil,
        reassignCount: Int = 0,
        excludedCourierIds: [UUID] = [],
        deliveryMode: DeliveryMode = .handToMe,
        deliveryProofUrl: String? = nil,
        noShow: Bool = false,
        noShowStartedAt: Date? = nil,
        restaurantDelayMin: Int = 0
    ) {
        self.id = id
        self.userId = userId
        self.restaurantId = restaurantId
        self.addressId = addressId
        self.courierId = courierId
        self.status = status
        self.subtotal = subtotal
        self.deliveryFee = deliveryFee
        self.total = total
        self.deliveryAddressSnapshot = deliveryAddressSnapshot
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.restaurant = restaurant
        self.orderItems = orderItems
        self.estimatedDeliveryTime = estimatedDeliveryTime
        self.estimatedPrepTime = estimatedPrepTime
        self.cancellationReason = cancellationReason
        self.cancellationReasonCode = cancellationReasonCode
        self.cancelledBy = cancelledBy
        self.pickupVerificationCode = pickupVerificationCode
        self.deliveryVerificationCode = deliveryVerificationCode
        self.tipAmount = tipAmount
        self.pickedUpAt = pickedUpAt
        self.deliveredAt = deliveredAt
        self.acceptedAt = acceptedAt
        self.rejectedAt = rejectedAt
        self.scheduledFor = scheduledFor
        self.claimedAt = claimedAt
        self.arrivedAtRestaurantAt = arrivedAtRestaurantAt
        self.arrivedAtCustomerAt = arrivedAtCustomerAt
        self.expectedActionBy = expectedActionBy
        self.etaMinutes = etaMinutes
        self.courierDelayReasonCode = courierDelayReasonCode
        self.courierDelayExplainedAt = courierDelayExplainedAt
        self.courierNoShowWarnedAt = courierNoShowWarnedAt
        self.courierNoShowEscalatedAt = courierNoShowEscalatedAt
        self.reassignCount = reassignCount
        self.excludedCourierIds = excludedCourierIds
        self.deliveryMode = deliveryMode
        self.deliveryProofUrl = deliveryProofUrl
        self.noShow = noShow
        self.noShowStartedAt = noShowStartedAt
        self.restaurantDelayMin = restaurantDelayMin
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.userId = try c.decode(UUID.self, forKey: .userId)
        self.restaurantId = try c.decode(UUID.self, forKey: .restaurantId)
        self.addressId = try c.decodeIfPresent(UUID.self, forKey: .addressId)
        self.courierId = try c.decodeIfPresent(UUID.self, forKey: .courierId)
        self.status = try c.decode(OrderStatus.self, forKey: .status)
        self.subtotal = try c.decode(Double.self, forKey: .subtotal)
        self.deliveryFee = try c.decode(Double.self, forKey: .deliveryFee)
        self.total = try c.decode(Double.self, forKey: .total)
        self.deliveryAddressSnapshot = try c.decodeIfPresent(AddressSnapshot.self, forKey: .deliveryAddressSnapshot)
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.restaurant = try c.decodeIfPresent(Restaurant.self, forKey: .restaurant)
        self.orderItems = try c.decodeIfPresent([OrderItem].self, forKey: .orderItems)
        self.estimatedDeliveryTime = try c.decodeIfPresent(Date.self, forKey: .estimatedDeliveryTime)
        self.estimatedPrepTime = try c.decodeIfPresent(Int.self, forKey: .estimatedPrepTime)
        self.cancellationReason = try c.decodeIfPresent(String.self, forKey: .cancellationReason)
        self.cancellationReasonCode = try c.decodeIfPresent(String.self, forKey: .cancellationReasonCode)
        self.cancelledBy = try c.decodeIfPresent(UUID.self, forKey: .cancelledBy)
        self.pickupVerificationCode = try c.decodeIfPresent(String.self, forKey: .pickupVerificationCode)
        self.deliveryVerificationCode = try c.decodeIfPresent(String.self, forKey: .deliveryVerificationCode)
        self.tipAmount = try c.decodeIfPresent(Double.self, forKey: .tipAmount)
        self.pickedUpAt = try c.decodeIfPresent(Date.self, forKey: .pickedUpAt)
        self.deliveredAt = try c.decodeIfPresent(Date.self, forKey: .deliveredAt)
        self.acceptedAt = try c.decodeIfPresent(Date.self, forKey: .acceptedAt)
        self.rejectedAt = try c.decodeIfPresent(Date.self, forKey: .rejectedAt)
        self.scheduledFor = try c.decodeIfPresent(Date.self, forKey: .scheduledFor)
        self.claimedAt = try c.decodeIfPresent(Date.self, forKey: .claimedAt)
        self.arrivedAtRestaurantAt = try c.decodeIfPresent(Date.self, forKey: .arrivedAtRestaurantAt)
        self.arrivedAtCustomerAt = try c.decodeIfPresent(Date.self, forKey: .arrivedAtCustomerAt)
        self.expectedActionBy = try c.decodeIfPresent(Date.self, forKey: .expectedActionBy)
        self.etaMinutes = try c.decodeIfPresent(Int.self, forKey: .etaMinutes)
        self.courierDelayReasonCode = try c.decodeIfPresent(String.self, forKey: .courierDelayReasonCode)
        self.courierDelayExplainedAt = try c.decodeIfPresent(Date.self, forKey: .courierDelayExplainedAt)
        self.courierNoShowWarnedAt = try c.decodeIfPresent(Date.self, forKey: .courierNoShowWarnedAt)
        self.courierNoShowEscalatedAt = try c.decodeIfPresent(Date.self, forKey: .courierNoShowEscalatedAt)
        self.reassignCount = try c.decodeIfPresent(Int.self, forKey: .reassignCount) ?? 0
        self.excludedCourierIds = try c.decodeIfPresent([UUID].self, forKey: .excludedCourierIds) ?? []
        self.deliveryMode = try c.decodeIfPresent(DeliveryMode.self, forKey: .deliveryMode) ?? .handToMe
        self.deliveryProofUrl = try c.decodeIfPresent(String.self, forKey: .deliveryProofUrl)
        self.noShow = try c.decodeIfPresent(Bool.self, forKey: .noShow) ?? false
        self.noShowStartedAt = try c.decodeIfPresent(Date.self, forKey: .noShowStartedAt)
        self.restaurantDelayMin = try c.decodeIfPresent(Int.self, forKey: .restaurantDelayMin) ?? 0
    }

    /// Live computed: server SLA breached AND courier hasn't explained.
    public var delayWarningActive: Bool {
        guard let due = expectedActionBy else { return false }
        if courierDelayExplainedAt != nil { return false }
        return due < Date()
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case restaurantId = "restaurant_id"
        case addressId = "address_id"
        case courierId = "courier_id"
        case status, subtotal
        case deliveryFee = "delivery_fee"
        case total
        case deliveryAddressSnapshot = "delivery_address_snapshot"
        case notes
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case restaurant = "restaurants"
        case orderItems = "order_items"
        case estimatedDeliveryTime = "estimated_delivery_time"
        case estimatedPrepTime = "estimated_prep_time"
        case cancellationReason = "cancellation_reason"
        case cancellationReasonCode = "cancellation_reason_code"
        case cancelledBy = "cancelled_by"
        // Note: column `verification_code` IS the pickup code; we map to the new Swift name.
        case pickupVerificationCode = "verification_code"
        case deliveryVerificationCode = "delivery_verification_code"
        case tipAmount = "tip_amount"
        case pickedUpAt = "picked_up_at"
        case deliveredAt = "delivered_at"
        case acceptedAt = "accepted_at"
        case rejectedAt = "rejected_at"
        case scheduledFor = "scheduled_for"
        case claimedAt = "claimed_at"
        case arrivedAtRestaurantAt = "arrived_at_restaurant_at"
        case arrivedAtCustomerAt = "arrived_at_customer_at"
        case expectedActionBy = "expected_action_by"
        case etaMinutes = "eta_minutes"
        case courierDelayReasonCode = "courier_delay_reason_code"
        case courierDelayExplainedAt = "courier_delay_explained_at"
        case courierNoShowWarnedAt = "courier_no_show_warned_at"
        case courierNoShowEscalatedAt = "courier_no_show_escalated_at"
        case reassignCount = "reassign_count"
        case excludedCourierIds = "excluded_courier_ids"
        case deliveryMode = "delivery_mode"
        case deliveryProofUrl = "delivery_proof_url"
        case noShow = "no_show"
        case noShowStartedAt = "no_show_started_at"
        case restaurantDelayMin = "restaurant_delay_min"
    }
}

public struct OrderItemModifierSnapshot: Codable, Hashable, Sendable {
    public let groupName: String
    public let optionName: String
    public let priceAdjustment: Double

    public init(groupName: String, optionName: String, priceAdjustment: Double) {
        self.groupName = groupName
        self.optionName = optionName
        self.priceAdjustment = priceAdjustment
    }

    enum CodingKeys: String, CodingKey {
        case groupName = "group_name"
        case optionName = "option_name"
        case priceAdjustment = "price_adjustment"
    }
}

public struct OrderItem: Codable, Identifiable, Sendable {
    public let id: UUID
    public let orderId: UUID
    /// FK to menu_items. NULLABLE — set NULL when the item is hard-deleted (post 30-day soft-delete grace).
    /// UI must use the snapshot fields below, not look up the live row.
    public let menuItemId: UUID?
    public let quantity: Int
    public let unitPrice: Double
    public let totalPrice: Double
    public let itemName: String
    public let itemDescription: String?
    public let itemImageUrl: String?
    public let modifiersSnapshot: [OrderItemModifierSnapshot]

    public init(
        id: UUID, orderId: UUID, menuItemId: UUID?, quantity: Int,
        unitPrice: Double, totalPrice: Double, itemName: String,
        itemDescription: String? = nil, itemImageUrl: String? = nil,
        modifiersSnapshot: [OrderItemModifierSnapshot] = []
    ) {
        self.id = id
        self.orderId = orderId
        self.menuItemId = menuItemId
        self.quantity = quantity
        self.unitPrice = unitPrice
        self.totalPrice = totalPrice
        self.itemName = itemName
        self.itemDescription = itemDescription
        self.itemImageUrl = itemImageUrl
        self.modifiersSnapshot = modifiersSnapshot
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.orderId = try c.decode(UUID.self, forKey: .orderId)
        self.menuItemId = try c.decodeIfPresent(UUID.self, forKey: .menuItemId)
        self.quantity = try c.decode(Int.self, forKey: .quantity)
        self.unitPrice = try c.decode(Double.self, forKey: .unitPrice)
        self.totalPrice = try c.decode(Double.self, forKey: .totalPrice)
        self.itemName = try c.decode(String.self, forKey: .itemName)
        self.itemDescription = try c.decodeIfPresent(String.self, forKey: .itemDescription)
        self.itemImageUrl = try c.decodeIfPresent(String.self, forKey: .itemImageUrl)
        self.modifiersSnapshot = try c.decodeIfPresent([OrderItemModifierSnapshot].self, forKey: .modifiersSnapshot) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case id
        case orderId = "order_id"
        case menuItemId = "menu_item_id"
        case quantity
        case unitPrice = "unit_price"
        case totalPrice = "total_price"
        case itemName = "item_name"
        case itemDescription = "item_description"
        case itemImageUrl = "item_image_url"
        case modifiersSnapshot = "modifiers_snapshot"
    }
}

public struct OrderStatusHistory: Codable, Identifiable, Sendable {
    public let id: UUID
    public let orderId: UUID
    public let status: OrderStatus
    public let changedBy: UUID?
    public let notes: String?
    public let createdAt: Date

    public init(id: UUID, orderId: UUID, status: OrderStatus, changedBy: UUID? = nil, notes: String? = nil, createdAt: Date) {
        self.id = id
        self.orderId = orderId
        self.status = status
        self.changedBy = changedBy
        self.notes = notes
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case orderId = "order_id"
        case status
        case changedBy = "changed_by"
        case notes
        case createdAt = "created_at"
    }
}
