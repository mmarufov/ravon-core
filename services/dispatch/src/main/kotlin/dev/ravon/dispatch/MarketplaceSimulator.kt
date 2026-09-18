package dev.ravon.dispatch

import java.util.UUID

/**
 * Deterministic discrete-event marketplace simulator.
 *
 * Port of Sources/RavonCore/Dispatch/MarketplaceSimulator.swift. Verified against
 * `Tests/RavonCoreTests/Fixtures/dispatch-baseline.json` — 30 seeds × 2 dispatchers ×
 * 11 metrics, recorded from the Swift original before this port existed.
 *
 * Three things are load-bearing for that verification and must not be "tidied":
 *
 *  1. **Draw order.** One [SwiftRandom] drives the whole run, so every draw must happen
 *     in the same order or the streams desynchronise. The order is: restaurant locations,
 *     per-restaurant prep bias, then per courier (location, speed), then per order
 *     (restaurant index, createdAt, quoted prep, prep noise, dropoff).
 *  2. **`gaussian` short-circuits when `sigma <= 0` and consumes *zero* draws.** The
 *     default latent profile is [LatentVariability.NONE], where every sigma is zero, so
 *     in the baseline configuration none of the three gaussian call sites advances the
 *     generator at all. Implementing it as "always draw two" desynchronises everything
 *     after the first restaurant.
 *  3. **`now` accumulates.** `now += step` in a loop, not `i * step`. The accumulated
 *     floating-point error is part of the recorded result.
 */
object MarketplaceSimulator {

    /**
     * Hidden state the world runs on but no model is allowed to see.
     *
     * Without this the simulator is a closed formula: delivery time would be computed
     * from distance, speed and prep time, all of which would also be model inputs, so
     * any "prediction" would re-derive the generating equation and score R² ≈ 1.
     */
    data class LatentVariability(
        val restaurantPrepBiasSigmaMinutes: Double,
        val prepNoiseSigmaMinutes: Double,
        val courierSpeedSpread: Double,
        val trafficAmplitude: Double,
        val trafficPeriodMinutes: Double = 90.0,
    ) {
        companion object {
            /**
             * Fully determined world. Correct for dispatch-algorithm comparisons, where
             * latent noise only adds variance to a paired test, and **wrong** for any
             * prediction task, where it makes the problem trivial.
             */
            val NONE = LatentVariability(0.0, 0.0, 0.0, 0.0)

            /** Default for prediction work. */
            val REALISTIC = LatentVariability(
                restaurantPrepBiasSigmaMinutes = 4.0,
                prepNoiseSigmaMinutes = 3.0,
                courierSpeedSpread = 0.30,
                trafficAmplitude = 0.35,
            )
        }
    }

    data class Config(
        val seed: ULong = 42UL,
        val courierCount: Int = 12,
        val orderCount: Int = 240,
        val durationMinutes: Double = 180.0,
        /**
         * How often dispatch runs — the batching window. Longer windows give the matcher
         * more to work with but make every order wait longer before it is considered.
         */
        val dispatchIntervalSeconds: Double = 30.0,
        val cityCenter: GeoPoint = GeoPoint(38.5598, 68.7870),
        val cityRadiusKm: Double = 6.0,
        val prepMinutesRange: ClosedRange<Double> = 8.0..25.0,
        val latent: LatentVariability = LatentVariability.NONE,
    )

    data class Result(
        val dispatcherName: String,
        val ordersOffered: Int,
        val ordersAssigned: Int,
        val ordersNeverAssigned: Int,
        val meanWaitToAssignMinutes: Double,
        val p95WaitToAssignMinutes: Double,
        val meanDeliveryMinutes: Double,
        val totalCourierTravelKm: Double,
        val jobsPerCourier: List<Int>,
        val giniCoefficient: Double,
        val couriersWithNoWork: Int,
        /**
         * Per-order outcome, in the simulator's createdAt-sorted order.
         *
         * The experiment harness needs this because aggregate numbers cannot answer
         * "what happened to the treated orders specifically", and the `ml/` layer trains
         * on it.
         */
        val orderRecords: List<OrderRecord> = emptyList(),
    ) {
        val assignmentRate: Double
            get() = if (ordersOffered == 0) 0.0 else ordersAssigned.toDouble() / ordersOffered
    }

