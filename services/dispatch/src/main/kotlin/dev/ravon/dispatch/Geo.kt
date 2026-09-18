package dev.ravon.dispatch

/**
 * A point on the earth. Dushanbe sits near 38.56°N, 68.79°E.
 *
 * Port of Sources/RavonCore/Dispatch/Geo.swift.
 */
data class GeoPoint(val latitude: Double, val longitude: Double) {

    /**
     * Great-circle distance in kilometres (Haversine).
     *
     * A planar approximation would be tolerable across a single city, but dispatch cost
     * is compared *between* candidate pairs — a consistent bias is fine, an inconsistent
     * one silently reorders the matching.
     *
     * The arithmetic is transcribed in the original's exact order. Floating-point
     * addition is not associative, so `sin(x) * sin(x)` is not interchangeable with
     * `sin(x).pow(2)`, and `atan2(sqrt(a), sqrt(1 - a))` is not interchangeable with
     * `asin(sqrt(a))`. Transcendentals go through [Libm] rather than `Math` or
     * `StrictMath`; see that file for the measurement that forced it.
     */
    fun distanceKm(other: GeoPoint): Double {
        val earthRadiusKm = 6371.0088
        val dLat = (other.latitude - latitude) * Math.PI / 180
        val dLon = (other.longitude - longitude) * Math.PI / 180
        val lat1 = latitude * Math.PI / 180
        val lat2 = other.latitude * Math.PI / 180

        val a = Libm.sin(dLat / 2) * Libm.sin(dLat / 2) +
            Libm.sin(dLon / 2) * Libm.sin(dLon / 2) *
            Libm.cos(lat1) * Libm.cos(lat2)
        return 2 * earthRadiusKm * Libm.atan2(Libm.sqrt(a), Libm.sqrt(1 - a))
    }
}
