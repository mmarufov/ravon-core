package dev.ravon.dispatch

import java.util.UUID

/** A courier available for assignment. */
data class DispatchCourier(
    val id: UUID,
    val location: GeoPoint,
    /**
     * When this courier last finished a delivery (or came online), as **seconds since
     * the Unix epoch** — i.e. exactly what Swift's `Date.timeIntervalSince1970` holds.
     *
     * Carrying an absolute instant rather than minutes-since-simulation-start looks like
     * pointless indirection and is not. The Swift original hands the cost model `Date`s,
     * so every elapsed time is computed as a difference of two ~1.7e9 doubles and then
     * divided by 60. At that magnitude a double has only ~1e-7 s of residual precision,
     * so `(epoch + a*60) - (epoch + b*60)` is **not** bitwise equal to `(a - b) * 60`.
     * Computing in minutes directly diverges from the recorded baseline within the first
     * seed — measured: 108 orders assigned instead of 110.
     */
    val idleSinceEpochSeconds: Double,
    /** Orders this courier has already declined or been excluded from. */
    val excludedOrderIds: Set<UUID> = emptySet(),
)

/** An order waiting for a courier. */
data class DispatchOrder(
    val id: UUID,
    val pickup: GeoPoint,
    val dropoff: GeoPoint,
    /** When the kitchen expects the food to be ready. A courier arriving earlier waits. */
    val readyAtEpochSeconds: Double,
    val createdAtEpochSeconds: Double,
    val excludedCourierIds: Set<UUID> = emptySet(),
)

data class Assignment(val courierId: UUID, val orderId: UUID, val cost: Double)

/**
 * How the cost of a (courier, order) pair is scored. All costs are **minutes**.
 *
 * Port of `DispatchCostModel` in Sources/RavonCore/Dispatch/Dispatcher.swift, defaults
 * included.
 *
 * The design decision worth defending, carried over verbatim from the original: the
 * objective is **not** "minimise total travel distance." Pure distance minimisation
 * produces two pathologies in a real marketplace — couriers on the edge of town never
 * get work, and an old order keeps losing to newer ones that happen to have a closer
 * courier. So the cost carries explicit fairness and urgency credits that trade a little
 * efficiency for bounded waiting, and the simulator exists to measure that trade instead
 * of guessing at it.
 */
data class DispatchCostModel(
    /** Average courier speed. Dushanbe traffic on a scooter, not a highway. */
    val averageSpeedKmh: Double = 18.0,
    /**
     * Beyond this, a pair is forbidden rather than merely expensive.
     *
     * 8 km is the project's single radius as of 2026-09-17. Three conflicting values
     * existed — 8 km here, 10 km in the Swift PostgREST wrapper, 50 km in the SQL
     * default — and this one was chosen both on merit and because the recorded baseline
     * was measured at it.
     */
    val maxAssignmentRadiusKm: Double = 8.0,
    /** Minutes of cost forgiven per minute an order has been waiting. */
    val orderAgeCreditPerMinute: Double = 1.5,
    /** Minutes of cost forgiven per minute a courier has been idle. */
    val courierIdleCreditPerMinute: Double = 0.4,
    /** Cap on **each** credit separately. */
    val maxCreditMinutes: Double = 25.0,
) {
    fun travelMinutes(km: Double): Double {
        if (averageSpeedKmh <= 0) return Double.POSITIVE_INFINITY
        return km / averageSpeedKmh * 60
    }

    /**
     * Cost in minutes of assigning [courier] to [order] at [nowEpochSeconds].
     *
     * Returns [HungarianSolver.FORBIDDEN] for pairs that must not be matched, so the
     * solver treats them as unmatchable rather than just unattractive.
     */
    fun cost(courier: DispatchCourier, order: DispatchOrder, nowEpochSeconds: Double): Double {
        if (order.id in courier.excludedOrderIds) return HungarianSolver.FORBIDDEN
        if (courier.id in order.excludedCourierIds) return HungarianSolver.FORBIDDEN

        val toPickupKm = courier.location.distanceKm(order.pickup)
        if (toPickupKm > maxAssignmentRadiusKm) return HungarianSolver.FORBIDDEN

        val toPickup = travelMinutes(toPickupKm)
        val deliveryLeg = travelMinutes(order.pickup.distanceKm(order.dropoff))

        // Courier idles at the counter if they beat the kitchen. That wasted time is a
        // real cost — it is the courier's, and it delays whatever they'd do next.
        // All three elapsed times below are computed the way Swift's `Date` arithmetic
        // computes them: subtract two absolute instants, then divide by 60. Do not
        // "simplify" to minute arithmetic — see the note on `idleSinceEpochSeconds`.
        val arrival = nowEpochSeconds + toPickup * 60
        val waitAtRestaurant = maxOf(0.0, (order.readyAtEpochSeconds - arrival) / 60)

        val orderAgeMinutes = maxOf(0.0, (nowEpochSeconds - order.createdAtEpochSeconds) / 60)
        val courierIdleMinutes = maxOf(0.0, (nowEpochSeconds - courier.idleSinceEpochSeconds) / 60)

        val urgencyCredit = minOf(orderAgeMinutes * orderAgeCreditPerMinute, maxCreditMinutes)
        val fairnessCredit = minOf(courierIdleMinutes * courierIdleCreditPerMinute, maxCreditMinutes)

        // Cost can legitimately go negative once credits apply; the solver handles that
        // fine and it is what lets a stale order outrank a cheap-but-new one.
        return toPickup + waitAtRestaurant + deliveryLeg - urgencyCredit - fairnessCredit
    }

    companion object {
        /** Pure distance only — the control arm in simulator experiments. */
        val DISTANCE_ONLY = DispatchCostModel(
            orderAgeCreditPerMinute = 0.0,
            courierIdleCreditPerMinute = 0.0,
        )
    }
}

