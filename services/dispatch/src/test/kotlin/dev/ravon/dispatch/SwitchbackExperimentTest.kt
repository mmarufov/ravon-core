package dev.ravon.dispatch

import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * Port of Tests/RavonCoreTests/SwitchbackExperimentTests.swift — findings from the
 * experiment-design study, pinned so they stay true.
 *
 * The headline result is not the one that was expected going in, which is why it is worth
 * having tests for.
 *
 * **What transfers from Swift and what does not.** The switchback design hashes
 * (zone × block), so it is deterministic in both languages and these thresholds are
 * directly comparable. The naive order-level design hashes the order *id*, and Swift's
 * ids come from `UUID()` — random per run — so its naive figures were never reproducible.
 * This port uses index-derived ids, so the naive numbers here are stable but are not the
 * same numbers any particular Swift run produced. Only the properties transfer, which is
 * all the Swift suite asserted anyway.
 */
class SwitchbackExperimentTest {

    private fun config(seed: ULong) = MarketplaceSimulator.Config(
        seed = seed, courierCount = 12, orderCount = 240, durationMinutes = 180.0,
    )

    private fun meanAbsoluteBias(divisions: Int, design: String, seeds: LongRange): Double {
        val biases = seeds.mapNotNull { seed ->
            val cfg = config(seed.toULong())
            val grid = ZoneGrid(cfg.cityCenter, cfg.cityRadiusKm, divisions)
            SwitchbackExperiment.run(
                config = cfg,
                control = ZonedDispatcher(GreedyDispatcher(), grid),
                treatment = ZonedDispatcher(OptimalBatchDispatcher(), grid),
                zoneDivisions = divisions,
                blockMinutes = 30.0,
            ).biasPoints(design)?.let { StrictMath.abs(it) }
        }
        return biases.fold(0.0) { a, b -> a + b } / biases.size
    }

    /**
     * **The main finding.** Experiment bias is dominated by whether the *algorithm*
     * operates at the same granularity the experiment randomises at — not by arm-to-arm
     * interference.
     *
     * A batch optimiser's effect is a property of the whole dispatch decision, not of an
     * individual order. Evaluate it on half the orders and it is measurably not the same
     * algorithm. Partitioning dispatch by zone makes each zone a coherent small market,
     * and the bias collapses by roughly an order of magnitude.
     *
     * Note the thresholds pin an order-of-magnitude *floor*, not the measured value. The
     * study prose claims "roughly 10x"; what is actually protected is "at least halved".
     * That gap is deliberate — it survives cost-model tuning — but the prose overstates
     * what the test guarantees, and that is worth knowing before quoting the 10x.
     */
    @Test
    fun `zone partitioning collapses experiment bias`() {
        val unpartitioned = meanAbsoluteBias(1, "switchback-zone-x-timeblock", 1L..12L)
        val partitioned = meanAbsoluteBias(3, "switchback-zone-x-timeblock", 1L..12L)

        assertTrue(
            unpartitioned > 10,
            "expected large bias with one global courier pool, got $unpartitioned pts",
        )
        assertTrue(
            partitioned < 6,
            "expected small bias once dispatch is zone-partitioned, got $partitioned pts",
        )
        assertTrue(
            partitioned < unpartitioned / 2,
            "zone partitioning should at least halve the bias ($unpartitioned -> $partitioned)",
        )
    }

    /** Bias should fall as the partition gets finer — monotone, not a lucky single point. */
    @Test
    fun `bias decreases with finer partitioning`() {
        val coarse = meanAbsoluteBias(1, "switchback-zone-x-timeblock", 1L..8L)
        val medium = meanAbsoluteBias(2, "switchback-zone-x-timeblock", 1L..8L)
        val fine = meanAbsoluteBias(3, "switchback-zone-x-timeblock", 1L..8L)

        assertTrue(coarse > medium, "1x1 ($coarse) should be worse than 2x2 ($medium)")
        assertTrue(medium > fine, "2x2 ($medium) should be worse than 3x3 ($fine)")
    }

