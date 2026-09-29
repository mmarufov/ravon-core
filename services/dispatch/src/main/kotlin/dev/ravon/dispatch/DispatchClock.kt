package dev.ravon.dispatch

/**
 * The engine's time base, and the one place that knows how to convert into it.
 *
 * **Why the engine does not simply use Unix seconds.** The dispatch cost model is pinned
 * bit-for-bit to a baseline recorded from the Swift original, and Swift's `Date` stores
 * `timeIntervalSinceReferenceDate` — seconds since 2001-01-01, not 1970. So the original
 * performs its elapsed-time arithmetic on values around 7.2e8, and a double has different
 * residual precision there than at 1.7e9 (~1.2e-7 s versus ~2.4e-7 s).
 *
 * That is not a rounding curiosity. Computing the same quantities in Unix seconds
 * produced costs that differed in the ninth decimal, which was enough to flip a greedy
 * tie and lose exactly one assignment on the very first seed of the baseline. The
 * conversion is load-bearing.
 *
 * Every boundary that accepts a wall-clock instant — the gRPC layer, tests, any future
 * caller — converts here rather than open-coding the offset, so there is one definition
 * to be wrong rather than several to disagree.
 */
object DispatchClock {

    /** Seconds between 1970-01-01 and 2001-01-01. */
    const val UNIX_TO_REFERENCE_DATE: Long = 978_307_200L

    /** Convert seconds-since-1970 into the engine's time base. */
    fun fromUnixSeconds(seconds: Double): Double = seconds - UNIX_TO_REFERENCE_DATE

    /** Convert a protobuf-style (seconds, nanos) Unix instant into the engine's base. */
    fun fromUnix(seconds: Long, nanos: Int): Double =
        (seconds - UNIX_TO_REFERENCE_DATE).toDouble() + nanos / 1_000_000_000.0

    /** Convert the engine's time base back to seconds-since-1970. */
    fun toUnixSeconds(referenceSeconds: Double): Double = referenceSeconds + UNIX_TO_REFERENCE_DATE
}
