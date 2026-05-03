import Foundation
import Supabase

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
        case .minOrderNotMet(let need):      return "Минимальная сумма заказа: \(Int(need)) ₽"
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

@MainActor
public final class SupabaseService {
    public static let shared = SupabaseService()

    private var client: SupabaseClient { AuthService.shared.supabaseClient }

    public init() {}

    private struct IdRow: Decodable { let id: UUID }
    private static let isoFormatter = ISO8601DateFormatter()

    // MARK: - Profile

    public func fetchProfile() async throws -> Profile {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        return try await client.from("profiles")
            .select()
            .eq("id", value: uid.uuidString)
            .single()
            .execute()
            .value
    }

    public func updateProfile(fullName: String, phone: String?) async throws {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        var updates: [String: AnyJSON] = [
            "full_name": .string(fullName),
        ]
        updates["phone"] = phone.map { .string($0) } ?? .null
        try await client.from("profiles")
            .update(updates)
            .eq("id", value: uid.uuidString)
            .execute()
    }

    // MARK: - Restaurants

    /// Consumer feed: only `active` restaurants. Server view `restaurants_orderable` exposes
    /// `is_orderable_now` so the consumer can render badges (open / out-of-hours / not-accepting)
    /// without re-computing client-side. We still fetch all `active` rows so the feed shows
    /// out-of-hours restaurants greyed-out (per UX matrix), with the schedule-for-later flow.
    public func fetchRestaurants() async throws -> [Restaurant] {
        try await client.from("restaurants")
            .select()
            .eq("restaurant_status", value: RestaurantStatus.active.rawValue)
            .order("rating", ascending: false)
            .execute()
            .value
    }

    /// Single-restaurant fetch. Returns even paused/closed/soft-deleted rows so deep-links
    /// and order history can render them — UI is responsible for showing the right state.
    public func fetchRestaurant(id: UUID) async throws -> Restaurant {
        try await client.from("restaurants")
            .select()
            .eq("id", value: id.uuidString)
            .single()
            .execute()
            .value
    }

    // MARK: - Orderability (server-truth)

    public struct RestaurantOrderability: Decodable, Sendable {
        public let isOrderableNow: Bool
        public let reason: OrderabilityReason
        public let opensAt: Date?

        enum CodingKeys: String, CodingKey {
            case isOrderableNow = "is_orderable_now"
            case reason
            case opensAt = "opens_at"
        }
    }

    /// Lightweight RPC to check orderability without re-fetching the whole restaurant.
    /// Used by consumer detail screen to render the bottom CTA state.
    public func getRestaurantOrderability(restaurantId: UUID, at: Date? = nil) async throws -> RestaurantOrderability {
        struct Params: Encodable {
            let p_restaurant_id: UUID
            let p_at: Date?
        }
        return try await client.rpc("get_restaurant_orderability", params: Params(
            p_restaurant_id: restaurantId, p_at: at
        )).execute().value
    }

    // MARK: - Menu

    /// Consumer view: only available, non-soft-deleted categories.
    public func fetchMenuCategories(restaurantId: UUID) async throws -> [MenuCategory] {
        try await client.from("menu_categories")
            .select()
            .eq("restaurant_id", value: restaurantId.uuidString)
            .eq("is_available", value: true)
            .is("deleted_at", value: nil)
            .order("sort_order")
            .execute()
            .value
    }

    /// Consumer view: only available, non-soft-deleted items.
    public func fetchMenuItems(restaurantId: UUID) async throws -> [MenuItem] {
        try await client.from("menu_items")
            .select()
            .eq("restaurant_id", value: restaurantId.uuidString)
            .eq("is_available", value: true)
            .is("deleted_at", value: nil)
            .order("sort_order")
            .execute()
            .value
    }

    // MARK: - Addresses

    public func fetchAddresses() async throws -> [Address] {
        try await client.from("addresses")
            .select()
            .order("is_default", ascending: false)
            .execute()
            .value
    }

    public func createAddress(_ address: AddressInsert) async throws -> Address {
        try await client.from("addresses")
            .insert(address)
            .select()
            .single()
            .execute()
            .value
    }

    public func deleteAddress(id: UUID) async throws {
        try await client.from("addresses")
            .delete()
            .eq("id", value: id.uuidString)
            .execute()
    }

    // MARK: - Orders

