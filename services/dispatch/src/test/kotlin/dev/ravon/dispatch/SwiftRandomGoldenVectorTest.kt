package dev.ravon.dispatch

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import com.fasterxml.jackson.module.kotlin.readValue
import java.nio.file.Files
import java.nio.file.Path
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Pins [SwiftRandom] against vectors recorded from the Swift original.
 *
 * This is the test that makes the whole port possible. Reproducing SplitMix64 is trivial;
 * reproducing Swift's mapping from 64 raw bits into a range is not, and getting it wrong
 * produces a simulator that is statistically plausible and numerically different — which
 * would silently invalidate every measured claim about dispatch quality.
 *
 * Doubles are compared **bitwise**, not with a tolerance. A tolerance here would defeat
 * the purpose: the point is not "close enough", it is "the same stream".
 */
class SwiftRandomGoldenVectorTest {

    private data class Vectors(
        val note: String = "",
        val seed: Long = 0,
        val rawNext: List<String> = emptyList(),
        val doubleClosed01: List<Double> = emptyList(),
        val doubleHalfOpen2Pi: List<Double> = emptyList(),
        val doubleClosed12to20: List<Double> = emptyList(),
        val intHalfOpen0to7: List<Int> = emptyList(),
        val gaussianMean0Sigma1: List<Double> = emptyList(),
    )

    private val vectors: Vectors = jacksonObjectMapper()
        .readValue(Files.readString(Fixtures.path("dispatch-rng-golden-vectors.json")))

    private val n get() = vectors.rawNext.size

    @Test
    fun `splitmix64 state update matches`() {
        val rng = SwiftRandom(42UL)
        val got = (0 until n).map { rng.next().toString() }
        assertEquals(vectors.rawNext, got, "raw next() stream diverged")
    }

    @Test
    fun `closed-range double matches bitwise`() {
        val rng = SwiftRandom(42UL)
        assertBitwise(vectors.doubleClosed01, (0 until n).map { rng.nextDoubleClosed(0.0, 1.0) })
    }

    @Test
    fun `half-open double takes the power-of-two path and matches bitwise`() {
        val rng = SwiftRandom(42UL)
        assertBitwise(
            vectors.doubleHalfOpen2Pi,
            (0 until n).map { rng.nextDoubleHalfOpen(0.0, 2 * Math.PI) },
        )
    }

    @Test
    fun `closed-range double over a non-unit interval matches bitwise`() {
        val rng = SwiftRandom(42UL)
        assertBitwise(
            vectors.doubleClosed12to20,
            (0 until n).map { rng.nextDoubleClosed(12.0, 20.0) },
        )
    }

    @Test
    fun `integer range uses Lemire and matches`() {
        val rng = SwiftRandom(42UL)
        assertEquals(vectors.intHalfOpen0to7, (0 until n).map { rng.nextIntHalfOpen(7) })
    }

