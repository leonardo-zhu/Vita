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
    @Test func averagesOnlyRecordedDays() async throws {
        let stub = APIStub()
        let monday = Fixtures.day.startOfWeek
        for offset in 0..<7 {
            let date = monday.adding(days: offset).isoString
            switch date {
            case "2026-10-29": stub.on("GET", "/v1/days/\(date)", json: APIFixtures.day(date, kcal: 1000, protein: 60))
            case Fixtures.day.isoString: stub.on("GET", "/v1/days/\(date)", json: APIFixtures.day(date, kcal: 2000, protein: 100))
            default: stub.on("GET", "/v1/days/\(date)", json: APIFixtures.emptyDay(date))
            }
        }
        let service = DayDataService(api: stub.client())

        let week = try await service.week(containing: Fixtures.day)
        #expect(week.days.count == 7)
        #expect(week.start.isoString == "2026-10-26")
        #expect(week.end.isoString == "2026-11-01")
        #expect(week.days.map(\.date) == (0..<7).map { monday.adding(days: $0) })
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
