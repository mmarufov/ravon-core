package dev.ravon.dispatch

import com.fasterxml.jackson.annotation.JsonIgnoreProperties
import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import com.fasterxml.jackson.module.kotlin.readValue
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * **The acceptance test for the Kotlin dispatch port.**
 *
 * `Tests/RavonCoreTests/Fixtures/dispatch-baseline.json` was recorded by compiling and
 * running the *Swift* engine before this port existed: 30 seeds × 2 dispatchers × 11
 * metrics, at the exact configuration `DispatchSimulationTests` uses (12 couriers, 240
 * orders, 180 minutes). The port is correct when every one of those 660 numbers matches.
 *
 * Doubles are compared **bitwise**. A tolerance would let a subtly different simulation
 * pass, and the whole value of the fixture is that it cannot.
 */
class DispatchBaselineTest {

    @JsonIgnoreProperties(ignoreUnknown = true)
    private data class Row(
        val seed: Long = 0,
        val dispatcher: String = "",
        val ordersOffered: Int = 0,
        val ordersAssigned: Int = 0,
        val ordersNeverAssigned: Int = 0,
        val meanWaitToAssignMinutes: Double = 0.0,
        val p95WaitToAssignMinutes: Double = 0.0,
        val meanDeliveryMinutes: Double = 0.0,
        val totalCourierTravelKm: Double = 0.0,
        val giniCoefficient: Double = 0.0,
        val couriersWithNoWork: Int = 0,
        val jobsPerCourier: List<Int> = emptyList(),
    )

    @JsonIgnoreProperties(ignoreUnknown = true)
    private data class Baseline(
        val rows: List<Row> = emptyList(),
        val meanImprovementOrdersAssigned: Double = 0.0,
        val meanImprovementDeliveryMinutes: Double = 0.0,
        val meanImprovementTravelKm: Double = 0.0,
        val minImprovementOrdersAssigned: Double = 0.0,
        val seedsWhereOptimalWins: Int = 0,
    )

    private val baseline: Baseline = jacksonObjectMapper()
        .readValue(Files.readString(Fixtures.path("dispatch-baseline.json")))

    private fun config(seed: Long, couriers: Int = 12) = MarketplaceSimulator.Config(
        seed = seed.toULong(),
        courierCount = couriers,
        orderCount = 240,
        durationMinutes = 180.0,
    )

    private fun dispatcherNamed(name: String): Dispatcher = when (name) {
        "greedy" -> GreedyDispatcher()
        "optimal" -> OptimalBatchDispatcher()
        else -> error("unknown dispatcher in fixture: $name")
    }

    @Test
    fun `fixture is the expected shape`() {
        assertEquals(60, baseline.rows.size, "expected 30 seeds x 2 dispatchers")
        assertEquals(30, baseline.rows.count { it.dispatcher == "greedy" })
        assertEquals(30, baseline.rows.count { it.dispatcher == "optimal" })
    }

    @Test
    fun `every seed reproduces the Swift baseline exactly`() {
        val failures = mutableListOf<String>()

        for (row in baseline.rows) {
            val result = MarketplaceSimulator.run(
                config(row.seed),
                dispatcherNamed(row.dispatcher),
            )
            val where = "seed ${row.seed} / ${row.dispatcher}"

            fun cmpInt(field: String, expected: Int, actual: Int) {
                if (expected != actual) failures += "$where $field: expected $expected, got $actual"
            }
            fun cmpDouble(field: String, expected: Double, actual: Double) {
                if (expected.toRawBits() != actual.toRawBits()) {
                    failures += "$where $field: expected $expected, got $actual" +
                        " (delta ${actual - expected})"
                }
            }

            cmpInt("ordersOffered", row.ordersOffered, result.ordersOffered)
            cmpInt("ordersAssigned", row.ordersAssigned, result.ordersAssigned)
            cmpInt("ordersNeverAssigned", row.ordersNeverAssigned, result.ordersNeverAssigned)
            cmpInt("couriersWithNoWork", row.couriersWithNoWork, result.couriersWithNoWork)
            cmpDouble("meanWaitToAssignMinutes", row.meanWaitToAssignMinutes, result.meanWaitToAssignMinutes)
            cmpDouble("p95WaitToAssignMinutes", row.p95WaitToAssignMinutes, result.p95WaitToAssignMinutes)
            cmpDouble("meanDeliveryMinutes", row.meanDeliveryMinutes, result.meanDeliveryMinutes)
            cmpDouble("totalCourierTravelKm", row.totalCourierTravelKm, result.totalCourierTravelKm)
            cmpDouble("giniCoefficient", row.giniCoefficient, result.giniCoefficient)
            if (row.jobsPerCourier != result.jobsPerCourier) {
                failures += "$where jobsPerCourier: expected ${row.jobsPerCourier}," +
                    " got ${result.jobsPerCourier}"
            }
        }

        assertTrue(
            failures.isEmpty(),
            "${failures.size} mismatches against the Swift baseline:\n" +
                failures.take(25).joinToString("\n") +
                if (failures.size > 25) "\n… and ${failures.size - 25} more" else "",
        )
    }

