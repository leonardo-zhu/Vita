import Foundation
import Testing
@testable import Vita

struct EventTimeTests {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    @Test func localDateRoundTripsIsoString() throws {
        let date = try #require(LocalDate(isoString: "2026-09-17"))
        #expect(date.isoString == "2026-09-17")
        #expect(LocalDate(isoString: "2026-02-30") == nil)
        #expect(LocalDate(isoString: "2026-9-17") == nil)
    }

    @Test func localDateIsDerivedInGivenTimeZone() {
        // 2026-09-17 17:00 UTC 在上海已是 18 日。
        let instant = Date(timeIntervalSince1970: 1_789_664_400)
        #expect(LocalDate(date: instant, timeZone: TimeZone(identifier: "UTC")!).isoString == "2026-09-17")
        #expect(LocalDate(date: instant, timeZone: shanghai).isoString == "2026-09-18")
    }

    @Test func mealPeriodDoesNotCarryFakeTimestamp() throws {
        let day = try #require(LocalDate(isoString: "2026-09-17"))
        let time = try EventTime(
            localDate: day, precision: .mealPeriod, mealPeriod: .lunch,
            timeZoneIdentifier: shanghai.identifier
        )
        #expect(time.timestamp == nil)
        #expect(throws: EventTimeError.unexpectedTimestamp(.mealPeriod)) {
            try EventTime(
                localDate: day, precision: .mealPeriod, timestamp: Date(), mealPeriod: .lunch,
                timeZoneIdentifier: shanghai.identifier
            )
        }
        #expect(throws: EventTimeError.missingMealPeriod) {
            try EventTime(localDate: day, precision: .mealPeriod, timeZoneIdentifier: shanghai.identifier)
        }
    }

    @Test func exactRequiresTimestampInsideLocalDate() throws {
        let day = try #require(LocalDate(isoString: "2026-09-17"))
        #expect(throws: EventTimeError.missingTimestamp(.exact)) {
            try EventTime(localDate: day, precision: .exact, timeZoneIdentifier: shanghai.identifier)
        }
        let otherDay = Date(timeIntervalSince1970: 1_789_664_400 + 86_400 * 3)
        #expect(throws: EventTimeError.timestampOutsideLocalDate) {
            try EventTime(
                localDate: day, precision: .exact, timestamp: otherDay,
                timeZoneIdentifier: shanghai.identifier
            )
        }
    }

    @Test func defaultedEntryTimeStaysInsideHistoricalSession() throws {
        let sessionDate = try #require(LocalDate(isoString: "2026-09-10"))
        let now = Date(timeIntervalSince1970: 1_789_664_400) // 2026-09-18 01:00 上海
        let time = try EventTime.defaultedEntryTime(sessionDate: sessionDate, now: now, timeZone: shanghai)
        #expect(time.precision == .defaultedEntryTime)
        #expect(time.localDate == sessionDate)
        let stamp = try #require(time.timestamp)
        #expect(LocalDate(date: stamp, timeZone: shanghai) == sessionDate)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghai
        #expect(calendar.component(.hour, from: stamp) == calendar.component(.hour, from: now))
    }

    @Test func codableRoundTrip() throws {
        let day = try #require(LocalDate(isoString: "2026-09-17"))
        let original = try EventTime(
            localDate: day, precision: .dateOnly, timeZoneIdentifier: shanghai.identifier
        )
        let decoded = try JSONDecoder().decode(EventTime.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }
}
