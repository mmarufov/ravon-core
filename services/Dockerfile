# syntax=docker/dockerfile:1

# ---- build ------------------------------------------------------------------
# JDK 25 rather than 21: `Libm` reaches the platform libm through the FFM API, which was
# still a preview feature in 21. Bytecode targets 21; only the runtime must be newer.
FROM eclipse-temurin:25-jdk AS build
WORKDIR /src

# Wrapper and build scripts first, so dependency resolution caches across source edits.
COPY gradlew settings.gradle.kts build.gradle.kts ./
COPY gradle ./gradle
COPY proto/build.gradle.kts ./proto/
COPY dispatch/build.gradle.kts ./dispatch/
COPY server/build.gradle.kts ./server/
RUN ./gradlew --no-daemon dependencies --quiet || true

COPY . .
# The canonical contract lives at the repository root, one level above this build
# context; see docker-build.sh, which sets the context accordingly.
RUN ./gradlew --no-daemon :server:installDist -x test

# ---- run --------------------------------------------------------------------
FROM eclipse-temurin:25-jre
WORKDIR /app
COPY --from=build /src/server/build/install/server ./

# `Libm` needs native access. Without this the JVM warns on every call today and will
# refuse outright in a later release.
#
# MaxRAMPercentage rather than a fixed -Xmx so the same image is right on a 512 MB and a
# 2 GB machine. SerialGC because at this heap size a concurrent collector costs more in
# threads than it saves in pauses.
ENV JAVA_OPTS="--enable-native-access=ALL-UNNAMED -XX:MaxRAMPercentage=75 -XX:+UseSerialGC"
ENV PORT=8080
EXPOSE 8080

# Bare `curl` is not in the JRE image; the platform health check hits /health over HTTP.
CMD ["./bin/server"]
