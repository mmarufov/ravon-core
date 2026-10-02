import Foundation

public enum ServiceError: LocalizedError, Sendable {
    case notAuthenticated
    case invalidResponse
    case orderNotFound
    case invalidStatusTransition
    case unauthorized
    case invalidVerificationCode
    case orderAlreadyClaimed
    case restaurantClosed
    case restaurantNotAccepting
    case restaurantOverloaded
    case restaurantOutOfHours
    case insufficientStock
    case cancelNotAllowed
    case merchantAlreadyHasRestaurant
    case onboardingIncomplete
    case imageTooLarge
    case unsupportedImageFormat
    case categoryNotEmpty
    case minOrderNotMet(need: Double)
    case scheduledTimeInvalid
    case cartHasIssues(CartValidationResult)
    // Umbrella II — courier hardening
    case cancelAfterPickupNotAllowed
    case cannotCancelPostPickup
    case orderNoLongerPickupable
    case courierBusy
    case courierMustBeOnline
    case courierSuspended(until: Date?)
    case courierExcluded
    case courierCancelCooldown(recentCancels: Int)
    case wrongDeliveryCode
    case missingProofImage
    case invalidReasonCode(String)
    case accuracyTooLow(meters: Double)

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:              return "Пользователь не авторизован"
        case .invalidResponse:               return "Ошибка ответа сервера"
        case .orderNotFound:                 return "Заказ не найден"
        case .invalidStatusTransition:       return "Недопустимый переход статуса"
        case .unauthorized:                  return "Недостаточно прав"
        case .invalidVerificationCode:       return "Неверный код подтверждения"
        case .orderAlreadyClaimed:           return "Заказ уже занят другим курьером"
        case .restaurantClosed:              return "Ресторан сейчас закрыт"
        case .restaurantNotAccepting:        return "Ресторан не принимает заказы"
        case .restaurantOverloaded:          return "Ресторан перегружен заказами"
        case .restaurantOutOfHours:          return "Ресторан сейчас не работает по расписанию"
        case .insufficientStock:             return "Недостаточно товара на складе"
        case .cancelNotAllowed:              return "Отмена невозможна — заказ уже забран курьером"
        case .merchantAlreadyHasRestaurant:  return "У вас уже есть ресторан"
        case .onboardingIncomplete:          return "Заполните все данные перед открытием"
        case .imageTooLarge:                 return "Изображение слишком большое (макс. 5 МБ)"
        case .unsupportedImageFormat:        return "Неподдерживаемый формат изображения"
        case .categoryNotEmpty:              return "Удалите все блюда из категории перед удалением"
        case .minOrderNotMet(let need):      return "Минимальная сумма заказа: \(Int(need)) сомони"
        case .scheduledTimeInvalid:          return "Выбранное время недоступно"
        case .cartHasIssues(let r):
            let msg = r.reason.localizedMessage
            return msg.isEmpty ? "В корзине есть изменения" : msg
        case .cancelAfterPickupNotAllowed:   return "Заказ уже в пути — отмена недоступна, обратитесь в поддержку"
        case .cannotCancelPostPickup:        return "Доставка началась. Используйте «Сообщить о проблеме»"
        case .orderNoLongerPickupable:       return "Заказ больше недоступен"
        case .courierBusy:                   return "У вас уже есть активная доставка"
        case .courierMustBeOnline:           return "Включите статус «На линии» перед взятием заказа"
        case .courierSuspended(let until):
            if let u = until {
                let f = DateFormatter()
                f.dateFormat = "HH:mm"
                return "Аккаунт временно приостановлен до \(f.string(from: u))"
            }
            return "Аккаунт временно приостановлен"
        case .courierExcluded:               return "Этот заказ для вас недоступен"
        case .courierCancelCooldown(let n):  return "Слишком много отмен (\(n) за 24ч). Возьмите паузу."
        case .wrongDeliveryCode:             return "Неверный код от клиента"
        case .missingProofImage:             return "Сделайте фото у двери для подтверждения"
        case .invalidReasonCode(let c):      return "Неподдерживаемая причина: \(c)"
        case .accuracyTooLow(_):             return "Слабый сигнал GPS — обновите местоположение"
        }
    }

    /// Best-effort decoder: maps a Supabase/PostgREST error to a typed
    /// `ServiceError` by inspecting the structured DETAIL emitted by our
    /// SECURITY DEFINER RPCs (`USING DETAIL = jsonb_build_object('reason', X)`).
    /// Returns nil when nothing matches.
    public static func from(serverError error: Error) -> ServiceError? {
        // The Supabase Swift SDK exposes the message and a JSON-string `detail`
        // on PostgrestError. Normalise common JSON escapes so a single regex
        // works whether the detail comes through pretty-printed, escaped, or
        // wrapped in NSError's description format.
        let raw = String(describing: error)
        let normalized = raw.replacingOccurrences(of: "\\\"", with: "\"")
        // Search for "reason":"<KIND>" — kind is uppercase letters + underscores.
        let pattern = #""reason"\s*:\s*"([A-Z_]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
              match.numberOfRanges >= 2,
              let captureRange = Range(match.range(at: 1), in: normalized) else {
            return nil
        }
        let kind = String(normalized[captureRange])
        switch kind {
        case "CANCEL_AFTER_PICKUP_NOT_ALLOWED":     return .cancelAfterPickupNotAllowed
        case "CANNOT_CANCEL_POST_PICKUP":           return .cannotCancelPostPickup
        case "ORDER_NO_LONGER_PICKUPABLE":          return .orderNoLongerPickupable
        case "COURIER_ALREADY_HAS_ACTIVE_ORDER":    return .courierBusy
        case "COURIER_MUST_BE_ONLINE":              return .courierMustBeOnline
        case "COURIER_SUSPENDED":                   return .courierSuspended(until: nil)
        case "COURIER_EXCLUDED_FROM_ORDER":         return .courierExcluded
        case "COURIER_CANCEL_COOLDOWN":             return .courierCancelCooldown(recentCancels: 3)
        case "WRONG_DELIVERY_CODE":                 return .wrongDeliveryCode
        case "MISSING_PROOF_IMAGE":                 return .missingProofImage
        case "INVALID_REASON_CODE":                 return .invalidReasonCode("")
        case "ACCURACY_TOO_LOW":                    return .accuracyTooLow(meters: 0)
        case "INVALID_VERIFICATION_CODE":           return .invalidVerificationCode
        case "ORDER_NOT_FOUND":                     return .orderNotFound
        case "ORDER_ALREADY_TERMINAL":              return .invalidStatusTransition
        case "INVALID_STATUS_TRANSITION":           return .invalidStatusTransition
        case "UNAUTHORIZED":                        return .unauthorized
        case "NOT_AUTHENTICATED":                   return .notAuthenticated
        default:                                    return nil
        }
    }
}
