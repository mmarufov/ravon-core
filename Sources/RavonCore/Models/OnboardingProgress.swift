import Foundation

public struct OnboardingProgress: Sendable {
    public let hasRestaurant: Bool
    public let hasName: Bool
    public let hasAddress: Bool
    public let hasAtLeastOneCategory: Bool
    public let hasAtLeastOneMenuItem: Bool
    public let hasHoursConfigured: Bool

    public var isReadyToGoLive: Bool {
        hasRestaurant && hasName && hasAddress &&
        hasAtLeastOneCategory && hasAtLeastOneMenuItem && hasHoursConfigured
    }

    public var completionPercentage: Double {
        let checks = [hasRestaurant, hasName, hasAddress,
                      hasAtLeastOneCategory, hasAtLeastOneMenuItem, hasHoursConfigured]
        return Double(checks.filter { $0 }.count) / Double(checks.count)
    }

    public init(
        hasRestaurant: Bool = false, hasName: Bool = false,
        hasAddress: Bool = false, hasAtLeastOneCategory: Bool = false,
        hasAtLeastOneMenuItem: Bool = false, hasHoursConfigured: Bool = false
    ) {
        self.hasRestaurant = hasRestaurant
        self.hasName = hasName
        self.hasAddress = hasAddress
        self.hasAtLeastOneCategory = hasAtLeastOneCategory
        self.hasAtLeastOneMenuItem = hasAtLeastOneMenuItem
        self.hasHoursConfigured = hasHoursConfigured
    }
}
