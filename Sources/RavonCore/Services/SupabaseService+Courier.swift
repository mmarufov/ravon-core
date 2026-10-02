import Foundation
import Supabase

extension SupabaseService {
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
}
