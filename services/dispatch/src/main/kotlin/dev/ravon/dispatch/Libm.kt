package dev.ravon.dispatch

import java.lang.foreign.FunctionDescriptor
import java.lang.foreign.Linker
import java.lang.foreign.ValueLayout
import java.lang.invoke.MethodHandle

/**
 * The platform's C `libm`, reached through the FFM API.
 *
 * **Why this exists, and why `Math`/`StrictMath` will not do.**
 *
 * The dispatch port is verified against a baseline recorded from the Swift engine, and
 * Swift's `sin`/`cos`/`atan2`/`log` are the platform libm. The JVM's are not. Measured
 * over 600 bearings drawn from `SwiftRandom(1)` the way the simulator draws them, on macOS
 * (pinned by `LibmDisagreementTest`, which asserts these exact counts):
 *
 * | implementation | bitwise disagreement with platform libm |
 * |---|---|
 * | `Math.sin` or `Math.cos` | **20.3 %** of inputs (122 / 600) |
 * | `Math.sin` alone | 11.5 % (69 / 600) |
 * | `StrictMath.sin` or `StrictMath.cos` | 9.0 % (54 / 600) |
 * | this, native libm via FFM | **0 %** by construction |
 *
 * Those disagreements are one or two units in the last place, which sounds ignorable and
 * is not: the simulator feeds them into a cost comparison, and a 1-ULP flip near a tie
 * changes which courier wins an assignment. Routing these four functions through
 * `java.lang.Math` instead leaves seed 1 bit-identical but breaks **91** baseline fields
 * across other seeds (`StrictMath`: 87), including `ordersAssigned` off by one on seeds 4,
 * 6 and 9. So last-bit fidelity here is not pedantry: it is the difference between a port
 * that reproduces the baseline and one that merely resembles it.
 *
 * (The "109 assigned against the recorded 110 on seed 1" failure is a different bug, the
 * time base, not libm. See [DispatchClock].)
 *
 * **The trade this makes explicit.** Bit-exactness is now a property of the *platform*
 * libm, not of the JVM. On macOS this is the same libm Swift used to record the fixture,
 * so the match is exact. On a different libm (glibc, musl) the results may differ again,
 * and the baseline test would have to be re-recorded there. That is an acceptable
 * boundary because the Swift suite is macOS-only too — `.github/workflows/ci.yml` runs it
 * on `macos-15` — so both halves of the comparison live on the same platform. It is
 * recorded here rather than discovered later.
 *
 * `sqrt` is deliberately **not** here: IEEE-754 requires it to be correctly rounded, so
 * `Math.sqrt` is exact everywhere and an FFM downcall would only cost time.
 */
internal object Libm {

    private val linker: Linker = Linker.nativeLinker()
    private val lookup = linker.defaultLookup()

    private val unary = FunctionDescriptor.of(ValueLayout.JAVA_DOUBLE, ValueLayout.JAVA_DOUBLE)
    private val binary = FunctionDescriptor.of(
        ValueLayout.JAVA_DOUBLE, ValueLayout.JAVA_DOUBLE, ValueLayout.JAVA_DOUBLE
    )

    private fun handle(name: String, descriptor: FunctionDescriptor): MethodHandle =
        linker.downcallHandle(
            lookup.find(name).orElseThrow { IllegalStateException("libm symbol '$name' not found") },
            descriptor,
        )

    private val SIN = handle("sin", unary)
    private val COS = handle("cos", unary)
    private val LOG = handle("log", unary)
    private val ATAN2 = handle("atan2", binary)

    fun sin(x: Double): Double = SIN.invokeExact(x) as Double
    fun cos(x: Double): Double = COS.invokeExact(x) as Double
    fun log(x: Double): Double = LOG.invokeExact(x) as Double
    fun atan2(y: Double, x: Double): Double = ATAN2.invokeExact(y, x) as Double

    /** Correctly rounded by IEEE-754, so the JVM's is already exact. */
    fun sqrt(x: Double): Double = Math.sqrt(x)
}
