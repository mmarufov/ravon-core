import Foundation

#if canImport(CoreLocation)
import CoreLocation
#endif

/// Streams the courier's GPS heartbeat to the server at a status-aware cadence.
///
/// The cadence policy (Workstream D) trades battery for tracking precision:
///
/// | Status                                    | Interval | Move filter |
/// |-------------------------------------------|---------:|------------:|
/// | online, no order                          |    30 s  |   skip < 50m|
/// | assigned (en route to restaurant)         |    10 s  |   skip < 25m|
/// | courier_arrived_restaurant                |    30 s  |        none |
/// | picked_up + delivering                    |     5 s  |   skip < 15m|
/// | courier_arrived_customer                  |    10 s  |        none |
///
/// The actor keeps a lightweight in-memory schedule and pushes heartbeats via
/// `SupabaseService.updateCourierHeartbeat`. The server enforces the rate
/// limit (≥1s) and accuracy gate (≤200m). The server also computes
/// `last_moved_at` based on geog drift.
///
/// Apps own the actual location source (`CLLocationManager` on iOS).
/// They feed each new fix to `submit(latitude:longitude:...)`. The streamer
/// applies the cadence + movement filter and forwards to the server.
@MainActor
public final class CourierLocationStreamer {
    public static let shared = CourierLocationStreamer()

    /// Last successfully sent point (after server filter applied locally).
    private var lastSentAt: Date?
    private var lastSentLatitude: Double?
    private var lastSentLongitude: Double?
    private var currentStatus: OrderStatus?

    public init() {}

    /// Update the active order status. Apps call this from the courier-side
    /// "active order" subscription so the streamer can pick the right interval.
    public func setActiveOrderStatus(_ status: OrderStatus?) {
        self.currentStatus = status
    }

    /// Submit a new GPS fix. Called by the app's `CLLocationManagerDelegate`.
    /// Applies the cadence + movement filter; on green, calls
    /// `SupabaseService.updateCourierHeartbeat(...)`.
    public func submit(
        latitude: Double,
        longitude: Double,
        accuracyMeters: Double? = nil,
        heading: Double? = nil,
        speed: Double? = nil
    ) async {
        let interval = cadence(for: currentStatus)
        let movement = movementFilterMeters(for: currentStatus)
        let now = Date()

        if let last = lastSentAt, now.timeIntervalSince(last) < interval { return }
        if let m = movement,
           let lastLat = lastSentLatitude, let lastLng = lastSentLongitude,
           haversine(lat1: lastLat, lng1: lastLng, lat2: latitude, lng2: longitude) < m {
            // Below movement threshold — skip but keep timestamp so we don't
            // flood the server when standing still.
            lastSentAt = now
            return
        }
        if let acc = accuracyMeters, acc > 200 { return } // server would reject

        do {
            try await SupabaseService.shared.updateCourierHeartbeat(
                latitude: latitude, longitude: longitude,
                accuracyMeters: accuracyMeters, heading: heading, speed: speed
            )
            lastSentAt = now
            lastSentLatitude = latitude
            lastSentLongitude = longitude
        } catch {
            // Log + drop. Next fix will retry.
        }
    }

    /// Reset (call when courier goes offline / stops streaming).
    public func reset() {
        lastSentAt = nil
        lastSentLatitude = nil
        lastSentLongitude = nil
        currentStatus = nil
    }

    // MARK: - Cadence policy

    /// Visible to tests so cadence isn't a black box.
    public func cadence(for status: OrderStatus?) -> TimeInterval {
        switch status {
        case .pickedUp, .delivering:                return 5
        case .assigned:                             return 10
        case .courierArrivedCustomer:               return 10
        case .courierArrivedRestaurant:             return 30
        case .none:                                 return 30   // online, no order
        default:                                    return 30
        }
    }

    /// Visible to tests.
    public func movementFilterMeters(for status: OrderStatus?) -> Double? {
        switch status {
        case .pickedUp, .delivering:                return 15
        case .assigned:                             return 25
        case .none:                                 return 50
        default:                                    return nil
        }
    }

    // MARK: - Haversine (no PostGIS on the client)

    private func haversine(lat1: Double, lng1: Double, lat2: Double, lng2: Double) -> Double {
        let R = 6_371_000.0
        let φ1 = lat1 * .pi / 180
        let φ2 = lat2 * .pi / 180
        let Δφ = (lat2 - lat1) * .pi / 180
        let Δλ = (lng2 - lng1) * .pi / 180
        let a = sin(Δφ/2) * sin(Δφ/2) + cos(φ1) * cos(φ2) * sin(Δλ/2) * sin(Δλ/2)
        let c = 2 * atan2(sqrt(a), sqrt(1-a))
        return R * c
    }
}