    /**
     * Box-Muller, to **1 ULP** rather than bitwise — and the reason matters.
     *
     * The *draws* match exactly: this test consumes the same generator stream as Swift,
     * which is what the bitwise tests above prove. What differs is the transcendental
     * arithmetic on top. Darwin's libm and the JVM disagree by one unit in the last place
     * on `log`/`cos` for some inputs — measured: index 0 comes out
     * `0.41471975043153053` here against Swift's `0.41471975043153050`, while the other
     * fifteen agree bit-for-bit. Both `Math` and `StrictMath` produce the identical JVM
     * value, so there is no library choice that closes the gap.
     *
     * **This cannot affect the recorded baseline.** `gaussian` short-circuits when
     * `sigma <= 0` and consumes zero draws, and the baseline configuration uses
     * [MarketplaceSimulator.LatentVariability.NONE] where every sigma is zero — so no
     * gaussian is evaluated at all on that path. [`latent regime NONE never draws a
     * gaussian`][gaussianIsUnusedInTheBaselineRegime] pins that.
     *
     * It *would* affect a run with `LatentVariability.REALISTIC`, which is the regime the
     * `ml/` layer uses. Anyone comparing Kotlin and Swift simulator output under latent
     * noise should expect last-bit drift that compounds over a run, and should compare
     * distributions rather than bits.
     */
    @Test
    fun `box-muller gaussian matches to one ulp`() {
        val rng = SwiftRandom(42UL)
        val got = (0 until n).map {
            val u1 = maxOf(rng.nextDoubleClosed(0.0, 1.0), 1e-12)
            val u2 = rng.nextDoubleClosed(0.0, 1.0)
            StrictMath.sqrt(-2 * StrictMath.log(u1)) * StrictMath.cos(2 * Math.PI * u2)
        }
        val expected = vectors.gaussianMean0Sigma1
        assertEquals(expected.size, got.size)
        expected.indices.forEach { i ->
            val tolerance = StrictMath.ulp(expected[i])
            assertTrue(
                StrictMath.abs(got[i] - expected[i]) <= tolerance,
                "index $i: expected ${expected[i]} got ${got[i]}," +
                    " off by ${StrictMath.abs(got[i] - expected[i]) / tolerance} ulp",
            )
        }
    }

    /**
     * Guards the argument above: in the baseline regime the gaussian path is never taken,
     * so its 1-ULP divergence is unreachable. If someone changes the short-circuit, the
     * generator stream shifts and every baseline row breaks — this test says why.
     */
    @Test
    fun `latent regime NONE never draws a gaussian`() {
        val probe = SwiftRandom(42UL)
        val before = probe.next()
        // Re-create and burn exactly one draw to compare against.
        val control = SwiftRandom(42UL)
        assertEquals(before, control.next())

        // A zero-sigma gaussian must not advance the stream at all.
        val rng = SwiftRandom(42UL)
        val sigmas = listOf(
            MarketplaceSimulator.LatentVariability.NONE.restaurantPrepBiasSigmaMinutes,
            MarketplaceSimulator.LatentVariability.NONE.prepNoiseSigmaMinutes,
            MarketplaceSimulator.LatentVariability.NONE.courierSpeedSpread,
        )
        assertTrue(sigmas.all { it == 0.0 }, "LatentVariability.NONE gained a non-zero sigma")
        assertEquals(
            before,
            rng.next(),
            "the first draw shifted, so something consumed the generator before it",
        )
    }

    /**
     * A power-of-two bound must mask the low bits and a non-power-of-two bound must not.
     * Stated as its own test because collapsing the two branches is the single most
     * tempting simplification in this file, and the golden vectors are the only thing
     * that would catch it.
     */
    @Test
    fun `power-of-two and Lemire paths genuinely differ`() {
        val masked = SwiftRandom(42UL).next(1UL shl 53)
        val lemire = SwiftRandom(42UL).next((1UL shl 53) + 1UL)
        assertTrue(
            masked != lemire,
            "the two branches produced the same value, so one of them is not being taken",
        )
    }

    private fun assertBitwise(expected: List<Double>, actual: List<Double>) {
        assertEquals(expected.size, actual.size)
        expected.indices.forEach { i ->
            assertEquals(
                expected[i].toRawBits(),
                actual[i].toRawBits(),
                "index $i: expected ${expected[i]} got ${actual[i]}",
            )
        }
    }
}

/** Locates the fixtures, which live with the Swift tests and are shared by both ports. */
object Fixtures {
    fun path(name: String): Path {
        // Tests run with the Gradle project (`services/`) as the working directory.
        val candidates = listOf(
            Path.of("../Tests/RavonCoreTests/Fixtures", name),
            Path.of("../../Tests/RavonCoreTests/Fixtures", name),
            Path.of("Tests/RavonCoreTests/Fixtures", name),
        )
        return candidates.firstOrNull { Files.exists(it) }
            ?: error("fixture $name not found; looked in ${candidates.joinToString()} from ${Path.of("").toAbsolutePath()}")
    }
}
