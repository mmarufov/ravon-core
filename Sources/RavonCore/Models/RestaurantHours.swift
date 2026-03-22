import Foundation

public struct RestaurantHours: Codable, Identifiable, Sendable {
    public let id: UUID
    public let restaurantId: UUID
    public let dayOfWeek: Int
    public let openingTime: String
    public let closingTime: String
    public let isClosed: Bool

    public init(
        id: UUID, restaurantId: UUID, dayOfWeek: Int,
        openingTime: String, closingTime: String, isClosed: Bool
    ) {
        self.id = id
        self.restaurantId = restaurantId
        self.dayOfWeek = dayOfWeek
        self.openingTime = openingTime
        self.closingTime = closingTime
        self.isClosed = isClosed
    }

    enum CodingKeys: String, CodingKey {
        case id
        case restaurantId = "restaurant_id"
        case dayOfWeek = "day_of_week"
        case openingTime = "opening_time"
        case closingTime = "closing_time"
        case isClosed = "is_closed"
    }

    public var dayName: String {
        switch dayOfWeek {
        case 0: return "Воскресенье"
        case 1: return "Понедельник"
        case 2: return "Вторник"
        case 3: return "Среда"
        case 4: return "Четверг"
        case 5: return "Пятница"
        case 6: return "Суббота"
        default: return ""
        }
    }
}

public struct RestaurantHoursUpsert: Encodable, Sendable {
    public let restaurantId: UUID
    public let dayOfWeek: Int
    public let openingTime: String
    public let closingTime: String
    public let isClosed: Bool

    public init(
        restaurantId: UUID, dayOfWeek: Int,
        openingTime: String, closingTime: String, isClosed: Bool
    ) {
        self.restaurantId = restaurantId
        self.dayOfWeek = dayOfWeek
        self.openingTime = openingTime
        self.closingTime = closingTime
        self.isClosed = isClosed
    }

    enum CodingKeys: String, CodingKey {
        case restaurantId = "restaurant_id"
        case dayOfWeek = "day_of_week"
        case openingTime = "opening_time"
        case closingTime = "closing_time"
        case isClosed = "is_closed"
    }
}