    /**
     * Per-order outcome and the features a model is legitimately allowed to see.
     *
     * The split matters: `restaurantIndex` is an opaque id a model may learn
     * per-restaurant effects from, while `latentTrafficMultiplier` and
     * `latentCourierSpeedFactor` are the hidden parameters that generated the outcome —
     * recorded for *validation only*, so calibration can be checked against the true
     * conditional distribution. A model that reads them is cheating.
     */
    data class OrderRecord(
        val id: UUID,
        val pickup: GeoPoint,
        val createdAtMinutes: Double,
        val assignedAtMinutes: Double?,
        val deliveredAtMinutes: Double?,
        val restaurantIndex: Int,
        val haulKm: Double,
        val quotedPrepMinutes: Double,
        val freeCouriersAtCreation: Int,
        val pendingOrdersAtCreation: Int,
        val latentTrafficMultiplier: Double?,
        val latentCourierSpeedFactor: Double?,
    ) {
        val hourOfDay: Double get() = (createdAtMinutes / 60) % 24
        val waitToAssignMinutes: Double? get() = assignedAtMinutes?.let { it - createdAtMinutes }
        val totalDeliveryMinutes: Double? get() = deliveredAtMinutes?.let { it - createdAtMinutes }
    }

    private class SimCourier(
        val id: UUID,
        var location: GeoPoint,
        var idleSince: Double,
        var busyUntil: Double,
        val speedFactor: Double,
        val excluded: Set<UUID> = emptySet(),
        var jobsCompleted: Int = 0,
        var travelKm: Double = 0.0,
    )

    private class SimOrder(
        val id: UUID,
        val restaurantIndex: Int,
        val pickup: GeoPoint,
        val dropoff: GeoPoint,
        val createdAt: Double,
        val quotedReadyAt: Double,
        val trueReadyAt: Double,
        var assignedAt: Double? = null,
        var deliveredAt: Double? = null,
        var latentTraffic: Double? = null,
        var latentCourierSpeed: Double? = null,
        var freeCouriersAtCreation: Int = 0,
        var pendingOrdersAtCreation: Int = 0,
    )

    /**
     * Uniform point within [radiusKm] of [center]. Square-root on the radius keeps the
     * distribution area-uniform instead of clustering everything at the centre.
     *
     * Draws **radial first, then bearing**.
     */
    private fun randomPoint(center: GeoPoint, radiusKm: Double, rng: SwiftRandom): GeoPoint {
        val distance = radiusKm * Libm.sqrt(rng.nextDoubleClosed(0.0, 1.0))
        val bearing = rng.nextDoubleHalfOpen(0.0, 2 * Math.PI)
        val deltaLat = distance / 111.0
        val cosLat = Libm.cos(center.latitude * Math.PI / 180)
        val deltaLon = distance / (111.0 * (if (cosLat == 0.0) 1.0 else cosLat))
        return GeoPoint(
            latitude = center.latitude + deltaLat * Libm.sin(bearing),
            longitude = center.longitude + deltaLon * Libm.cos(bearing),
        )
    }

    /**
     * Box-Muller, so latent parameters are Gaussian rather than uniform.
     *
     * Consumes exactly two draws when `sigma > 0` and **zero** otherwise. Discards the
     * second Box-Muller output rather than caching it.
     */
    private fun gaussian(mean: Double, sigma: Double, rng: SwiftRandom): Double {
        if (sigma <= 0) return mean
        val u1 = maxOf(rng.nextDoubleClosed(0.0, 1.0), 1e-12)
        val u2 = rng.nextDoubleClosed(0.0, 1.0)
        return mean + sigma * Libm.sqrt(-2 * Libm.log(u1)) *
            Libm.cos(2 * Math.PI * u2)
    }

