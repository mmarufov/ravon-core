package dev.ravon.dispatch

import java.util.UUID

/**
 * Experiment designs for evaluating a dispatch algorithm change.
 *
 * Port of Sources/RavonCore/Dispatch/SwitchbackExperiment.swift.
 *
 * ## Why this exists
 *
 * A/B testing a dispatch algorithm by randomising **individual orders** is **invalid**,
 * and the reason is structural rather than statistical: orders in the same place at the
 * same time draw from the *same courier pool*. Serving a treated order well consumes a
 * courier a control order needed. The arms interfere, which violates the independence
 * assumption every standard A/B test rests on (SUTVA).
 *
 * The answer is the **switchback test**: randomise over **(zone × time block)** cells, so
 * an entire zone runs one variant for an entire block and the market acts as its own
 * comparison.
 *
 * Doing this in a simulator is what makes it checkable — run the world entirely on one
 * algorithm, then entirely on the other with the same seed, and the difference is the
 * *true* effect. So the bias of each design can be **measured** rather than argued about.
 */
enum class ExperimentArm { CONTROL, TREATMENT }

/**
 * Assigns orders to arms. Deterministic, so an order's arm can be re-derived after the
 * simulation when computing per-arm metrics.
 */
class ArmAssignment(
    val name: String,
    private val armForOrder: (DispatchOrder) -> ExperimentArm,
    private val armForRecord: (MarketplaceSimulator.OrderRecord) -> ExperimentArm,
) {
    fun arm(order: DispatchOrder): ExperimentArm = armForOrder(order)
    fun arm(record: MarketplaceSimulator.OrderRecord): ExperimentArm = armForRecord(record)

    companion object {
        /**
         * Hash a UUID to a stable arm — FNV-style over the 16 identity bytes, matching
         * the Swift original's `withUnsafeBytes(of: id.uuid)` byte order (big-endian:
         * most-significant bits first).
         */
        private fun hashToArm(id: UUID, salt: ULong): ExperimentArm {
            var hash: ULong = salt + 0x9E3779B97F4A7C15UL
            val bytes = ByteArray(16)
            var msb = id.mostSignificantBits
            var lsb = id.leastSignificantBits
            for (i in 7 downTo 0) { bytes[i] = (msb and 0xFF).toByte(); msb = msb ushr 8 }
            for (i in 15 downTo 8) { bytes[i] = (lsb and 0xFF).toByte(); lsb = lsb ushr 8 }
            for (b in bytes) {
                hash = (hash xor (b.toULong() and 0xFFUL)) * 0x100000001B3UL
            }
            return if (hash % 2UL == 0UL) ExperimentArm.CONTROL else ExperimentArm.TREATMENT
        }

        /**
         * **The invalid design.** Each order independently coin-flipped, while both arms
         * compete for one courier pool.
         *
         * A caveat the Swift original cannot state about itself: there, order ids come
         * from `UUID()` and are therefore *random per run*, so this design's arm split —
         * and every number derived from it — is not reproducible. This port derives ids
         * from the order index, so the split is deterministic. That makes the Kotlin
         * naive-design figures stable but **not** comparable to any particular Swift run.
         * Only the *property* (that this design is badly biased) transfers, which is
         * exactly what the tests assert.
         */
        fun naiveOrderLevel(salt: ULong = 1UL): ArmAssignment = ArmAssignment(
            name = "naive-order-level-ab",
            armForOrder = { hashToArm(it.id, salt) },
            armForRecord = { hashToArm(it.id, salt) },
        )

        /**
         * **The switchback design.** A whole (zone × time block) cell runs one variant,
         * so orders competing for the same couriers at the same time are almost always in
         * the same arm. Deterministic in both languages.
         */
        fun switchback(
            grid: ZoneGrid,
            blockMinutes: Double,
            salt: ULong = 1UL,
        ): ArmAssignment {
            fun cellArm(zone: DispatchZone, block: Int): ExperimentArm {
                var hash = salt + 0x9E3779B97F4A7C15UL
                for (value in longArrayOf(zone.row.toLong(), zone.column.toLong(), block.toLong())) {
                    hash = (hash xor value.toULong()) * 0x100000001B3UL
                    hash = hash xor (hash shr 29)
                }
                return if (hash % 2UL == 0UL) ExperimentArm.CONTROL else ExperimentArm.TREATMENT
            }
            return ArmAssignment(
                name = "switchback-zone-x-timeblock",
                armForOrder = { order ->
                    val minutes =
                        (order.createdAtEpochSeconds - MarketplaceSimulator.EPOCH_SECONDS) / 60
                    cellArm(grid.zone(order.pickup), StrictMath.floor(minutes / blockMinutes).toInt())
                },
                armForRecord = { record ->
                    cellArm(
                        grid.zone(record.pickup),
                        StrictMath.floor(record.createdAtMinutes / blockMinutes).toInt(),
                    )
                },
            )
        }
    }
}

/**
 * Runs two dispatchers side by side inside one simulated world, splitting orders by arm
 * while both draw from the **same courier pool** — which is precisely the interference
 * that makes naive A/B testing wrong.
 */
