import Foundation
import Testing
@testable import Vita

struct LocalDateArithmeticTests {
    @Test func addsDaysAcrossMonthAndYearEnds() {
        #expect(LocalDate(isoString: "2026-10-31")!.adding(days: 1).isoString == "2026-11-01")
        #expect(LocalDate(isoString: "2026-12-31")!.adding(days: 1).isoString == "2027-01-01")
        #expect(LocalDate(isoString: "2026-03-01")!.adding(days: -1).isoString == "2026-02-28")
    }

    @Test func weekStartsOnMonday() {
        // 2026-10-31 是周六，2026-11-01 是周日，2026-10-26 是周一。
        #expect(LocalDate(isoString: "2026-10-31")!.startOfWeek.isoString == "2026-10-26")
        #expect(LocalDate(isoString: "2026-11-01")!.startOfWeek.isoString == "2026-10-26")
        #expect(LocalDate(isoString: "2026-10-26")!.startOfWeek.isoString == "2026-10-26")
    }
}

@MainActor
struct WeekDataTests {
    @Test func averagesOnlyRecordedDays() throws {
        let services = AppServices(container: try AppContainer.inMemory(), now: { Fixtures.now }, timeZone: { Fixtures.shanghai })
        let thursday = LocalDate(isoString: "2026-10-29")!
        try services.records.createRecord(on: thursday, expectedRevision: 0, draft: try .lunch(on: thursday, [.estimate(kcal: 1000, protein: 60)]))
        try services.records.createRecord(on: Fixtures.day, expectedRevision: 0, draft: try .lunch([.estimate(kcal: 2000, protein: 100)]))

        let week = try services.dayData.week(containing: Fixtures.day)
        #expect(week.days.count == 7)
        #expect(week.start.isoString == "2026-10-26")
        #expect(week.end.isoString == "2026-11-01")
        #expect(week.recordedDays.count == 2)
        #expect(week.average(.energyKcal) == 1500)
        #expect(week.average(.proteinG) == 80)
    }

    @Test func mealSlotFollowsPeriodOrClockTime() throws {
        let lunch = try EventTime(localDate: Fixtures.day, precision: .mealPeriod, mealPeriod: .lunch, timeZoneIdentifier: "Asia/Shanghai")
        #expect(MealSlot(lunch).period == .lunch)
        // Fixtures.now 是上海 20:00。
        let evening = try EventTime(localDate: Fixtures.day, precision: .exact, timestamp: Fixtures.now, timeZoneIdentifier: "Asia/Shanghai")
        #expect(MealSlot(evening).period == .dinner)
        let dateOnly = try EventTime(localDate: Fixtures.day, precision: .dateOnly, timeZoneIdentifier: "Asia/Shanghai")
        #expect(MealSlot(dateOnly).period == .other)
    }
}
