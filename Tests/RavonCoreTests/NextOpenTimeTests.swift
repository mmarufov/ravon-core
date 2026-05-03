import Testing
import Foundation
@testable import RavonCore

@Suite("RestaurantHours.nextOpenAt")
struct NextOpenAtTests {
    private func tjkCal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Dushanbe")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        var dc = DateComponents()
        dc.year = y; dc.month = m; dc.day = d; dc.hour = h; dc.minute = min
        dc.timeZone = TimeZone(identifier: "Asia/Dushanbe")
        return Calendar(identifier: .gregorian).date(from: dc)!
    }

    private func hours(dow: Int, open: String, close: String, isClosed: Bool = false) -> RestaurantHours {
        RestaurantHours(
            id: UUID(), restaurantId: UUID(),
            dayOfWeek: dow, openingTime: open, closingTime: close, isClosed: isClosed
        )
    }

    @Test("Empty hours = always open (returns reference time)")
    func empty() {
        let ref = date(2026, 5, 3, 3, 0)
        let result = ([] as [RestaurantHours]).nextOpenAt(from: ref)
        #expect(result == ref)
    }

    @Test("Inside today's window returns reference (already open)")
    func insideWindow() {
        // Sunday May 3 2026, 12:00 TJK; restaurant open 09:00–22:00 on Sunday (dow=0)
        let ref = date(2026, 5, 3, 12, 0)
        let h = [hours(dow: 0, open: "09:00:00", close: "22:00:00")]
        let result = h.nextOpenAt(from: ref)
        #expect(result == ref)
    }

    @Test("Before today's opening returns today's opening")
    func beforeOpen() {
        // Sunday 03:00 TJK; opens at 09:00 today
        let ref = date(2026, 5, 3, 3, 0)
        let h = [hours(dow: 0, open: "09:00:00", close: "22:00:00")]
        let result = h.nextOpenAt(from: ref)
        let expected = date(2026, 5, 3, 9, 0)
        #expect(result == expected)
    }

    @Test("After today's closing returns tomorrow's opening")
    func afterClose() {
        // Sunday 23:00 TJK; closed; tomorrow (Mon dow=1) opens at 09:00
        let ref = date(2026, 5, 3, 23, 0)
        let h = [
            hours(dow: 0, open: "09:00:00", close: "22:00:00"),
            hours(dow: 1, open: "09:00:00", close: "22:00:00")
        ]
        let result = h.nextOpenAt(from: ref)
        let expected = date(2026, 5, 4, 9, 0)
        #expect(result == expected)
    }

    @Test("Past-midnight window: 18:00–02:00, ref at 23:00 → currently open")
    func pastMidnightCurrent() {
        // Sunday 23:00 TJK; window 18:00–02:00 → in window
        let ref = date(2026, 5, 3, 23, 0)
        let h = [hours(dow: 0, open: "18:00:00", close: "02:00:00")]
        let result = h.nextOpenAt(from: ref)
        #expect(result == ref)
    }

    @Test("Past-midnight window: 18:00–02:00, ref at 01:30 (early Mon, but Sunday window) → open")
    func pastMidnightEarly() {
        // Monday 01:30 TJK — Sunday's window extends to Mon 02:00; today (Mon) needs its own row
        // For this test: restaurant has BOTH Sunday and Monday rows with same window
        let ref = date(2026, 5, 4, 1, 30)
        let h = [
            hours(dow: 0, open: "18:00:00", close: "02:00:00"),
            hours(dow: 1, open: "18:00:00", close: "02:00:00")
        ]
        let result = h.nextOpenAt(from: ref)
        #expect(result == ref) // Mon 01:30 is inside Mon's [18:00, 02:00) window per past-midnight rule
    }

    @Test("Closed-day marker: skips that day")
    func closedDay() {
        // Sunday explicitly closed; Mon opens at 09:00
        let ref = date(2026, 5, 3, 12, 0)
        let h = [
            hours(dow: 0, open: "00:00:00", close: "00:00:00", isClosed: true),
            hours(dow: 1, open: "09:00:00", close: "22:00:00")
        ]
        let result = h.nextOpenAt(from: ref)
        let expected = date(2026, 5, 4, 9, 0)
        #expect(result == expected)
    }

    @Test("All week closed within lookahead returns nil")
    func allClosed() {
        let ref = date(2026, 5, 3, 12, 0)
        let h = (0...6).map { hours(dow: $0, open: "00:00:00", close: "00:00:00", isClosed: true) }
        let result = h.nextOpenAt(from: ref, lookaheadDays: 7)
        #expect(result == nil)
    }
}