    /**
     * The aggregate claims, recomputed from this port rather than copied.
     *
     * Carried over from the Swift `DispatchSimulationTests`, including the corrected
     * figures: the mean throughput gain is +44.6 % (the docs long said +42 %), and the
     * travel result is a mean of −1.06 % with a **worst single seed of +2.13 %** — so the
     * defensible claim is "no measurable travel penalty", not "less travel".
     */
    @Test
    fun `aggregate improvements match the recorded summary`() {
        val improvements = (1L..30L).map { seed ->
            val greedy = MarketplaceSimulator.run(config(seed), GreedyDispatcher())
            val optimal = MarketplaceSimulator.run(config(seed), OptimalBatchDispatcher())
            Triple(
                (optimal.ordersAssigned - greedy.ordersAssigned).toDouble() / greedy.ordersAssigned,
                (optimal.meanDeliveryMinutes - greedy.meanDeliveryMinutes) / greedy.meanDeliveryMinutes,
                (optimal.totalCourierTravelKm - greedy.totalCourierTravelKm) / greedy.totalCourierTravelKm,
            )
        }
        fun mean(xs: List<Double>) = xs.fold(0.0) { a, b -> a + b } / xs.size

        assertEquals(
            baseline.meanImprovementOrdersAssigned,
            mean(improvements.map { it.first }),
            1e-12,
            "mean orders-assigned improvement",
        )
        assertEquals(
            baseline.meanImprovementDeliveryMinutes,
            mean(improvements.map { it.second }),
            1e-12,
            "mean delivery-time improvement",
        )
        assertEquals(
            baseline.meanImprovementTravelKm,
            mean(improvements.map { it.third }),
            1e-12,
            "mean travel improvement",
        )
        assertEquals(
            baseline.seedsWhereOptimalWins,
            improvements.count { it.first > 0 },
            "seeds where optimal wins",
        )
    }

    /** The guard the Swift suite carries, at the value it was tightened to. */
    @Test
    fun `optimal dispatch is substantially better under load`() {
        val improvements = (1L..30L).map { seed ->
            val greedy = MarketplaceSimulator.run(config(seed), GreedyDispatcher())
            val optimal = MarketplaceSimulator.run(config(seed), OptimalBatchDispatcher())
            (optimal.ordersAssigned - greedy.ordersAssigned).toDouble() / greedy.ordersAssigned
        }
        val mean = improvements.fold(0.0) { a, b -> a + b } / improvements.size
        assertTrue(mean >= 0.35, "mean improvement collapsed to ${mean * 100}%")
    }

    @Test
    fun `optimal never loses to greedy on any seed`() {
        for (seed in 1L..30L) {
            val greedy = MarketplaceSimulator.run(config(seed), GreedyDispatcher())
            val optimal = MarketplaceSimulator.run(config(seed), OptimalBatchDispatcher())
            assertTrue(
                optimal.ordersAssigned >= greedy.ordersAssigned,
                "seed $seed: batch matching served fewer orders" +
                    " (${optimal.ordersAssigned}) than greedy (${greedy.ordersAssigned})",
            )
        }
    }

    /**
     * The honest finding, ported verbatim: the advantage is a function of scarcity and
     * vanishes once supply exceeds demand. Worth keeping so nobody later "optimises"
     * dispatch for a regime where it cannot matter.
     */
    @Test
    fun `advantage vanishes when couriers are abundant`() {
        val scarceGain = MarketplaceSimulator.run(config(42, couriers = 6), OptimalBatchDispatcher())
            .ordersAssigned -
            MarketplaceSimulator.run(config(42, couriers = 6), GreedyDispatcher()).ordersAssigned
        val abundantGreedy = MarketplaceSimulator.run(config(42, couriers = 48), GreedyDispatcher())
        val abundantOptimal = MarketplaceSimulator.run(config(42, couriers = 48), OptimalBatchDispatcher())

        assertTrue(scarceGain > 20, "expected a large gain when couriers are scarce, got $scarceGain")
        assertEquals(
            abundantGreedy.ordersAssigned,
            abundantOptimal.ordersAssigned,
            "with surplus couriers both strategies should saturate demand",
        )
    }

    @Test
    fun `simulation is reproducible`() {
        val a = MarketplaceSimulator.run(config(7), OptimalBatchDispatcher())
        val b = MarketplaceSimulator.run(config(7), OptimalBatchDispatcher())
        assertEquals(a, b)
    }
}
