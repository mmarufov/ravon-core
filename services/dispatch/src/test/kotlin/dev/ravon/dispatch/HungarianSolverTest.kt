package dev.ravon.dispatch

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Port of Tests/RavonCoreTests/HungarianSolverTests.swift.
 *
 * The centrepiece is [`matches brute force optimum on random matrices`] — 300 random
 * matrices checked against an exhaustive optimum. That is what retires a commercial
 * solver from the plan's non-goals: the matching is *exact* at this problem size, and
 * exactness is proven rather than assumed.
 *
 * The same [SwiftRandom] drives the matrix generation as in the simulator, so these
 * matrices are the identical 300 the Swift suite checks.
 */
class HungarianSolverTest {

    /**
     * Exhaustive optimum by trying every assignment. Only tractable for tiny n, which is
     * exactly what makes it a trustworthy oracle.
     */
    private fun bruteForceOptimum(cost: List<DoubleArray>): Double {
        val rows = cost.size
        val columns = cost[0].size
        var best = Double.POSITIVE_INFINITY

        fun permute(chosen: List<Int>, remaining: List<Int>) {
            if (chosen.size == minOf(rows, columns)) {
                var total = 0.0
                chosen.forEachIndexed { row, column -> total += cost[row][column] }
                best = minOf(best, total)
                return
            }
            remaining.forEachIndexed { offset, column ->
                permute(chosen + column, remaining.filterIndexed { i, _ -> i != offset })
            }
        }
        permute(emptyList(), (0 until columns).toList())
        return best
    }

    @Test
    fun `known optimum on a square matrix`() {
        // Greedy picks (0,0)=1 then is forced into (1,1)=100 -> 101.
        // The optimum takes (0,1)=2 and (1,0)=3 -> 5.
        val cost = listOf(doubleArrayOf(1.0, 2.0), doubleArrayOf(3.0, 100.0))
        val assignment = HungarianSolver.solve(cost)
        assertEquals(5.0, HungarianSolver.totalCost(assignment, cost), 1e-9)
        assertEquals(listOf(1, 0), assignment.toList())
    }

    /**
     * **The property that matters: the solver's matching must equal the true optimum.**
     * Verified against brute force over 300 random matrices, generated from the same
     * seeded stream the Swift suite uses.
     */
    @Test
    fun `matches brute force optimum on random matrices`() {
        val rng = SwiftRandom(0xD15A7C4UL)
        for (trial in 0 until 300) {
            val rows = 1 + rng.nextIntHalfOpen(5)              // Int.random(in: 1...5)
            val columns = rows + rng.nextIntHalfOpen(6 - rows + 1) // Int.random(in: rows...6)
            val cost = (0 until rows).map {
                DoubleArray(columns) { rng.nextIntHalfOpen(51).toDouble() } // 0...50
            }
            val assignment = HungarianSolver.solve(cost)
            val solved = HungarianSolver.totalCost(assignment, cost)
            val optimal = bruteForceOptimum(cost)
            assertEquals(
                optimal, solved, 1e-9,
                "trial $trial: solver got $solved, optimum is $optimal, cost=" +
                    cost.joinToString { it.toList().toString() },
            )
        }
    }

    @Test
    fun `matching is a valid permutation`() {
        val rng = SwiftRandom(7UL)
        repeat(200) {
            val rows = 1 + rng.nextIntHalfOpen(6)
            val columns = 1 + rng.nextIntHalfOpen(6)
            val cost = (0 until rows).map {
                DoubleArray(columns) { rng.nextIntHalfOpen(100).toDouble() }
            }
            val assignment = HungarianSolver.solve(cost)
            assertEquals(rows, assignment.size)
            val used = assignment.filterNotNull()
            assertEquals(used.size, used.toSet().size, "a column was assigned to two rows")
            used.forEach { assertTrue(it in 0 until columns, "column $it out of range") }
            if (columns >= rows) {
                assertEquals(rows, used.size, "a row went unmatched despite spare columns")
            } else {
                assertEquals(columns, used.size, "a column went unused despite waiting rows")
            }
        }
    }

    /**
     * Surplus couriers (more rows than columns) must come back unmatched, not matched to
     * a phantom order. This is what the zero-cost dummy-column padding buys.
     */
    @Test
    fun `surplus rows are unmatched`() {
        val cost = listOf(doubleArrayOf(5.0), doubleArrayOf(3.0), doubleArrayOf(9.0))
        val assignment = HungarianSolver.solve(cost)
        assertEquals(1, assignment.filterNotNull().size, "only one order exists")
        assertEquals(0, assignment[1], "the cheapest courier should take the only order")
        assertNull(assignment[0])
        assertNull(assignment[2])
    }

    /**
     * A forbidden pair must never be selected, even when it is the only option — better
     * to leave an order unassigned than to dispatch an excluded courier.
     */
    @Test
    fun `forbidden pairs are never matched`() {
        val cost = listOf(
            doubleArrayOf(HungarianSolver.FORBIDDEN, 4.0),
            doubleArrayOf(2.0, HungarianSolver.FORBIDDEN),
        )
        val assignment = HungarianSolver.solve(cost)
        assertEquals(1, assignment[0])
        assertEquals(0, assignment[1])

        // Courier 0 is banned from the only order -> must stay unassigned.
        val impossible = listOf(doubleArrayOf(HungarianSolver.FORBIDDEN))
        assertNull(HungarianSolver.solve(impossible)[0])
    }

    @Test
    fun `empty input is handled`() {
        assertTrue(HungarianSolver.solve(emptyList()).isEmpty())
        assertTrue(HungarianSolver.solve(listOf(DoubleArray(0))).isEmpty())
    }

    /** Haversine sanity: Dushanbe to Khujand is ~200 km straight-line. */
    @Test
    fun `haversine matches a known distance`() {
        val dushanbe = GeoPoint(38.5598, 68.7870)
        val khujand = GeoPoint(40.2833, 69.6222)
        val distance = dushanbe.distanceKm(khujand)
        assertTrue(distance in 190.0..215.0, "expected ~200 km, got $distance")
        assertEquals(0.0, dushanbe.distanceKm(dushanbe), 1e-12)
        assertEquals(distance, khujand.distanceKm(dushanbe), 1e-12, "distance must be symmetric")
    }
}