    /**
     * **The honest negative result.** At this scale, once dispatch is zone-partitioned,
     * order-level randomisation is about as unbiased as a switchback.
     *
     * That does not contradict DoorDash — it localises *why* switchbacks matter. With 12
     * couriers spread over 9 zones there is barely any cross-arm competition left to
     * contaminate, so temporal blocking has little left to buy. Their markets are far more
     * densely coupled, with real carryover between time blocks. The transferable lesson
     * from this experiment is the granularity one, not a reproduction of their headline.
     */
    @Test
    fun `switchback and naive are comparable once zoned`() {
        val naive = meanAbsoluteBias(3, "naive-order-level-ab", 1L..12L)
        val switchback = meanAbsoluteBias(3, "switchback-zone-x-timeblock", 1L..12L)

        assertTrue(naive < 6, "naive bias unexpectedly large once zoned: $naive")
        assertTrue(switchback < 6, "switchback bias unexpectedly large once zoned: $switchback")
        assertTrue(
            maxOf(naive, switchback) / maxOf(minOf(naive, switchback), 0.01) < 3.0,
            "expected comparable bias at this scale, got naive $naive vs switchback $switchback",
        )
    }

    /** Arm assignment must be balanced, or the comparison is confounded before it starts. */
    @Test
    fun `arm assignment is roughly balanced`() {
        val cfg = config(42UL)
        val run = MarketplaceSimulator.run(cfg, GreedyDispatcher())
        val grid = ZoneGrid(cfg.cityCenter, cfg.cityRadiusKm, 3)

        for (assignment in listOf(
            ArmAssignment.naiveOrderLevel(salt = 42UL),
            ArmAssignment.switchback(grid, blockMinutes = 30.0, salt = 42UL),
        )) {
            val treated = run.orderRecords.count { assignment.arm(it) == ExperimentArm.TREATMENT }
            val share = treated.toDouble() / run.orderRecords.size
            assertEquals(
                0.5, share, 0.20,
                "${assignment.name} put ${share * 100}% in treatment",
            )
        }
    }

    /**
     * Arm assignment must be a pure function of the order, so it can be re-derived after
     * the simulation when computing per-arm metrics.
     */
    @Test
    fun `arm assignment is deterministic`() {
        val cfg = config(5UL)
        val run = MarketplaceSimulator.run(cfg, GreedyDispatcher())
        val assignment = ArmAssignment.naiveOrderLevel(salt = 5UL)
        run.orderRecords.take(50).forEach { record ->
            assertEquals(assignment.arm(record), assignment.arm(record))
        }
    }

    /** Zoned dispatch must never send a courier to an order outside their own zone. */
    @Test
    fun `zoned dispatcher keeps assignments within zone`() {
        val center = GeoPoint(38.5598, 68.7870)
        val grid = ZoneGrid(center, radiusKm = 6.0, divisions = 3)
        val now = MarketplaceSimulator.EPOCH_SECONDS

        // One courier in the far north-west, one order in the far south-east.
        val nw = GeoPoint(center.latitude + 0.04, center.longitude - 0.05)
        val se = GeoPoint(center.latitude - 0.04, center.longitude + 0.05)
        assertNotEquals(grid.zone(nw), grid.zone(se), "test setup: points must differ in zone")

        val courier = DispatchCourier(UUID.randomUUID(), nw, idleSinceEpochSeconds = now)
        val order = DispatchOrder(
            UUID.randomUUID(), pickup = se, dropoff = se,
            readyAtEpochSeconds = now, createdAtEpochSeconds = now,
        )

        val zoned = ZonedDispatcher(OptimalBatchDispatcher(), grid)
        assertTrue(
            zoned.assign(listOf(courier), listOf(order), now).isEmpty(),
            "zoned dispatch crossed a zone boundary",
        )
    }

    /**
     * Points outside the grid's bounding box must clamp into edge zones rather than
     * producing out-of-range indices.
     */
    @Test
    fun `zone grid clamps out of bounds points`() {
        val grid = ZoneGrid(GeoPoint(38.5598, 68.7870), radiusKm = 6.0, divisions = 3)
        val zone = grid.zone(GeoPoint(89.0, 179.0))
        assertTrue(zone.row in 0 until 3)
        assertTrue(zone.column in 0 until 3)
    }
}