    /** City-wide traffic at a given minute. `> 1` means slower than nominal. */
    private fun trafficMultiplier(minute: Double, latent: LatentVariability): Double {
        if (latent.trafficAmplitude <= 0) return 1.0
        val phase = 2 * Math.PI * minute / latent.trafficPeriodMinutes
        return 1 + latent.trafficAmplitude * (1 - Libm.cos(phase)) / 2
    }

    /**
     * Deterministic identity.
     *
     * The Swift original calls `UUID()`, which draws from the system generator rather
     * than the seeded one — so identity there is random but never affects a metric, since
     * ids are only used for lookup. Deriving them from the index instead makes the whole
     * run reproducible without changing any result.
     */
    private fun stableId(kind: Long, index: Int): UUID = UUID(kind, index.toLong())

    fun run(config: Config, dispatcher: Dispatcher): Result {
        val rng = SwiftRandom(config.seed)

        // Restaurants cluster (a city has commercial districts); dropoffs spread out.
        val restaurantCount = maxOf(3, config.courierCount / 2)
        val restaurants = (0 until restaurantCount).map {
            randomPoint(config.cityCenter, config.cityRadiusKm * 0.5, rng)
        }

        // Latent per-restaurant kitchen bias: some kitchens run persistently slow.
        val restaurantPrepBias = (0 until restaurantCount).map {
            gaussian(0.0, config.latent.restaurantPrepBiasSigmaMinutes, rng)
        }

        val couriers = (0 until config.courierCount).map { i ->
            SimCourier(
                id = stableId(COURIER_KIND, i),
                location = randomPoint(config.cityCenter, config.cityRadiusKm, rng),
                idleSince = 0.0,
                busyUntil = 0.0,
                speedFactor = maxOf(0.3, gaussian(1.0, config.latent.courierSpeedSpread, rng)),
            )
        }

        val orders = (0 until config.orderCount).map { i ->
            val restaurantIndex = rng.nextIntHalfOpen(restaurantCount)
            val createdAt = rng.nextDoubleClosed(0.0, config.durationMinutes)
            // The merchant quotes a prep time; the kitchen's real behaviour is the quote
            // plus a persistent per-restaurant bias plus per-order noise. Only the quote
            // is observable.
            val quotedPrep = rng.nextDoubleClosed(
                config.prepMinutesRange.start, config.prepMinutesRange.endInclusive
            )
            val truePrep = maxOf(
                1.0,
                quotedPrep + restaurantPrepBias[restaurantIndex] +
                    gaussian(0.0, config.latent.prepNoiseSigmaMinutes, rng),
            )
            SimOrder(
                id = stableId(ORDER_KIND, i),
                restaurantIndex = restaurantIndex,
                pickup = restaurants[restaurantIndex],
                dropoff = randomPoint(config.cityCenter, config.cityRadiusKm, rng),
                createdAt = createdAt,
                quotedReadyAt = createdAt + quotedPrep,
                trueReadyAt = createdAt + truePrep,
            )
        }.sortedWith(compareBy({ it.createdAt }, { it.id }))

        val costModel = DispatchCostModel()
        val step = config.dispatchIntervalSeconds / 60
        // Run past the arrival window so late orders still get a chance to be served.
        val horizon = config.durationMinutes + 90

        var now = 0.0
        while (now <= horizon) {
            val pendingIndices = orders.indices.filter {
                orders[it].assignedAt == null && orders[it].createdAt <= now
            }
            val freeIndices = couriers.indices.filter { couriers[it].busyUntil <= now }

            if (pendingIndices.isNotEmpty() && freeIndices.isNotEmpty()) {
                // The dispatcher is handed absolute instants, exactly as the Swift
                // original hands it `Date`s built from this epoch. The round-trip through
                // ~1.7e9 is not incidental — it is what the recorded baseline was measured
                // with, and computing in minutes instead changes the matching.
                val nowEpochSeconds = EPOCH_SECONDS + now * 60
                val dispatchCouriers = freeIndices.map { index ->
                    val c = couriers[index]
                    DispatchCourier(
                        id = c.id,
                        location = c.location,
                        idleSinceEpochSeconds = EPOCH_SECONDS + c.idleSince * 60,
                        excludedOrderIds = c.excluded,
                    )
                }
                val dispatchOrders = pendingIndices.map { index ->
                    val o = orders[index]
                    DispatchOrder(
                        id = o.id,
                        pickup = o.pickup,
                        dropoff = o.dropoff,
                        readyAtEpochSeconds = EPOCH_SECONDS + o.quotedReadyAt * 60,
                        createdAtEpochSeconds = EPOCH_SECONDS + o.createdAt * 60,
                    )
                }

                for (assignment in dispatcher.assign(dispatchCouriers, dispatchOrders, nowEpochSeconds)) {
                    val ci = couriers.indexOfFirst { it.id == assignment.courierId }
                    val oi = orders.indexOfFirst { it.id == assignment.orderId }
                    if (ci < 0 || oi < 0) continue
                    if (orders[oi].assignedAt != null) continue
                    if (couriers[ci].busyUntil > now) continue

                    val order = orders[oi]
                    val toPickupKm = couriers[ci].location.distanceKm(order.pickup)
                    val legKm = order.pickup.distanceKm(order.dropoff)

                    // Latent: the courier's own speed and the current traffic. The
                    // dispatcher planned with nominal speed and had access to neither.
                    val traffic = trafficMultiplier(now, config.latent)
                    val speed = couriers[ci].speedFactor
                    fun actualMinutes(km: Double) = costModel.travelMinutes(km) * traffic / speed

                    val arriveAt = now + actualMinutes(toPickupKm)
                    // The courier waits on the kitchen's *true* readiness, not the quote.
                    val departAt = maxOf(arriveAt, order.trueReadyAt)
                    val deliverAt = departAt + actualMinutes(legKm)

                    orders[oi].assignedAt = now
                    orders[oi].deliveredAt = deliverAt
                    orders[oi].latentTraffic = traffic
                    orders[oi].latentCourierSpeed = speed
                    orders[oi].freeCouriersAtCreation = freeIndices.size
                    orders[oi].pendingOrdersAtCreation = pendingIndices.size
                    couriers[ci].location = order.dropoff
                    couriers[ci].busyUntil = deliverAt
                    couriers[ci].idleSince = deliverAt
                    couriers[ci].jobsCompleted += 1
                    couriers[ci].travelKm += toPickupKm + legKm
                }
            }
            now += step
        }

        val assigned = orders.filter { it.assignedAt != null }
        val waits = assigned.map { it.assignedAt!! - it.createdAt }
        val deliveries = assigned.mapNotNull { o -> o.deliveredAt?.let { it - o.createdAt } }
        val jobs = couriers.map { it.jobsCompleted }

        return Result(
            dispatcherName = dispatcher.name,
            ordersOffered = orders.size,
            ordersAssigned = assigned.size,
            ordersNeverAssigned = orders.size - assigned.size,
            meanWaitToAssignMinutes = mean(waits),
            p95WaitToAssignMinutes = percentile(waits, 0.95),
            meanDeliveryMinutes = mean(deliveries),
            totalCourierTravelKm = couriers.fold(0.0) { acc, c -> acc + c.travelKm },
            jobsPerCourier = jobs,
            giniCoefficient = gini(jobs),
            couriersWithNoWork = jobs.count { it == 0 },
            orderRecords = orders.map { o ->
                OrderRecord(
                    id = o.id,
                    pickup = o.pickup,
                    createdAtMinutes = o.createdAt,
                    assignedAtMinutes = o.assignedAt,
                    deliveredAtMinutes = o.deliveredAt,
                    restaurantIndex = o.restaurantIndex,
                    haulKm = o.pickup.distanceKm(o.dropoff),
                    quotedPrepMinutes = o.quotedReadyAt - o.createdAt,
                    freeCouriersAtCreation = o.freeCouriersAtCreation,
                    pendingOrdersAtCreation = o.pendingOrdersAtCreation,
                    latentTrafficMultiplier = o.latentTraffic,
                    latentCourierSpeedFactor = o.latentCourierSpeed,
                )
            },
        )
    }

