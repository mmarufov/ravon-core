import Foundation

/// Typed cancellation reasons. Mirror of the SQL CHECK constraint on
/// `orders.cancellation_reason_code`.
///
/// The DB-level whitelist is the source of truth — adding a reason here without
/// the matching migration will fail at insert time.
public enum CancellationReason: String, Codable, CaseIterable, Sendable {
    // Consumer-initiated
    case consumerChangedMind            = "CONSUMER_CHANGED_MIND"
    case consumerDuplicate              = "CONSUMER_DUPLICATE"

    // Restaurant-initiated
    case restaurantClosed               = "RESTAURANT_CLOSED"
    case restaurantOutOfItems           = "RESTAURANT_OUT_OF_ITEMS"
    case restaurantRejected             = "RESTAURANT_REJECTED"
    case restaurantTooLongWait          = "RESTAURANT_TOO_LONG_WAIT"

    // Courier-initiated (whitelist for cancel_order_by_courier)
    case courierVehicleIssue            = "COURIER_VEHICLE_ISSUE"
    case courierSafetyIssue             = "COURIER_SAFETY_ISSUE"
    case courierRestaurantClosed        = "COURIER_RESTAURANT_CLOSED"
    case courierItemsUnavailable        = "COURIER_ITEMS_UNAVAILABLE"
    case courierNonResponsive           = "COURIER_NON_RESPONSIVE"

    // System-initiated
    case systemTimeout                  = "SYSTEM_TIMEOUT"
    case systemFraudSuspected           = "SYSTEM_FRAUD_SUSPECTED"

    // Pre-existing scheduled-order cancellation reasons (Umbrella I)
    case restaurantNotOpenAtScheduledTime = "RESTAURANT_NOT_OPEN_AT_SCHEDULED_TIME"
    case itemUnavailable                = "ITEM_UNAVAILABLE"
    case insufficientStock              = "INSUFFICIENT_STOCK"
    case itemDeleted                    = "ITEM_DELETED"

    // Customer no-show (Workstream I)
    case customerNoShow                 = "CUSTOMER_NO_SHOW"

    /// Reasons the consumer is allowed to send via `cancelOrder()`.
    public static var consumerAllowed: Set<CancellationReason> {
        [.consumerChangedMind, .consumerDuplicate]
    }

    /// Reasons a courier is allowed to send via `cancelOrderByCourier()`.
    /// Note: `restaurantTooLongWait` is included because we re-pool the order
    /// when the wait blows past the 30-min cap (Workstream I).
    public static var courierAllowed: Set<CancellationReason> {
        [
            .courierVehicleIssue, .courierSafetyIssue,
            .courierRestaurantClosed, .courierItemsUnavailable,
            .restaurantTooLongWait,
        ]
    }

    public var localizedDisplayName: String {
        switch self {
        case .consumerChangedMind:               return "Передумал"
        case .consumerDuplicate:                 return "Повторный заказ"
        case .restaurantClosed:                  return "Ресторан закрыт"
        case .restaurantOutOfItems:              return "Не хватает позиций"
        case .restaurantRejected:                return "Ресторан отклонил заказ"
        case .restaurantTooLongWait:             return "Слишком долгое ожидание"
        case .courierVehicleIssue:               return "Проблема с транспортом"
        case .courierSafetyIssue:                return "Вопрос безопасности"
        case .courierRestaurantClosed:           return "Ресторан закрыт (курьер на месте)"
        case .courierItemsUnavailable:           return "Позиций нет в наличии"
        case .courierNonResponsive:              return "Курьер не отвечает"
        case .systemTimeout:                     return "Истекло время ожидания"
        case .systemFraudSuspected:              return "Подозрение на мошенничество"
        case .restaurantNotOpenAtScheduledTime:  return "Ресторан закрыт в это время"
        case .itemUnavailable:                   return "Позиция недоступна"
        case .insufficientStock:                 return "Недостаточно товара"
        case .itemDeleted:                       return "Позиция удалена"
        case .customerNoShow:                    return "Клиент не вышел"
        }
    }
}

/// Reasons a courier picks from when responding to a delay banner.
/// Used by `courier_explain_delay`.
public enum CourierDelayReason: String, Codable, CaseIterable, Sendable {
    case traffic
    case restaurantSlow      = "restaurant_slow"
    case addressUnclear      = "address_unclear"
    case customerUnreachable = "customer_unreachable"
    case other

    public var localizedDisplayName: String {
        switch self {
        case .traffic:             return "Пробки"
        case .restaurantSlow:      return "Ресторан задерживает"
        case .addressUnclear:      return "Не могу найти адрес"
        case .customerUnreachable: return "Клиент не отвечает"
        case .other:               return "Другое"
        }
    }
}
