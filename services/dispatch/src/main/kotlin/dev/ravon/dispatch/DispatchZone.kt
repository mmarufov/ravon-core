package dev.ravon.dispatch

/**
 * A geographic partition of the service area.
 *
 * Port of Sources/RavonCore/Dispatch/DispatchZone.swift.
 *
 * Zones exist for two independent reasons:
 *
 *  1. **Tractability** — the matching is solved per zone, so cost grows with the size of
 *     a zone rather than the size of the city.
 *  2. **Experimentation** — a switchback test randomises the algorithm over
 *     (zone × time block) cells. Without a zone concept there is no unit to randomise
 *     over that respects the shared courier pool.
 */
data class DispatchZone(val row: Int, val column: Int) {
    override fun toString(): String = "z$row-$column"
}

/**
 * Splits a bounding box into a uniform grid of zones.
 *
 * A uniform grid is deliberately naive — real zones follow population density and road
 * topology, and DoorDash derives "starting points" from data. A grid is enough to make
 * the zone *concept* real, which is what switchback randomisation needs, and it is honest
 * about what it is.
 */
class ZoneGrid(
    val center: GeoPoint,
    val radiusKm: Double,
    divisions: Int = 3,
) {
    val divisions: Int = maxOf(1, divisions)

    /**
     * Degrees of latitude per kilometre is roughly constant; longitude shrinks with
     * latitude, so it is scaled by cos(lat).
     */
    private val latSpanDegrees: Double get() = radiusKm / 111.0
    private val lonSpanDegrees: Double
        get() {
            val cosLat = Libm.cos(center.latitude * Math.PI / 180)
            return radiusKm / (111.0 * (if (StrictMath.abs(cosLat) < 1e-9) 1.0 else cosLat))
        }

    fun zone(point: GeoPoint): DispatchZone {
        // Normalise into [0, 1) across the bounding box, then bucket.
        val latFraction = (point.latitude - (center.latitude - latSpanDegrees)) / (2 * latSpanDegrees)
        val lonFraction = (point.longitude - (center.longitude - lonSpanDegrees)) / (2 * lonSpanDegrees)
        return DispatchZone(row = bucket(latFraction), column = bucket(lonFraction))
    }

    /** Clamps points outside the box into the edge zones. */
    private fun bucket(fraction: Double): Int {
        val scaled = StrictMath.floor(fraction * divisions).toInt()
        return scaled.coerceIn(0, divisions - 1)
    }

    val allZones: List<DispatchZone>
        get() = (0 until divisions).flatMap { row -> (0 until divisions).map { DispatchZone(row, it) } }
}

/**
 * Runs a dispatcher **independently per zone**: each zone's couriers are matched only to
 * that zone's orders.
 *
 * This is why DoorDash partitions the market, and the second reason is the non-obvious
 * one:
 *
 *  1. **Tractability.** The assignment problem is solved per zone, so cost scales with
 *     zone size rather than city size.
 *  2. **Experimental isolation.** A switchback test randomises the algorithm over
 *     (zone × time block) cells — but that only isolates the two arms if the algorithm
 *     also *operates* per zone. With one global courier pool a "treatment zone" and a
 *     "control zone" still draw from the same couriers, and a batch optimiser in the
 *     treatment arm only ever sees a fraction of the orders it would see in production.
 *     Randomising over zones without dispatching over zones measures neither algorithm
 *     faithfully.
 *
 * The cost is real and worth stating: couriers cannot serve an adjacent zone even when
 * they are the closest available. Zone partitioning trades global optimality for
 * tractability and measurability.
 */
class ZonedDispatcher(
    private val base: Dispatcher,
    private val grid: ZoneGrid,
) : Dispatcher {
    override val name: String = "zoned[${base.name}]"

    override fun assign(
        couriers: List<DispatchCourier>,
        orders: List<DispatchOrder>,
        nowEpochSeconds: Double,
    ): List<Assignment> {
        val couriersByZone = couriers.groupBy { grid.zone(it.location) }
        val ordersByZone = orders.groupBy { grid.zone(it.pickup) }

        // Deterministic zone order. The Swift original iterates a `Dictionary`, whose
        // order is randomised per process — which is outcome-equivalent here because
        // zones partition both couriers and orders, so no two zones can contend for the
        // same courier and the concatenation order cannot change who gets what. Sorting
        // makes the *returned sequence* reproducible too, which the simulator's
        // assignment-application loop and any future logging both benefit from.
        val result = mutableListOf<Assignment>()
        for (zone in ordersByZone.keys.sortedWith(compareBy({ it.row }, { it.column }))) {
            val zoneOrders = ordersByZone.getValue(zone)
            val zoneCouriers = couriersByZone[zone]
            if (zoneCouriers.isNullOrEmpty()) continue
            result += base.assign(zoneCouriers, zoneOrders, nowEpochSeconds)
        }
        return result
    }
}
