package dev.ravon.dispatch

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * The measurement behind [Libm]: how often the JVM's trig disagrees, bit for bit, with the
 * platform libm that the Swift engine called when it recorded the baseline.
 *
 * The inputs are the ones that matter: 600 bearings drawn from `SwiftRandom(1)` exactly as
 * `MarketplaceSimulator.randomPoint` draws them, a radial `nextDoubleClosed(0, 1)` and then
 * the bearing `nextDoubleHalfOpen(0, 2π)`. The draw order changes the inputs, and so the
 * counts: 600 consecutive bearings with no radial draw give 111 / 65 / 52 instead.
 *
 * The reference is the platform libm reached through [Libm]. That equals Swift's libm only
 * where the fixture was recorded, macOS, which is where CI runs this (`dispatch-quality`
 * is a `macos-15` job). On glibc the counts below may differ, and so may the baseline.
 */
class LibmDisagreementTest {

    private val bearings: List<Double> = SwiftRandom(1UL).let { rng ->
        List(600) {
            rng.nextDoubleClosed(0.0, 1.0)              // the radial draw, discarded here
            rng.nextDoubleHalfOpen(0.0, 2 * Math.PI)
        }
    }

    private fun Double.bits() = java.lang.Double.doubleToRawLongBits(this)

    private fun disagreements(
        sin: (Double) -> Double,
        cos: ((Double) -> Double)? = null,
    ): Int = bearings.count { x ->
        sin(x).bits() != Libm.sin(x).bits() ||
            (cos != null && cos(x).bits() != Libm.cos(x).bits())
    }

    private fun pct(n: Int) = "%.1f%%".format(100.0 * n / bearings.size)

    @Test
    fun `JVM trig disagrees with platform libm on a measured share of simulator bearings`() {
        val mathEither = disagreements(Math::sin, Math::cos)
        val mathSin = disagreements(Math::sin)
        val strictEither = disagreements(StrictMath::sin, StrictMath::cos)
        println(
            "libm disagreement over ${bearings.size} bearings from SwiftRandom(1): " +
                "Math.sin or Math.cos ${pct(mathEither)} ($mathEither), " +
                "Math.sin alone ${pct(mathSin)} ($mathSin), " +
                "StrictMath.sin or StrictMath.cos ${pct(strictEither)} ($strictEither)",
        )
        // Exact counts, not a tolerance: these are the numbers the docs quote.
        assertEquals(122, mathEither, "Math.sin or Math.cos: 122 / 600 = 20.3%")
        assertEquals(69, mathSin, "Math.sin alone: 69 / 600 = 11.5%")
        assertEquals(54, strictEither, "StrictMath.sin or StrictMath.cos: 54 / 600 = 9.0%")
    }

    @Test
    fun `negative control - the comparison reports zero against libm itself`() {
        // If the bitwise comparison were broken in the direction of always disagreeing,
        // the counts above would be noise. Libm against Libm must be exactly 0.
        assertEquals(0, disagreements(Libm::sin, Libm::cos))
    }

    @Test
    fun `negative control - a one-ULP perturbation is caught on every input`() {
        // And if it were broken the other way, blind to last-bit differences, 1 ULP would
        // slip through. It must disagree on all 600.
        assertEquals(bearings.size, disagreements({ Math.nextUp(Libm.sin(it)) }))
    }
}
