import Foundation

/// Hours are stored as plain "HH:mm:ss" strings interpreted in **Asia/Dushanbe** (UTC+5).
/// Server `restaurant_within_hours()` is the source of truth for "is open right now".
/// Helpers below are for UI rendering only — never for blocking decisions.
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

// MARK: - Hours helpers (UI rendering only, NOT for blocking)

public extension Array where Element == RestaurantHours {
    /// Returns the next moment the restaurant is open from `from`, looking up to `lookaheadDays` ahead.
    /// nil if no opening within the window. Honors past-midnight ranges and `isClosed=true` markers.
    /// Used to render "Откроется в…" and bound the consumer schedule picker.
    func nextOpenAt(from reference: Date = Date(), lookaheadDays: Int = 7) -> Date? {
        guard !isEmpty else { return reference }
        let tjk = TimeZone(identifier: "Asia/Dushanbe") ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tjk

        // Map dayOfWeek (0=Sun..6=Sat per DB) → row
        let byDow: [Int: RestaurantHours] = Dictionary(uniqueKeysWithValues: map { ($0.dayOfWeek, $0) })

        for offset in 0...lookaheadDays {
            guard let dayDate = cal.date(byAdding: .day, value: offset, to: reference) else { continue }
            // Swift weekday: 1=Sun..7=Sat → DB convention: subtract 1
            let dow = cal.component(.weekday, from: dayDate) - 1
            guard let row = byDow[dow], !row.isClosed else { continue }
            guard let open = parseTime(row.openingTime, on: dayDate, cal: cal) else { continue }

            if offset == 0 {
                // Today: if reference is before opening, opening; if inside the window, "open right now"; else skip
                if let close = parseTime(row.closingTime, on: dayDate, cal: cal) {
                    let inWindow: Bool = {
                        if close > open { return reference >= open && reference <= close }
                        // past-midnight: window is [open, end-of-day) ∪ [start-of-day, close)
                        let endOfDay = cal.date(bySettingHour: 23, minute: 59, second: 59, of: dayDate) ?? dayDate
                        let startOfDay = cal.startOfDay(for: dayDate)
                        return (reference >= open && reference <= endOfDay)
                            || (reference >= startOfDay && reference <= close)
                    }()
                    if inWindow { return reference }
                    if reference < open { return open }
                    // already closed today — try tomorrow
                    continue
                }
                if reference < open { return open }
                continue
            }
            return open
        }
        return nil
    }

    private func parseTime(_ s: String, on day: Date, cal: Calendar) -> Date? {
        // s is "HH:mm:ss" in Asia/Dushanbe
        let parts = s.split(separator: ":")
        guard parts.count >= 2,
              let h = Int(parts[0]),
              let m = Int(parts[1]) else { return nil }
        let sec = parts.count >= 3 ? (Int(parts[2]) ?? 0) : 0
        return cal.date(bySettingHour: h, minute: m, second: sec, of: day)
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
