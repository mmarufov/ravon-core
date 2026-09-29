import com.google.protobuf.gradle.id

plugins {
    id("com.google.protobuf") version "0.9.5"
}

dependencies {
    api("io.grpc:grpc-protobuf:1.78.0")
    api("io.grpc:grpc-stub:1.78.0")
    api("io.grpc:grpc-kotlin-stub:1.5.0")
    api("com.google.protobuf:protobuf-kotlin:4.33.0")
    compileOnly("org.apache.tomcat:annotations-api:6.0.53")
}

// The canonical contract lives at the repository root, not inside this module. One
// `proto/` tree, versioned with the code that implements it and the clients that consume
// it — which is the point of keeping the Swift and Kotlin sides in one repo.
sourceSets.named("main") {
    proto { srcDir(rootProject.file("../proto")) }
}

protobuf {
    protoc { artifact = "com.google.protobuf:protoc:4.33.0" }
    plugins {
        id("grpc") { artifact = "io.grpc:protoc-gen-grpc-java:1.78.0" }
        id("grpckt") { artifact = "io.grpc:protoc-gen-grpc-kotlin:1.4.1:jdk8@jar" }
    }
    generateProtoTasks {
        all().forEach {
            it.plugins { id("grpc"); id("grpckt") }
            it.builtins { id("kotlin") }
        }
    }
}
