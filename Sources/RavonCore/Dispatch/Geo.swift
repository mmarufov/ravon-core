import Foundation

/// A point on the earth. Dushanbe sits near 38.56°N, 68.79°E.
public struct GeoPoint: Sendable, Hashable, Codable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Great-circle distance in kilometres (Haversine).
    ///
    /// Planar approximation would be tolerable across a single city, but dispatch cost
    /// is compared *between* candidate pairs — a consistent bias is fine, an
    /// inconsistent one silently reorders the matching. Haversine costs a few
    /// trigonometric calls and removes the question.
    public func distanceKm(to other: GeoPoint) -> Double {
        let earthRadiusKm = 6371.0088
        let dLat = (other.latitude - latitude) * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180

        let a = sin(dLat / 2) * sin(dLat / 2)
            + sin(dLon / 2) * sin(dLon / 2) * cos(lat1) * cos(lat2)
        return 2 * earthRadiusKm * atan2(sqrt(a), sqrt(1 - a))
    }
}
