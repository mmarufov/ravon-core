import Foundation

/// A geographic partition of the service area.
///
/// DoorDash partitions the market into zones for two independent reasons, and Ravon
/// needs zones for the same two:
///
/// 1. **Tractability** — the assignment MIP (or matching) is solved per zone, so cost
///    grows with the size of a zone rather than the size of the city.
/// 2. **Experimentation** — switchback tests randomise the algorithm over
///    (zone × time block) cells. Without a zone concept there is no unit to randomise
///    over that respects the shared courier pool.
public struct DispatchZone: Sendable, Hashable, Codable, CustomStringConvertible {
    public let row: Int
    public let column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    public var description: String { "z\(row)-\(column)" }
}

/// Splits a bounding box into a uniform grid of zones.
///
/// A uniform grid is deliberately naive — real zones follow population density and road
/// topology, and DoorDash derives "starting points" from data. A grid is enough to make
/// the zone *concept* real, which is what switchback randomisation needs, and it is
/// honest about what it is.
public struct ZoneGrid: Sendable {
    public let center: GeoPoint
    public let radiusKm: Double
    public let divisions: Int

    public init(center: GeoPoint, radiusKm: Double, divisions: Int = 3) {
        self.center = center
        self.radiusKm = radiusKm
        self.divisions = max(1, divisions)
    }

    /// Degrees of latitude per kilometre is roughly constant; longitude shrinks with
    /// latitude, so it is scaled by cos(lat).
    private var latSpanDegrees: Double { radiusKm / 111.0 }
    private var lonSpanDegrees: Double {
        let cosLat = cos(center.latitude * .pi / 180)
        return radiusKm / (111.0 * (abs(cosLat) < 1e-9 ? 1 : cosLat))
    }

    public func zone(for point: GeoPoint) -> DispatchZone {
        // Normalise into [0, 1) across the bounding box, then bucket.
        let latFraction = (point.latitude - (center.latitude - latSpanDegrees))
            / (2 * latSpanDegrees)
        let lonFraction = (point.longitude - (center.longitude - lonSpanDegrees))
            / (2 * lonSpanDegrees)

        func bucket(_ fraction: Double) -> Int {
            let scaled = Int((fraction * Double(divisions)).rounded(.down))
            return min(max(scaled, 0), divisions - 1)   // clamp points outside the box
        }
        return DispatchZone(row: bucket(latFraction), column: bucket(lonFraction))
    }

    public var allZones: [DispatchZone] {
        (0..<divisions).flatMap { row in
            (0..<divisions).map { DispatchZone(row: row, column: $0) }
        }
    }
}

/// Runs a dispatcher **independently per zone**: each zone's couriers are matched only to
/// that zone's orders.
///
/// This is why DoorDash partitions the market. Two reasons, and the second one is
/// non-obvious and was discovered here empirically:
///
/// 1. **Tractability.** The assignment problem is solved per zone, so cost scales with
///    zone size rather than city size.
/// 2. **Experimental isolation.** A switchback test randomises the algorithm over
///    (zone × time block) cells — but that only isolates the two arms if the algorithm
///    also *operates* per zone. With one global courier pool, a "treatment zone" and a
///    "control zone" still draw from the same couriers, and a batch optimiser in the
///    treatment arm only ever sees a fraction of the orders it would see in production.
///    Randomising over zones without dispatching over zones measures neither algorithm
///    faithfully.
///
/// The cost is real and worth stating: couriers cannot serve an adjacent zone even when
/// they are the closest available. Zone partitioning trades global optimality for
/// tractability and measurability.
public struct ZonedDispatcher: Dispatcher {
    public let name: String
    public let base: any Dispatcher
    public let grid: ZoneGrid

    public init(base: any Dispatcher, grid: ZoneGrid) {
        self.base = base
        self.grid = grid
        self.name = "zoned[\(base.name)]"
    }

    public func assign(
        couriers: [DispatchCourier], orders: [DispatchOrder], now: Date
    ) -> [Assignment] {
        let couriersByZone = Dictionary(grouping: couriers) { grid.zone(for: $0.location) }
        let ordersByZone = Dictionary(grouping: orders) { grid.zone(for: $0.pickup) }

        var result: [Assignment] = []
        for (zone, zoneOrders) in ordersByZone {
            guard let zoneCouriers = couriersByZone[zone], !zoneCouriers.isEmpty else { continue }
            result.append(
                contentsOf: base.assign(couriers: zoneCouriers, orders: zoneOrders, now: now)
            )
        }
        return result
    }
}
