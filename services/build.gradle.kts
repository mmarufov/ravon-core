plugins {
    kotlin("jvm") version "2.4.0" apply false
}

subprojects {
    apply(plugin = "org.jetbrains.kotlin.jvm")

    repositories { mavenCentral() }

    // Reproducibility is the whole point of this module: the dispatch port is verified
    // bit-for-bit against a fixture recorded from the Swift original, so the JVM stays
    // boring. `StrictMath` is used in the numeric paths rather than `Math` because the
    // latter may use platform intrinsics that differ in the last bits.
    //
    // No `jvmToolchain(...)` pin: the toolchain that happens to be installed is used, and
    // the fixture test is what proves the result is unaffected by which one. Pin this
    // once CI's JDK is fixed.
    extensions.configure<org.jetbrains.kotlin.gradle.dsl.KotlinJvmProjectExtension>("kotlin") {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_21)
            freeCompilerArgs.add("-Xjdk-release=21")
        }
    }

    tasks.withType<JavaCompile>().configureEach {
        options.release.set(21)
    }

    tasks.withType<Test>().configureEach {
        useJUnitPlatform()
        testLogging { events("passed", "failed", "skipped") }
        // `Libm` reaches the platform libm through the FFM API so the port's
        // transcendentals match Swift's bit-for-bit. Without this the JVM prints a
        // warning on every run and will refuse outright in a future release.
        jvmArgs("--enable-native-access=ALL-UNNAMED")
    }
}
