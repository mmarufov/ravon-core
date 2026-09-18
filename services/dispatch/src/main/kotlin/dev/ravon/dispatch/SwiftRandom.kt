package dev.ravon.dispatch

/**
 * Bit-exact reimplementation of the Swift simulator's random number generation.
 *
 * Porting the generator is the easy half: `SeededRNG` in MarketplaceSimulator.swift is
 * SplitMix64, written out by hand, and it maps to `ULong` arithmetic directly.
 *
 * The hard half — and the thing that decides whether this port reproduces the recorded
 * baseline at all — is Swift's *mapping* from 64 raw bits into a range. It is not a
 * modulo, it is not uniform-by-luck, and the closed-range and half-open-range forms
 * differ. Both were reverse-engineered against
 * `Tests/RavonCoreTests/Fixtures/dispatch-rng-golden-vectors.json` and the findings are:
 *
 *  - `next(upperBound:)` takes a **power-of-two fast path** that masks the low bits,
 *    and otherwise uses **Lemire's "nearly divisionless" method** returning the high
 *    word of a 128-bit product. Using one algorithm for both cases fails: five vectors
 *    match Lemire and the sixth (whose bound is exactly 2^53) only matches the mask.
 *  - `Double.random(in: a...b)` draws with `upperBound = 2^53 + 1`, which is *not* a
 *    power of two, so it goes through Lemire.
 *  - `Double.random(in: a..<b)` draws with `upperBound = 2^53`, which *is*, so it masks.
 *
 * Do not "simplify" any of this, and do not substitute `kotlin.random.Random`. Every
 * line here is pinned by [SwiftRandomGoldenVectorTest].
 */
class SwiftRandom(seed: ULong) {

    private var state: ULong = seed

    /** SplitMix64 — MarketplaceSimulator.swift:16-27, transcribed. */
    fun next(): ULong {
        state += 0x9E3779B97F4A7C15UL
        var z = state
        z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9UL
        z = (z xor (z shr 27)) * 0x94D049BB133111EBUL
        return z xor (z shr 31)
    }

    /**
     * Swift stdlib `RandomNumberGenerator.next(upperBound:)`.
     *
     * The power-of-two branch is load-bearing, not an optimisation: it produces a
     * different value from Lemire for the same input, and `Double.random(in: a..<b)`
     * depends on it.
     */
    fun next(upperBound: ULong): ULong {
        require(upperBound != 0UL) { "upperBound cannot be zero" }
        if (upperBound and (upperBound - 1UL) == 0UL) {
            return next() and (upperBound - 1UL)
        }
        var random = next()
        var high = unsignedMultiplyHigh(random, upperBound)
        var low = random * upperBound
        if (low < upperBound) {
            // (0 - upperBound) % upperBound, in unsigned arithmetic.
            val t = (0UL - upperBound) % upperBound
            while (low < t) {
                random = next()
                high = unsignedMultiplyHigh(random, upperBound)
                low = random * upperBound
            }
        }
        return high
    }

    private fun unsignedMultiplyHigh(a: ULong, b: ULong): ULong =
        java.lang.Math.unsignedMultiplyHigh(a.toLong(), b.toLong()).toULong()

    /** `Double.random(in: lower...upper, using:)`. */
    fun nextDoubleClosed(lower: Double, upper: Double): Double {
        val delta = upper - lower
        val rand = next(MAX_SIGNIFICAND + 1UL)
        return rand.toDouble() * (delta / MAX_SIGNIFICAND.toDouble()) + lower
    }

    /** `Double.random(in: lower..<upper, using:)`. */
    fun nextDoubleHalfOpen(lower: Double, upper: Double): Double {
        val delta = upper - lower
        val rand = next(MAX_SIGNIFICAND)
        return rand.toDouble() * (delta / MAX_SIGNIFICAND.toDouble()) + lower
    }

    /** `Int.random(in: 0..<upperBound, using:)`. */
    fun nextIntHalfOpen(upperBound: Int): Int {
        require(upperBound > 0)
        return next(upperBound.toULong()).toInt()
    }

    private companion object {
        /** `1 << (Double.significandBitCount + 1)` = 2^53. */
        val MAX_SIGNIFICAND: ULong = 1UL shl 53
    }
}