    /** Left-fold sum then divide, matching the original's `reduce(0, +) / count`. */
    private fun mean(xs: List<Double>): Double =
        if (xs.isEmpty()) 0.0 else xs.fold(0.0) { a, b -> a + b } / xs.size

    private fun percentile(xs: List<Double>, p: Double): Double {
        if (xs.isEmpty()) return 0.0
        val sorted = xs.sorted()
        // Swift's `.rounded()` is `.toNearestOrAwayFromZero`. Expressed directly rather
        // than as `floor(x + 0.5)`: the two agree for non-negative arguments, which this
        // always is, but writing the weaker rule invites someone to reuse the helper
        // somewhere it does not hold.
        val rank = roundTiesAwayFromZero((sorted.size - 1).toDouble() * p).toInt()
        return sorted[rank.coerceIn(0, sorted.size - 1)]
    }

    /** Swift's `Double.rounded()` default rule: nearest, ties away from zero. */
    private fun roundTiesAwayFromZero(x: Double): Double =
        if (x < 0) -StrictMath.floor(-x + 0.5) else StrictMath.floor(x + 0.5)

    /**
     * Gini over completed jobs. Mean delivery time can look excellent while a third of
     * the fleet earns nothing, so fairness needs its own number.
     */
    private fun gini(counts: List<Int>): Double {
        if (counts.size <= 1) return 0.0
        val values = counts.map { it.toDouble() }.sorted()
        val total = values.fold(0.0) { a, b -> a + b }
        if (total <= 0) return 0.0
        val n = values.size.toDouble()
        var weighted = 0.0
        values.forEachIndexed { offset, element ->
            weighted += (2 * (offset + 1).toDouble() - n - 1) * element
        }
        return weighted / (n * total)
    }