    public func fetchOrders() async throws -> [Order] {
        try await client.from("orders")
            .select("*, restaurants(*), order_items(*)")
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    public func fetchOrder(id: UUID) async throws -> Order {
        try await client.from("orders")
            .select("*, restaurants(*), order_items(*)")
            .eq("id", value: id.uuidString)
            .single()
            .execute()
            .value
    }

    public func fetchOrderStatusHistory(orderId: UUID) async throws -> [OrderStatusHistory] {
        try await client.from("order_status_history")
            .select()
            .eq("order_id", value: orderId.uuidString)
            .order("created_at")
            .execute()
            .value
    }

    // MARK: - Orders (Merchant / Courier)

    /// Fetch orders for a specific restaurant (used by Merchant app)
    public func fetchOrdersForRestaurant(restaurantId: UUID) async throws -> [Order] {
        try await client.from("orders")
            .select("*, order_items(*)")
            .eq("restaurant_id", value: restaurantId.uuidString)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    // MARK: - Create Order (via RPC)

    public struct CreateOrderParams: Encodable, Sendable {
        public let p_restaurant_id: UUID
        public let p_address_id: UUID
        public let p_items: [OrderItemParam]
        public let p_notes: String?
        public let p_scheduled_for: Date?

        public init(p_restaurant_id: UUID, p_address_id: UUID, p_items: [OrderItemParam], p_notes: String?, p_scheduled_for: Date? = nil) {
            self.p_restaurant_id = p_restaurant_id
            self.p_address_id = p_address_id
            self.p_items = p_items
            self.p_notes = p_notes
            self.p_scheduled_for = p_scheduled_for
        }
    }

    public struct OrderItemParam: Encodable, Sendable {
        public let menu_item_id: UUID
        public let quantity: Int

        public init(menu_item_id: UUID, quantity: Int) {
            self.menu_item_id = menu_item_id
            self.quantity = quantity
        }
    }

    /// Place an order. Pass `scheduledFor` (in the future, within next 7 days, within restaurant hours)
    /// to create a `scheduled` order — held by the platform until activation.
    public func createOrder(
        restaurantId: UUID,
        addressId: UUID,
        items: [(menuItemId: UUID, quantity: Int)],
        notes: String?,
        scheduledFor: Date? = nil
    ) async throws -> UUID {
        let itemsParam = items.map { item in
            OrderItemParam(menu_item_id: item.menuItemId, quantity: item.quantity)
        }
        let params = CreateOrderParams(
            p_restaurant_id: restaurantId,
            p_address_id: addressId,
            p_items: itemsParam,
            p_notes: notes,
            p_scheduled_for: scheduledFor
        )
        let result: String = try await client.rpc("create_order", params: params).execute().value
        guard let uuid = UUID(uuidString: result) else {
            throw ServiceError.invalidResponse
        }
        return uuid
    }

    // MARK: - Cart validation (pre-checkout truth gate)

    public struct ValidateCartParams: Encodable, Sendable {
        public let p_restaurant_id: UUID
        public let p_items: [OrderItemParam]
        public let p_scheduled_for: Date?
    }

    /// Server-side validation of cart contents. Called inside the consumer's
    /// confirm-tap loading screen before `createOrder`. Read-only, locks no rows,
    /// idempotent. Returns a structured payload the UI can render diffs from.
    public func validateCart(
        restaurantId: UUID,
        items: [(menuItemId: UUID, quantity: Int)],
        scheduledFor: Date? = nil
    ) async throws -> CartValidationResult {
        let params = ValidateCartParams(
            p_restaurant_id: restaurantId,
            p_items: items.map { OrderItemParam(menu_item_id: $0.menuItemId, quantity: $0.quantity) },
            p_scheduled_for: scheduledFor
        )
        return try await client.rpc("validate_cart", params: params).execute().value
    }

    // MARK: - Order Lifecycle (Merchant)

    public func acceptOrder(orderId: UUID, estimatedPrepMinutes: Int) async throws {
        let results: [IdRow] = try await client.from("orders")
            .update([
                "status": AnyJSON.string(OrderStatus.accepted.rawValue),
                "estimated_prep_time": AnyJSON.integer(estimatedPrepMinutes),
                "accepted_at": AnyJSON.string(Self.isoFormatter.string(from: Date())),
            ])
            .eq("id", value: orderId.uuidString)
            .eq("status", value: OrderStatus.created.rawValue)
            .select("id")
            .execute()
            .value
        guard !results.isEmpty else { throw ServiceError.invalidStatusTransition }
    }

    public func startPreparing(orderId: UUID) async throws {
        let results: [IdRow] = try await client.from("orders")
            .update(["status": AnyJSON.string(OrderStatus.preparing.rawValue)])
            .eq("id", value: orderId.uuidString)
            .eq("status", value: OrderStatus.accepted.rawValue)
            .select("id")
            .execute()
            .value
        guard !results.isEmpty else { throw ServiceError.invalidStatusTransition }
    }

    public func rejectOrder(orderId: UUID, reason: String) async throws {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        let results: [IdRow] = try await client.from("orders")
            .update([
                "status": AnyJSON.string(OrderStatus.rejected.rawValue),
                "cancellation_reason": AnyJSON.string(reason),
                "cancelled_by": AnyJSON.string(uid.uuidString),
                "rejected_at": AnyJSON.string(Self.isoFormatter.string(from: Date())),
            ])
            .eq("id", value: orderId.uuidString)
            .eq("status", value: OrderStatus.created.rawValue)
            .select("id")
            .execute()
            .value
        guard !results.isEmpty else { throw ServiceError.invalidStatusTransition }
    }

    public func markOrderReady(orderId: UUID) async throws {
        let results: [IdRow] = try await client.from("orders")
            .update(["status": AnyJSON.string(OrderStatus.ready.rawValue)])
            .eq("id", value: orderId.uuidString)
            .in("status", values: [OrderStatus.accepted.rawValue, OrderStatus.preparing.rawValue])
            .select("id")
            .execute()
            .value
        guard !results.isEmpty else { throw ServiceError.invalidStatusTransition }
    }

    // MARK: - Order Lifecycle (Courier)

    public func courierArrivedAtRestaurant(orderId: UUID) async throws {
        struct Params: Encodable { let p_order_id: UUID }
        try await client.rpc("courier_arrived_restaurant", params: Params(p_order_id: orderId)).execute()
    }

    public func pickUpOrder(orderId: UUID, pickupCode: String) async throws {
        struct Params: Encodable { let p_order_id: UUID; let p_verification_code: String }
        try await client.rpc("courier_pickup_order", params: Params(
            p_order_id: orderId, p_verification_code: pickupCode
        )).execute()
    }

    public func startDelivering(orderId: UUID) async throws {
        struct Params: Encodable { let p_order_id: UUID }
        try await client.rpc("courier_start_delivering", params: Params(p_order_id: orderId)).execute()
    }

    public func courierArrivedAtCustomer(orderId: UUID) async throws {
        struct Params: Encodable { let p_order_id: UUID }
        try await client.rpc("courier_arrived_at_customer", params: Params(p_order_id: orderId)).execute()
    }

    /// Mark the order as delivered.
    /// - When `deliveryMode == .handToMe`: pass `deliveryCode` (the consumer's
    ///   `delivery_verification_code`). Server matches it; mismatch → `.wrongDeliveryCode`.
    /// - When `deliveryMode == .leaveAtDoor`: pass `proofUrl` (Supabase Storage URL
    ///   to a photo in the `delivery-proofs` bucket). Missing → `.missingProofImage`.
    public func deliverOrder(
        orderId: UUID,
        deliveryCode: String? = nil,
        proofUrl: String? = nil
    ) async throws {
        struct Params: Encodable {
            let p_order_id: UUID
            let p_delivery_code: String?
            let p_delivery_proof_url: String?
        }
        try await client.rpc("courier_deliver_order", params: Params(
            p_order_id: orderId, p_delivery_code: deliveryCode, p_delivery_proof_url: proofUrl
        )).execute()
    }

    // MARK: - Order Lifecycle (Courier — cancellation + escalation)

    /// Self-cancel from a courier (pre-pickup whitelist only). Server returns the order
    /// to the available pool when the reason is restaurant-related; otherwise marks it
    /// `cancelled_by_courier` (terminal). Earnings tier credited per Workstream G.
    public func cancelOrderByCourier(orderId: UUID, reason: CancellationReason) async throws {
        guard CancellationReason.courierAllowed.contains(reason) else {
            throw ServiceError.invalidReasonCode(reason.rawValue)
        }
        struct Params: Encodable { let p_order_id: UUID; let p_reason_code: String }
        try await client.rpc("cancel_order_by_courier", params: Params(
            p_order_id: orderId, p_reason_code: reason.rawValue
        )).execute()
    }

    /// Post-pickup: courier cannot cancel, but can report a problem.
    /// Pauses SLA monitoring + posts a system message to the consumer chat.
    /// Order status is unchanged — support handles it.
    public func reportProblemPostPickup(
        orderId: UUID,
        reason: CancellationReason,
        freeForm: String? = nil
    ) async throws {
        struct Params: Encodable {
            let p_order_id: UUID
            let p_reason_code: String
            let p_free_form: String?
        }
        try await client.rpc("report_problem_post_pickup", params: Params(
            p_order_id: orderId, p_reason_code: reason.rawValue, p_free_form: freeForm
        )).execute()
    }

    /// Courier responds to a delay banner with a structured reason; server
    /// extends `expected_action_by` by 5 min and posts a chat note for the consumer.
    public func explainDelay(
        orderId: UUID,
        reason: CourierDelayReason,
        freeForm: String? = nil
    ) async throws {
        struct Params: Encodable {
            let p_order_id: UUID
            let p_reason_code: String
            let p_free_form: String?
        }
        try await client.rpc("courier_explain_delay", params: Params(
            p_order_id: orderId, p_reason_code: reason.rawValue, p_free_form: freeForm
        )).execute()
    }

    /// Customer not opening at the door — server starts a 5-min countdown after
    /// which the order is auto-marked `delivered` with `no_show=true` (Workstream I).
    public func reportCustomerNoShow(orderId: UUID) async throws {
        struct Params: Encodable { let p_order_id: UUID }
        try await client.rpc("courier_report_customer_no_show",
                             params: Params(p_order_id: orderId)).execute()
    }

    /// Courier at restaurant — restaurant is delaying. Extends SLA by N minutes,
    /// up to a cumulative cap of 30 min after which order auto-cancels with 50% earning.
    public func reportRestaurantDelay(orderId: UUID, extraMinutes: Int) async throws {
        struct Params: Encodable {
            let p_order_id: UUID
            let p_extra_minutes: Int
        }
        try await client.rpc("courier_report_restaurant_delay", params: Params(
            p_order_id: orderId, p_extra_minutes: extraMinutes
        )).execute()
    }

    /// Rate-limited heartbeat upsert (≥1 sec apart). The server applies an anti-stationary
    /// filter (only updates `last_moved_at` when the new fix is > 25m from the previous).
    /// Clients should call this from the `CourierLocationStreamer` actor.
    public func updateCourierHeartbeat(
        latitude: Double,
        longitude: Double,
        accuracyMeters: Double? = nil,
        heading: Double? = nil,
        speed: Double? = nil
    ) async throws {
        struct Params: Encodable {
            let p_latitude: Double
            let p_longitude: Double
            let p_accuracy_meters: Double?
            let p_heading: Double?
            let p_speed: Double?
        }
        try await client.rpc("update_courier_heartbeat", params: Params(
            p_latitude: latitude, p_longitude: longitude,
            p_accuracy_meters: accuracyMeters, p_heading: heading, p_speed: speed
        )).execute()
    }

    /// Read the rolling ETA + escalation-ladder hint for an order.
    /// Used by both courier (to know if delay banner is active) and consumer
    /// (to render "Курьер задерживается" + "Откроется в HH:mm" chips).
    public func fetchOrderEta(orderId: UUID) async throws -> OrderEta {
        try await client.from("orders")
            .select("id,eta_minutes,expected_action_by,courier_delay_reason_code,courier_delay_explained_at,courier_no_show_warned_at,courier_no_show_escalated_at,status")
            .eq("id", value: orderId.uuidString)
            .single()
            .execute()
            .value
    }

    /// How many self-cancels in the last 24h, and when the cooldown lifts.
    /// Used by courier UI to grey out the "Отменить заказ" button.
    public func fetchCancellationCooldownStatus() async throws -> (recentCancels: Int, cooldownUntil: Date?) {
        guard let uid = AuthService.shared.userId else { throw ServiceError.notAuthenticated }
        struct Row: Decodable { let created_at: Date }
        let rows: [Row] = try await client.from("courier_cancellation_log")
            .select("created_at")
            .eq("courier_id", value: uid.uuidString)
            .gte("created_at", value: Self.isoFormatter.string(from: Date().addingTimeInterval(-86400)))
            .order("created_at", ascending: false)
            .execute()
            .value
        let count = rows.count
        guard count >= 3, let oldest = rows.last else { return (count, nil) }
        return (count, oldest.created_at.addingTimeInterval(86400))
    }

    /// Upload a JPEG photo to the `delivery-proofs` bucket under
    /// `<order_id>/<courier_id>-<unix_ts>.jpg`. Returns the public URL.
    /// Caller is responsible for ≤ 500 KB validation (server-side check is added in v2).
    public func uploadDeliveryProof(orderId: UUID, jpegData: Data) async throws -> String {
        guard let uid = AuthService.shared.userId else { throw ServiceError.notAuthenticated }
        guard jpegData.count <= 500 * 1024 else { throw ServiceError.imageTooLarge }
        let ts = Int(Date().timeIntervalSince1970)
        let path = "\(orderId.uuidString)/\(uid.uuidString)-\(ts).jpg"
        _ = try await client.storage.from("delivery-proofs")
            .upload(path, data: jpegData, options: FileOptions(contentType: "image/jpeg", upsert: true))
        // Return the public URL (bucket is private — apps use signed URLs in v2; for now
        // the path is what we stamp on orders.delivery_proof_url).
        return path
    }

    // MARK: - Order Lifecycle (Consumer)

    public func cancelOrder(orderId: UUID, reason: String?) async throws {
        struct Params: Encodable { let p_order_id: UUID; let p_reason: String? }
        try await client.rpc("cancel_order_by_consumer", params: Params(
            p_order_id: orderId, p_reason: reason
        )).execute()
    }

    // MARK: - Order Lifecycle (Shared)

    public func assignCourier(orderId: UUID, courierId: UUID) async throws {
        let results: [IdRow] = try await client.from("orders")
            .update([
                "status": AnyJSON.string(OrderStatus.assigned.rawValue),
                "courier_id": AnyJSON.string(courierId.uuidString),
            ])
            .eq("id", value: orderId.uuidString)
            .in("status", values: [
                OrderStatus.accepted.rawValue,
                OrderStatus.preparing.rawValue,
                OrderStatus.ready.rawValue,
            ])
            .is("courier_id", value: nil)
            .select("id")
            .execute()
            .value
        guard !results.isEmpty else { throw ServiceError.orderAlreadyClaimed }
    }

    public func addTip(orderId: UUID, amount: Double) async throws {
        guard amount >= 0 else { return }
        struct Params: Encodable { let p_order_id: UUID; let p_amount: Double }
        try await client.rpc("add_tip", params: Params(
            p_order_id: orderId, p_amount: amount
        )).execute()
    }

    // MARK: - Courier Location

    public func updateCourierLocation(
        latitude: Double,
        longitude: Double,
        heading: Double?,
        speed: Double?
    ) async throws {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        let upsert = CourierLocationUpsert(
            courierId: uid,
            latitude: latitude,
            longitude: longitude,
            heading: heading,
            speed: speed,
            isOnline: true
        )
        try await client.from("courier_locations")
            .upsert(upsert, onConflict: "courier_id")
            .execute()
    }

    public func fetchCourierLocation(courierId: UUID) async throws -> CourierLocation {
        try await client.from("courier_locations")
            .select()
            .eq("courier_id", value: courierId.uuidString)
            .single()
            .execute()
            .value
    }

    public func fetchNearbyCouriers(
        latitude: Double,
        longitude: Double,
        radiusKm: Double = 5.0
    ) async throws -> [NearbyCourier] {
        struct Params: Encodable {
            let p_latitude: Double
            let p_longitude: Double
            let p_radius_km: Double
        }
        return try await client.rpc("find_nearby_couriers", params: Params(
            p_latitude: latitude,
            p_longitude: longitude,
            p_radius_km: radiusKm
        )).execute().value
    }

    // MARK: - Courier Status

    public func goOnline(latitude: Double, longitude: Double) async throws {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        let upsert = CourierLocationUpsert(
            courierId: uid,
            latitude: latitude,
            longitude: longitude,
            isOnline: true
        )
        try await client.from("courier_locations")
            .upsert(upsert, onConflict: "courier_id")
            .execute()
    }

    public func goOffline() async throws {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        try await client.from("courier_locations")
            .update(["is_online": AnyJSON.bool(false)])
            .eq("courier_id", value: uid.uuidString)
            .execute()
    }

    public func fetchCourierStatus() async throws -> CourierLocation {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        return try await client.from("courier_locations")
            .select()
            .eq("courier_id", value: uid.uuidString)
            .single()
            .execute()
            .value
    }

    // MARK: - Courier Claiming

    public func claimOrder(orderId: UUID) async throws -> UUID {
        struct Params: Encodable {
            let p_order_id: UUID
        }
        let result: String = try await client.rpc("claim_order", params: Params(
            p_order_id: orderId
        )).execute().value
        guard let uuid = UUID(uuidString: result) else {
            throw ServiceError.invalidResponse
        }
        return uuid
    }

    /// Fetch all available orders without location filter (for testing / fallback)
    public func fetchAvailableOrders() async throws -> [Order] {
        try await client.from("orders")
            .select("*, restaurants(*), order_items(*)")
            .is("courier_id", value: nil)
            .in("status", values: ["accepted", "preparing", "ready"])
            .order("created_at")
            .execute()
            .value
    }

    /// Fetch available orders within radius of courier's location
    public func fetchAvailableOrders(
        latitude: Double,
        longitude: Double,
        radiusKm: Double = 10.0
    ) async throws -> [Order] {
        struct Params: Encodable {
            let p_latitude: Double
            let p_longitude: Double
            let p_radius_km: Double
        }
        return try await client.rpc("fetch_available_orders", params: Params(
            p_latitude: latitude,
            p_longitude: longitude,
            p_radius_km: radiusKm
        )).execute().value
    }

    // MARK: - Courier Active Order

    /// Fetch the courier's current active (non-terminal) order for state restoration
    public func fetchActiveOrder(courierId: UUID) async throws -> Order? {
        let terminalStatuses = [
            OrderStatus.delivered.rawValue,
            OrderStatus.cancelled.rawValue,
            OrderStatus.cancelledByCustomer.rawValue,
            OrderStatus.cancelledByRestaurant.rawValue,
            OrderStatus.cancelledBySystem.rawValue,
            OrderStatus.rejected.rawValue,
        ]
        let orders: [Order] = try await client.from("orders")
            .select("*, restaurants(*), order_items(*)")
            .eq("courier_id", value: courierId.uuidString)
            .not("status", operator: .in, value: "(\(terminalStatuses.joined(separator: ",")))")
            .order("updated_at", ascending: false)
            .limit(1)
            .execute()
            .value
        return orders.first
    }

    /// Clear current_order_id on courier_locations so courier can receive new offers
    public func clearCurrentOrder() async throws {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        try await client.from("courier_locations")
            .update(["current_order_id": AnyJSON.null])
            .eq("courier_id", value: uid.uuidString)
            .execute()
    }

    // MARK: - Courier Earnings

    public enum EarningsPeriod: Sendable {
        case today
        case week
        case month
        case all
    }

    public func fetchEarnings(period: EarningsPeriod) async throws -> [CourierEarning] {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        var query = client.from("courier_earnings")
            .select()
            .eq("courier_id", value: uid.uuidString)

        let formatter = ISO8601DateFormatter()
        switch period {
        case .today:
            let startOfDay = Calendar.current.startOfDay(for: Date())
            query = query.gte("created_at", value: formatter.string(from: startOfDay))
        case .week:
            let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
            query = query.gte("created_at", value: formatter.string(from: weekAgo))
        case .month:
            let monthAgo = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
            query = query.gte("created_at", value: formatter.string(from: monthAgo))
        case .all:
            break
        }

        return try await query
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    public func fetchEarningsSummary(period: EarningsPeriod) async throws -> EarningsSummary {
        let earnings = try await fetchEarnings(period: period)
        return EarningsSummary(
            totalDeliveries: earnings.count,
            totalDeliveryFees: earnings.reduce(0) { $0 + $1.deliveryFee },
            totalTips: earnings.reduce(0) { $0 + $1.tipAmount },
            totalEarned: earnings.reduce(0) { $0 + $1.totalEarned }
        )
    }

    // MARK: - Restaurant Hours

    public func fetchRestaurantHours(restaurantId: UUID) async throws -> [RestaurantHours] {
        try await client.from("restaurant_hours")
            .select()
            .eq("restaurant_id", value: restaurantId.uuidString)
            .order("day_of_week")
            .execute()
            .value
    }

    public func upsertRestaurantHours(_ hours: [RestaurantHoursUpsert]) async throws {
        try await client.from("restaurant_hours")
            .upsert(hours, onConflict: "restaurant_id,day_of_week")
            .execute()
    }

    /// Removed — was client-side using device local time vs DB strings (Asia/Dushanbe-naïve)
    /// and didn't handle past-midnight ranges. Use `getRestaurantOrderability(restaurantId:at:)`
    /// which calls the server `restaurant_is_orderable()` function (timezone-correct, hours +
    /// status + accepting toggle in one call). For UI-only labels like "Откроется в 09:00",
    /// use `RestaurantHours.nextOpenAt(from:)`.

    // MARK: - Modifiers

    /// Fetch modifier groups for a specific menu item (consumer view, via junction table)
    public func fetchModifierGroups(menuItemId: UUID) async throws -> [ModifierGroup] {
        let junctions: [MenuItemModifierGroup] = try await client.from("menu_item_modifier_groups")
            .select()
            .eq("menu_item_id", value: menuItemId.uuidString)
            .execute()
            .value
        guard !junctions.isEmpty else { return [] }
        let groupIds = junctions.map { $0.modifierGroupId.uuidString }
        return try await client.from("modifier_groups")
            .select("*, modifier_options(*)")
            .in("id", values: groupIds)
            .order("sort_order")
            .execute()
            .value
    }

    /// Fetch all modifier groups for a restaurant (merchant management view)
    public func fetchAllModifierGroups(restaurantId: UUID) async throws -> [ModifierGroup] {
        try await client.from("modifier_groups")
            .select("*, modifier_options(*)")
            .eq("restaurant_id", value: restaurantId.uuidString)
            .order("sort_order")
            .execute()
            .value
    }

    // MARK: - Merchant Menu Management

    /// Fetch all menu items including unavailable AND soft-deleted ones (merchant view).
    /// Merchant UI greys out soft-deleted rows and offers a restore action within the 30-day grace.
    public func fetchAllMenuItems(restaurantId: UUID) async throws -> [MenuItem] {
        try await client.from("menu_items")
            .select()
            .eq("restaurant_id", value: restaurantId.uuidString)
            .order("sort_order")
            .execute()
            .value
    }

    /// Merchant view of categories (includes hidden + soft-deleted within grace).
    public func fetchAllMenuCategories(restaurantId: UUID) async throws -> [MenuCategory] {
        try await client.from("menu_categories")
            .select()
            .eq("restaurant_id", value: restaurantId.uuidString)
            .order("sort_order")
            .execute()
            .value
    }

    /// Show/hide a category to consumers without deleting it. Items inside an unavailable
    /// category are also hidden (consumer query filters categories first).
    public func toggleMenuCategoryAvailability(id: UUID, isAvailable: Bool) async throws {
        try await client.from("menu_categories")
            .update(["is_available": AnyJSON.bool(isAvailable)])
            .eq("id", value: id.uuidString)
            .execute()
    }

    public func toggleMenuItemAvailability(id: UUID, isAvailable: Bool) async throws {
        try await client.from("menu_items")
            .update(["is_available": AnyJSON.bool(isAvailable)])
            .eq("id", value: id.uuidString)
            .execute()
    }

    public func updateStock(menuItemId: UUID, count: Int?) async throws {
        let value: AnyJSON = count.map { AnyJSON.integer($0) } ?? .null
        try await client.from("menu_items")
            .update(["stock_count": value])
            .eq("id", value: menuItemId.uuidString)
            .execute()
    }

    public func updateMenuItem(
        id: UUID,
        name: String? = nil,
        description: String? = nil,
        price: Double? = nil,
        isAvailable: Bool? = nil,
        sortOrder: Int? = nil,
        stockCount: Int? = nil
    ) async throws {
        var updates: [String: AnyJSON] = [:]
        if let name { updates["name"] = .string(name) }
        if let description { updates["description"] = .string(description) }
        if let price { updates["price"] = .double(price) }
        if let isAvailable { updates["is_available"] = .bool(isAvailable) }
        if let sortOrder { updates["sort_order"] = .integer(sortOrder) }
        if let stockCount { updates["stock_count"] = .integer(stockCount) }
        guard !updates.isEmpty else { return }
        try await client.from("menu_items")
            .update(updates)
            .eq("id", value: id.uuidString)
            .execute()
    }

    // MARK: - Merchant Restaurant Management

    public func updateRestaurant(
        id: UUID,
        name: String? = nil,
        description: String? = nil,
        address: String? = nil,
        cuisineType: String? = nil,
        deliveryFee: Double? = nil,
        minOrderAmount: Double? = nil,
        deliveryTimeMin: Int? = nil,
        maxConcurrentOrders: Int? = nil
    ) async throws {
        var updates: [String: AnyJSON] = [:]
        if let name { updates["name"] = .string(name) }
        if let description { updates["description"] = .string(description) }
        if let address { updates["address"] = .string(address) }
        if let cuisineType { updates["cuisine_type"] = .string(cuisineType) }
        if let deliveryFee { updates["delivery_fee"] = .double(deliveryFee) }
        if let minOrderAmount { updates["min_order_amount"] = .double(minOrderAmount) }
        if let deliveryTimeMin { updates["delivery_time_min"] = .integer(deliveryTimeMin) }
        if let maxConcurrentOrders { updates["max_concurrent_orders"] = .integer(maxConcurrentOrders) }
        guard !updates.isEmpty else { return }
        try await client.from("restaurants")
            .update(updates)
            .eq("id", value: id.uuidString)
            .execute()
    }

    public func toggleAcceptingOrders(restaurantId: UUID, accepting: Bool) async throws {
        try await setAcceptingOrders(restaurantId: restaurantId, accepting: accepting, until: nil)
    }

    /// Set `is_accepting_orders` with an optional auto-resume time. When `until` is set,
    /// a `pg_cron` job flips `is_accepting_orders` back to `true` and clears `accepting_orders_until`
    /// at that time. Useful for "stop accepting until 21:00" — Tajikistan merchants will
    /// otherwise forget to re-enable.
    public func setAcceptingOrders(restaurantId: UUID, accepting: Bool, until: Date?) async throws {
        struct Params: Encodable {
            let p_restaurant_id: UUID
            let p_accepting: Bool
            let p_until: Date?
        }
        try await client.rpc("set_accepting_orders", params: Params(
            p_restaurant_id: restaurantId, p_accepting: accepting, p_until: until
        )).execute()
    }

    // MARK: - Chat Messages

    public func sendMessage(orderId: UUID, body: String) async throws -> ChatMessage {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        let insert = ChatMessageInsert(orderId: orderId, senderId: uid, body: body)
        return try await client.from("chat_messages")
            .insert(insert)
            .select()
            .single()
            .execute()
            .value
    }

    public func fetchMessages(orderId: UUID) async throws -> [ChatMessage] {
        guard AuthService.shared.userId != nil else {
            throw ServiceError.notAuthenticated
        }
        return try await client.from("chat_messages")
            .select()
            .eq("order_id", value: orderId.uuidString)
            .order("created_at")
            .execute()
            .value
    }

    public func markMessagesAsRead(orderId: UUID) async throws {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        try await client.from("chat_messages")
            .update(["read_at": AnyJSON.string(Self.isoFormatter.string(from: Date()))])
            .eq("order_id", value: orderId.uuidString)
            .neq("sender_id", value: uid.uuidString)
            .is("read_at", value: nil)
            .execute()
    }

    public func fetchUnreadCount(orderId: UUID) async throws -> Int {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        let rows: [IdRow] = try await client.from("chat_messages")
            .select("id")
            .eq("order_id", value: orderId.uuidString)
            .neq("sender_id", value: uid.uuidString)
            .is("read_at", value: nil)
            .execute()
            .value
        return rows.count
    }

    // MARK: - Merchant Restaurant CRUD

    /// Create a new restaurant for the authenticated merchant (1 per merchant enforced by DB unique index)
    public func createRestaurant(_ insert: RestaurantInsert) async throws -> Restaurant {
        guard AuthService.shared.userId != nil else {
            throw ServiceError.notAuthenticated
        }
        // Pre-check: does this merchant already have a restaurant?
        if let _ = try await fetchMyRestaurant() {
            throw ServiceError.merchantAlreadyHasRestaurant
        }
        return try await client.from("restaurants")
            .insert(insert)
            .select()
            .single()
            .execute()
            .value
    }

    /// Fetch the authenticated merchant's restaurant (nil if none yet)
    public func fetchMyRestaurant() async throws -> Restaurant? {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        let restaurants: [Restaurant] = try await client.from("restaurants")
            .select()
            .eq("owner_id", value: uid.uuidString)
            .limit(1)
            .execute()
            .value
        return restaurants.first
    }

    // MARK: - Restaurant Lifecycle

    /// Activate restaurant (draft → active). Checks onboarding completeness.
    public func activateRestaurant(id: UUID) async throws {
        let progress = try await fetchOnboardingProgress()
        guard progress.isReadyToGoLive else {
            throw ServiceError.onboardingIncomplete
        }
        let results: [IdRow] = try await client.from("restaurants")
            .update(["restaurant_status": AnyJSON.string(RestaurantStatus.active.rawValue)])
            .eq("id", value: id.uuidString)
            .eq("restaurant_status", value: RestaurantStatus.draft.rawValue)
            .select("id")
            .execute()
            .value
        guard !results.isEmpty else { throw ServiceError.invalidStatusTransition }
    }

    /// Resume restaurant (paused → active). No onboarding check needed.
    public func resumeRestaurant(id: UUID) async throws {
        let results: [IdRow] = try await client.from("restaurants")
            .update(["restaurant_status": AnyJSON.string(RestaurantStatus.active.rawValue)])
            .eq("id", value: id.uuidString)
            .eq("restaurant_status", value: RestaurantStatus.paused.rawValue)
            .select("id")
            .execute()
            .value
        guard !results.isEmpty else { throw ServiceError.invalidStatusTransition }
    }

    /// Pause restaurant (active → paused)
    public func pauseRestaurant(id: UUID) async throws {
        let results: [IdRow] = try await client.from("restaurants")
            .update(["restaurant_status": AnyJSON.string(RestaurantStatus.paused.rawValue)])
            .eq("id", value: id.uuidString)
            .eq("restaurant_status", value: RestaurantStatus.active.rawValue)
            .select("id")
            .execute()
            .value
        guard !results.isEmpty else { throw ServiceError.invalidStatusTransition }
    }

    /// Close restaurant permanently (active or paused → closed)
    public func closeRestaurant(id: UUID) async throws {
        let results: [IdRow] = try await client.from("restaurants")
            .update(["restaurant_status": AnyJSON.string(RestaurantStatus.closed.rawValue)])
            .eq("id", value: id.uuidString)
            .in("restaurant_status", values: [RestaurantStatus.active.rawValue, RestaurantStatus.paused.rawValue])
            .select("id")
            .execute()
            .value
        guard !results.isEmpty else { throw ServiceError.invalidStatusTransition }
    }

    // MARK: - Onboarding Progress

    /// Fetch onboarding progress for the merchant's restaurant
    public func fetchOnboardingProgress() async throws -> OnboardingProgress {
        guard let restaurant = try await fetchMyRestaurant() else {
            return OnboardingProgress()
        }
        let categories = try await fetchMenuCategories(restaurantId: restaurant.id)
        let liveItems: [MenuItem] = try await client.from("menu_items")
            .select()
            .eq("restaurant_id", value: restaurant.id.uuidString)
            .eq("is_available", value: true)
            .gt("price", value: 0)
            .execute()
            .value
        let hours = try await fetchRestaurantHours(restaurantId: restaurant.id)

        return OnboardingProgress(
            hasRestaurant: true,
            hasName: !restaurant.name.isEmpty,
            hasAddress: restaurant.address != nil && !restaurant.address!.isEmpty,
            hasAtLeastOneCategory: !categories.isEmpty,
            hasAtLeastOneMenuItem: !liveItems.isEmpty,
            hasHoursConfigured: !hours.isEmpty
        )
    }

    /// Preview restaurant as consumer sees it (available items only, sorted categories)
    public func fetchRestaurantPreview(restaurantId: UUID) async throws -> (Restaurant, [MenuCategory], [MenuItem]) {
        let restaurant = try await fetchRestaurant(id: restaurantId)
        let categories = try await fetchMenuCategories(restaurantId: restaurantId)
        let items = try await fetchMenuItems(restaurantId: restaurantId)
        return (restaurant, categories, items)
    }

    // MARK: - Menu Category CRUD

    public func createMenuCategory(_ insert: MenuCategoryInsert) async throws -> MenuCategory {
        try await client.from("menu_categories")
            .insert(insert)
            .select()
            .single()
            .execute()
            .value
    }

    public func updateMenuCategory(id: UUID, name: String? = nil, sortOrder: Int? = nil) async throws {
        var updates: [String: AnyJSON] = [:]
        if let name { updates["name"] = .string(name) }
        if let sortOrder { updates["sort_order"] = .integer(sortOrder) }
        guard !updates.isEmpty else { return }
        try await client.from("menu_categories")
            .update(updates)
            .eq("id", value: id.uuidString)
            .execute()
    }

    /// Soft-delete: sets `deleted_at`. Cron purges rows older than 30 days.
    /// Pre-check: category must be empty of non-deleted items.
    public func deleteMenuCategory(id: UUID) async throws {
        let items: [IdRow] = try await client.from("menu_items")
            .select("id")
            .eq("category_id", value: id.uuidString)
            .is("deleted_at", value: nil)
            .limit(1)
            .execute()
            .value
        guard items.isEmpty else { throw ServiceError.categoryNotEmpty }
        try await client.from("menu_categories")
            .update(["deleted_at": AnyJSON.string(Self.isoFormatter.string(from: Date()))])
            .eq("id", value: id.uuidString)
            .execute()
    }

    /// Restore a soft-deleted category (reverses `deleteMenuCategory` if within 30-day grace).
    public func restoreMenuCategory(id: UUID) async throws {
        try await client.from("menu_categories")
            .update(["deleted_at": AnyJSON.null])
            .eq("id", value: id.uuidString)
            .execute()
    }

    // MARK: - Menu Item CRUD

    public func createMenuItem(_ insert: MenuItemInsert) async throws -> MenuItem {
        try await client.from("menu_items")
            .insert(insert)
            .select()
            .single()
            .execute()
            .value
    }

    /// Soft-delete: sets `deleted_at`. The item disappears from consumer fetches
    /// (`fetchMenuItems` filters `deleted_at IS NULL`) but remains for order history.
    /// A daily cron hard-deletes rows where `deleted_at < now() - interval '30 days'`.
    /// Order rows are protected by `ON DELETE SET NULL` + the `OrderItem` snapshot fields.
    public func deleteMenuItem(id: UUID) async throws {
        try await client.from("menu_items")
            .update(["deleted_at": AnyJSON.string(Self.isoFormatter.string(from: Date()))])
            .eq("id", value: id.uuidString)
            .execute()
    }

    /// Restore a soft-deleted menu item (reverses `deleteMenuItem` if within 30-day grace).
    public func restoreMenuItem(id: UUID) async throws {
        try await client.from("menu_items")
            .update(["deleted_at": AnyJSON.null])
            .eq("id", value: id.uuidString)
            .execute()
    }

    // MARK: - Modifier Group CRUD

    public func createModifierGroup(_ insert: ModifierGroupInsert) async throws -> ModifierGroup {
        try await client.from("modifier_groups")
            .insert(insert)
            .select("*, modifier_options(*)")
            .single()
            .execute()
            .value
    }

    public func updateModifierGroup(
        id: UUID, name: String? = nil, isRequired: Bool? = nil,
        minSelections: Int? = nil, maxSelections: Int? = nil, sortOrder: Int? = nil
    ) async throws {
        var updates: [String: AnyJSON] = [:]
        if let name { updates["name"] = .string(name) }
        if let isRequired { updates["is_required"] = .bool(isRequired) }
        if let minSelections { updates["min_selections"] = .integer(minSelections) }
        if let maxSelections { updates["max_selections"] = .integer(maxSelections) }
        if let sortOrder { updates["sort_order"] = .integer(sortOrder) }
        guard !updates.isEmpty else { return }
        try await client.from("modifier_groups")
            .update(updates)
            .eq("id", value: id.uuidString)
            .execute()
    }

    public func deleteModifierGroup(id: UUID) async throws {
        try await client.from("modifier_groups")
            .delete()
            .eq("id", value: id.uuidString)
            .execute()
    }

    // MARK: - Modifier Option CRUD

    public func createModifierOption(_ insert: ModifierOptionInsert) async throws -> ModifierOption {
        try await client.from("modifier_options")
            .insert(insert)
            .select()
            .single()
            .execute()
            .value
    }

    public func updateModifierOption(
        id: UUID, name: String? = nil, priceAdjustment: Double? = nil,
        isAvailable: Bool? = nil, sortOrder: Int? = nil
    ) async throws {
        var updates: [String: AnyJSON] = [:]
        if let name { updates["name"] = .string(name) }
        if let priceAdjustment { updates["price_adjustment"] = .double(priceAdjustment) }
        if let isAvailable { updates["is_available"] = .bool(isAvailable) }
        if let sortOrder { updates["sort_order"] = .integer(sortOrder) }
        guard !updates.isEmpty else { return }
        try await client.from("modifier_options")
            .update(updates)
            .eq("id", value: id.uuidString)
            .execute()
    }

    public func deleteModifierOption(id: UUID) async throws {
        try await client.from("modifier_options")
            .delete()
            .eq("id", value: id.uuidString)
            .execute()
    }

    // MARK: - Modifier Group ↔ Menu Item Linking

    public func linkModifierGroup(menuItemId: UUID, modifierGroupId: UUID) async throws {
        let link = MenuItemModifierGroup(menuItemId: menuItemId, modifierGroupId: modifierGroupId)
        try await client.from("menu_item_modifier_groups")
            .insert(link)
            .execute()
    }

    public func unlinkModifierGroup(menuItemId: UUID, modifierGroupId: UUID) async throws {
        try await client.from("menu_item_modifier_groups")
            .delete()
            .eq("menu_item_id", value: menuItemId.uuidString)
            .eq("modifier_group_id", value: modifierGroupId.uuidString)
            .execute()
    }

    // MARK: - Image Upload

    private static let maxImageSize = 5 * 1024 * 1024 // 5 MB
    private static let allowedImageFormats = ["jpg", "jpeg", "png", "webp"]

    /// Upload restaurant image to Supabase Storage, returns public URL string
    public func uploadRestaurantImage(restaurantId: UUID, imageData: Data, fileExtension: String) async throws -> String {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        try validateImage(data: imageData, fileExtension: fileExtension)
        let path = "\(uid.uuidString)/\(restaurantId.uuidString).\(fileExtension)"
        try await client.storage.from("restaurant-images")
            .upload(path, data: imageData, options: .init(contentType: "image/\(fileExtension)", upsert: true))
        let publicURL = try client.storage.from("restaurant-images").getPublicURL(path: path)
        // Update restaurant image_url
        try await client.from("restaurants")
            .update(["image_url": AnyJSON.string(publicURL.absoluteString)])
            .eq("id", value: restaurantId.uuidString)
            .execute()
        return publicURL.absoluteString
    }

    /// Upload menu item image to Supabase Storage, returns public URL string
    public func uploadMenuItemImage(menuItemId: UUID, imageData: Data, fileExtension: String) async throws -> String {
        guard let uid = AuthService.shared.userId else {
            throw ServiceError.notAuthenticated
        }
        try validateImage(data: imageData, fileExtension: fileExtension)
        let path = "\(uid.uuidString)/\(menuItemId.uuidString).\(fileExtension)"
        try await client.storage.from("menu-item-images")
            .upload(path, data: imageData, options: .init(contentType: "image/\(fileExtension)", upsert: true))
        let publicURL = try client.storage.from("menu-item-images").getPublicURL(path: path)
        // Update menu item image_url
        try await client.from("menu_items")
            .update(["image_url": AnyJSON.string(publicURL.absoluteString)])
            .eq("id", value: menuItemId.uuidString)
            .execute()
        return publicURL.absoluteString
    }

    /// Delete an image from storage
    public func deleteImage(bucket: String, path: String) async throws {
        try await client.storage.from(bucket).remove(paths: [path])
    }

    private func validateImage(data: Data, fileExtension: String) throws {
        guard data.count <= Self.maxImageSize else {
            throw ServiceError.imageTooLarge
        }
        guard Self.allowedImageFormats.contains(fileExtension.lowercased()) else {
            throw ServiceError.unsupportedImageFormat
        }
    }

    // MARK: - Merchant Stats

    /// Fetch basic dashboard stats for merchant's restaurant (server-side RPC)
    public func fetchMerchantStats(restaurantId: UUID) async throws -> MerchantStats {
        struct Params: Encodable {
            let p_restaurant_id: UUID
        }
        return try await client.rpc("get_merchant_stats", params: Params(
            p_restaurant_id: restaurantId
        )).execute().value
    }
}
