# syntax=docker/dockerfile:1
#
# Build context is the REPOSITORY ROOT, not services/.
#
# The Gradle `proto` module reads the canonical contract from `../proto` — one proto tree,
# versioned alongside both the Kotlin that implements it and the Swift that consumes it.
# So the image has to see both directories. Deploy with:
#
#     fly deploy --config services/fly.toml --dockerfile services/Dockerfile
#
# run from the repository root.

# ---- build ------------------------------------------------------------------
# JDK 25 rather than 21: `Libm` reaches the platform libm through the FFM API, which was
# still a preview feature in 21. Bytecode targets 21; only the runtime must be newer.
FROM eclipse-temurin:25-jdk AS build
WORKDIR /src

# Wrapper and build scripts first, so dependency resolution caches across source edits.
COPY services/gradlew services/settings.gradle.kts services/build.gradle.kts ./services/
COPY services/gradle ./services/gradle
COPY services/proto/build.gradle.kts ./services/proto/
COPY services/dispatch/build.gradle.kts ./services/dispatch/
COPY services/server/build.gradle.kts ./services/server/
RUN cd services && ./gradlew --no-daemon --quiet dependencies > /dev/null 2>&1 || true

COPY proto ./proto
COPY services ./services
RUN cd services && ./gradlew --no-daemon :server:installDist -x test

# ---- run --------------------------------------------------------------------
FROM eclipse-temurin:25-jre
WORKDIR /app
COPY --from=build /src/services/server/build/install/server ./

# `Libm` needs native access. Without this the JVM warns on every call today and will
# refuse outright in a later release.
#
# MaxRAMPercentage rather than a fixed -Xmx, so the same image is right on a 512 MB and a
# 2 GB machine. SerialGC because at this heap size a concurrent collector costs more in
# threads than it saves in pauses.
ENV JAVA_OPTS="--enable-native-access=ALL-UNNAMED -XX:MaxRAMPercentage=75 -XX:+UseSerialGC"
ENV PORT=8080
EXPOSE 8080

CMD ["./bin/server"]