class ExperimentDispatcher(
    private val control: Dispatcher,
    private val treatment: Dispatcher,
    private val assignment: ArmAssignment,
) : Dispatcher {
    override val name: String = "experiment[${assignment.name}]"

    override fun assign(
        couriers: List<DispatchCourier>,
        orders: List<DispatchOrder>,
        nowEpochSeconds: Double,
    ): List<Assignment> {
        val treated = orders.filter { assignment.arm(it) == ExperimentArm.TREATMENT }
        val controlled = orders.filter { assignment.arm(it) == ExperimentArm.CONTROL }

        // Whichever arm runs first gets first refusal on the courier pool. Alternating by
        // tick stops that ordering from becoming a systematic advantage that would
        // masquerade as a treatment effect.
        //
        // The original reads `Int(now.timeIntervalSince1970 / 60) % 2`, i.e. the *Unix*
        // view of the instant, so the parity depends on the absolute epoch and not just
        // the elapsed time. Hence the conversion rather than using minutes directly.
        val unixSeconds =
            nowEpochSeconds - MarketplaceSimulator.EPOCH_SECONDS + MarketplaceSimulator.EPOCH_UNIX_SECONDS
        val treatmentFirst = (unixSeconds / 60).toLong() % 2L == 0L

        val remaining = couriers.toMutableList()
        val result = mutableListOf<Assignment>()

        fun runArm(dispatcher: Dispatcher, subset: List<DispatchOrder>) {
            if (subset.isEmpty() || remaining.isEmpty()) return
            val assignments = dispatcher.assign(remaining, subset, nowEpochSeconds)
            val consumed = assignments.map { it.courierId }.toSet()
            remaining.removeAll { it.id in consumed }
            result += assignments
        }

        if (treatmentFirst) {
            runArm(treatment, treated)
            runArm(control, controlled)
        } else {
            runArm(control, controlled)
            runArm(treatment, treated)
        }
        return result
    }
}

/** Measures a dispatch change under two designs and reports how badly each one lies. */
object SwitchbackExperiment {

    data class ArmMetrics(
        val orders: Int,
        val assigned: Int,
        val meanDeliveryMinutes: Double,
    ) {
        val assignmentRate: Double get() = if (orders == 0) 0.0 else assigned.toDouble() / orders
    }

    data class DesignResult(
        val designName: String,
        val control: ArmMetrics,
        val treatment: ArmMetrics,
    ) {
        /** Estimated effect on assignment rate, in percentage points. */
        val estimatedLiftPoints: Double
            get() = (treatment.assignmentRate - control.assignmentRate) * 100

        /** Estimated effect on mean delivery time, in minutes (negative is better). */
        val estimatedDeliveryDeltaMinutes: Double
            get() = treatment.meanDeliveryMinutes - control.meanDeliveryMinutes
    }

    data class Report(
        /** The true effect, from running the world entirely on each algorithm. */
        val groundTruthLiftPoints: Double,
        val groundTruthDeliveryDeltaMinutes: Double,
        val designs: List<DesignResult>,
    ) {
        fun biasPoints(designName: String): Double? =
            designs.firstOrNull { it.designName == designName }
                ?.let { it.estimatedLiftPoints - groundTruthLiftPoints }

        val summary: String
            get() = buildList {
                add(
                    "ground truth (full-world A vs full-world B):  lift %+.1f pts, delivery %+.1f min"
                        .format(groundTruthLiftPoints, groundTruthDeliveryDeltaMinutes)
                )
                designs.forEach { design ->
                    val bias = design.estimatedLiftPoints - groundTruthLiftPoints
                    // `%-30s` is safe here. The Swift original had to pad by hand because
                    // `String(format:)` with `%s` takes a C string and segfaults on a
                    // Swift String; `%@` is correct but ignores width flags. The JVM has
                    // no such trap.
                    add(
                        "%-30s lift %+6.1f pts  (bias %+6.1f pts)  delivery %+6.1f min".format(
                            design.designName, design.estimatedLiftPoints, bias,
                            design.estimatedDeliveryDeltaMinutes,
                        )
                    )
                }
            }.joinToString("\n")
    }

    private fun metrics(
        records: List<MarketplaceSimulator.OrderRecord>,
        arm: ExperimentArm,
        assignment: ArmAssignment,
    ): ArmMetrics {
        val subset = records.filter { assignment.arm(it) == arm }
        val delivered = subset.mapNotNull { it.totalDeliveryMinutes }
        return ArmMetrics(
            orders = subset.size,
            assigned = subset.count { it.assignedAtMinutes != null },
            meanDeliveryMinutes =
                if (delivered.isEmpty()) 0.0
                else delivered.fold(0.0) { a, b -> a + b } / delivered.size,
        )
    }

    /**
     * @param blockMinutes switchback block length. Short blocks give more randomisation
     *   units and more statistical power; long blocks reduce carryover between arms. The
     *   trade DoorDash calls out explicitly.
     */
    fun run(
        config: MarketplaceSimulator.Config,
        control: Dispatcher,
        treatment: Dispatcher,
        zoneDivisions: Int = 3,
        blockMinutes: Double = 30.0,
    ): Report {
        // Ground truth: two separate worlds, same seed, one algorithm each.
        val fullControl = MarketplaceSimulator.run(config, control)
        val fullTreatment = MarketplaceSimulator.run(config, treatment)
        val truthLift = (
            fullTreatment.ordersAssigned.toDouble() / fullTreatment.ordersOffered -
                fullControl.ordersAssigned.toDouble() / fullControl.ordersOffered
            ) * 100
        val truthDelivery = fullTreatment.meanDeliveryMinutes - fullControl.meanDeliveryMinutes

        val grid = ZoneGrid(config.cityCenter, config.cityRadiusKm, zoneDivisions)
        val designs = listOf(
            ArmAssignment.naiveOrderLevel(salt = config.seed),
            ArmAssignment.switchback(grid, blockMinutes, salt = config.seed),
        )

        val results = designs.map { assignment ->
            val mixed = MarketplaceSimulator.run(
                config,
                ExperimentDispatcher(control, treatment, assignment),
            )
            DesignResult(
                designName = assignment.name,
                control = metrics(mixed.orderRecords, ExperimentArm.CONTROL, assignment),
                treatment = metrics(mixed.orderRecords, ExperimentArm.TREATMENT, assignment),
            )
        }

        return Report(truthLift, truthDelivery, results)
    }
}
