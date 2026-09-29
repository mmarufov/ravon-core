plugins { application }

dependencies {
    implementation(project(":proto"))
    implementation(project(":dispatch"))
    implementation("com.linecorp.armeria:armeria:1.34.1")
    implementation("com.linecorp.armeria:armeria-grpc:1.34.1")
    implementation("ch.qos.logback:logback-classic:1.5.20")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")

    testImplementation(kotlin("test"))
    testImplementation("org.junit.jupiter:junit-jupiter:5.14.0")
    testImplementation("com.linecorp.armeria:armeria-junit5:1.34.1")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

application { mainClass.set("dev.ravon.server.MainKt") }