    /**
     * The simulation epoch, expressed the way Swift's `Date` actually stores it.
     *
     * The original writes `Date(timeIntervalSince1970: 1_700_000_000)`, but `Date` holds
     * `timeIntervalSinceReferenceDate` — seconds since **2001-01-01**, not 1970. So the
     * value the arithmetic is performed on is `1_700_000_000 - 978_307_200 =
     * 721_692_800`, and every `addingTimeInterval` / `timeIntervalSince` happens at that
     * magnitude.
     *
     * This is not a cosmetic difference. A double has ~2.4e-7 s of resolution at 1.7e9
     * and ~1.2e-7 s at 7.2e8, so using the Unix value produced costs that were wrong in
     * the 9th decimal — enough to flip a greedy tie and lose one assignment on seed 1.
     * The recorded baseline pins the correct one.
     */
    internal const val EPOCH_SECONDS = 721_692_800.0

    /**
     * The same instant as [EPOCH_SECONDS], expressed as seconds since 1970.
     *
     * `ExperimentDispatcher` alternates arm priority on
     * `Int(now.timeIntervalSince1970 / 60) % 2`, which reads the *Unix* view of the same
     * `Date`. Both constants are needed because Swift's `Date` exposes both and the
     * original uses each in a different place.
     */
    internal const val EPOCH_UNIX_SECONDS = EPOCH_SECONDS + 978_307_200.0

    private const val COURIER_KIND = 0x0000_0000_C0DE_0001L
    private const val ORDER_KIND = 0x0000_0000_0DDE_0001L
}
