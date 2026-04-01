import Foundation

public struct MerchantStats: Codable, Sendable {
    public let todayOrderCount: Int
    public let todayRevenue: Double
    public let averageOrderValue: Double
    public let activeOrderCount: Int

    public init(
        todayOrderCount: Int, todayRevenue: Double,
        averageOrderValue: Double, activeOrderCount: Int
    ) {
        self.todayOrderCount = todayOrderCount
        self.todayRevenue = todayRevenue
        self.averageOrderValue = averageOrderValue
        self.activeOrderCount = activeOrderCount
    }

    enum CodingKeys: String, CodingKey {
        case todayOrderCount = "today_order_count"
        case todayRevenue = "today_revenue"
        case averageOrderValue = "average_order_value"
        case activeOrderCount = "active_order_count"
    }
}