interface Dispatcher {
    val name: String
    fun assign(
        couriers: List<DispatchCourier>,
        orders: List<DispatchOrder>,
        nowEpochSeconds: Double,
    ): List<Assignment>
}

/**
 * What Ravon does today, modelled faithfully so it can be measured.
 *
 * `fetch_available_orders` sorts by `created_at` and the first courier to tap wins, so in
 * effect the oldest order is taken by whichever courier is nearest to it, one order at a
 * time, with no lookahead. This is the baseline the optimal dispatcher has to beat.
 */
class GreedyDispatcher(
    private val costModel: DispatchCostModel = DispatchCostModel(),
) : Dispatcher {
    override val name = "greedy-fcfs"

    override fun assign(
        couriers: List<DispatchCourier>,
        orders: List<DispatchOrder>,
        nowEpochSeconds: Double,
    ): List<Assignment> {
        // Mutable copy whose order is preserved: `available` shrinks as couriers are
        // consumed and the inner loop's strict `<` means the lowest surviving *index*
        // wins ties, so this must be an indexed removal, not a filter.
        val available = couriers.toMutableList()
        val result = mutableListOf<Assignment>()

        // Sorted by createdAt, then id. The Swift original sorts on createdAt alone and
        // Swift's sort is not stable, so two orders sharing a createdAt could order
        // either way; the simulator generates distinct timestamps so it never bites, and
        // the id tiebreak makes the port deterministic regardless.
        val queue = orders.sortedWith(
            compareBy({ it.createdAtEpochSeconds }, { it.id })
        )

        for (order in queue) {
            var bestIndex: Int? = null
            var bestCost = Double.POSITIVE_INFINITY
            for ((index, courier) in available.withIndex()) {
                val cost = costModel.cost(courier, order, nowEpochSeconds)
                if (cost < HungarianSolver.FORBIDDEN && cost < bestCost) {
                    bestCost = cost
                    bestIndex = index
                }
            }
            val chosen = bestIndex ?: continue    // nobody eligible; order waits
            val courier = available.removeAt(chosen)
            result.add(Assignment(courier.id, order.id, bestCost))
        }
        return result
    }
}

/**
 * Solves the whole batch at once as a minimum-cost bipartite matching.
 *
 * The win over greedy is lookahead: greedy hands the nearest courier to the oldest order,
 * which can consume the only courier reachable by a second order and leave it unassigned.
 * Batch matching pays slightly more on one order to keep the other feasible.
 */
class OptimalBatchDispatcher(
    private val costModel: DispatchCostModel = DispatchCostModel(),
) : Dispatcher {
    override val name = "optimal-batch"

    override fun assign(
        couriers: List<DispatchCourier>,
        orders: List<DispatchOrder>,
        nowEpochSeconds: Double,
    ): List<Assignment> {
        if (couriers.isEmpty() || orders.isEmpty()) return emptyList()

        // Couriers are rows, orders are columns. Preserve that orientation: the solver's
        // zero-cost padding only absorbs surplus *rows*.
        val matrix = couriers.map { courier ->
            DoubleArray(orders.size) { j -> costModel.cost(courier, orders[j], nowEpochSeconds) }
        }
        val matching = HungarianSolver.solve(matrix)

        val result = mutableListOf<Assignment>()
        matching.forEachIndexed { courierIndex, orderIndex ->
            if (orderIndex == null) return@forEachIndexed
            val cost = matrix[courierIndex][orderIndex]
            if (cost >= HungarianSolver.FORBIDDEN) return@forEachIndexed
            result.add(Assignment(couriers[courierIndex].id, orders[orderIndex].id, cost))
        }
        return result
    }
}
