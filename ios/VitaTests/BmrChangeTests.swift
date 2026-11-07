import Foundation
import Testing
@testable import Vita

@MainActor
struct BmrChangeTests {
    @Test func decodesTheDaysBmrChange() async throws {
        let stub = APIStub()
        let json = APIFixtures.day("2026-10-30", kcal: 650).replacingOccurrences(of: #""balance":null"#, with: """
        "balance":null,"bmrChange":{"date":"2026-10-30","changedAt":"2026-10-30T01:12:00.000Z","previousBmrKcal":1701.8,"bmrKcal":1689.3,
        "reason":"weighing","weightKg":72.05,"heightCm":175,"ageYears":26,"sex":"male"}
        """)
        stub.on("GET", "/v1/days/2026-10-30", json: json)
        let day = try await DayDataService(api: stub.client()) { _ in nil }.day(Fixtures.day)
        let change = try #require(day.summary.bmrChange)
        #expect(change.reason == .weighing)
        let n = { DisplayFormat.number($0, digits: 0) }
        #expect(change.note == "称重 \(DisplayFormat.number(72.05, digits: 1)) kg，基础代谢 \(n(1701.8)) → \(n(1689.3))")
        #expect(change.note.contains("72.1 kg"))
    }

    @Test func olderServersWithoutTheFieldStillDecode() async throws {
        let stub = APIStub()
        stub.on("GET", "/v1/days/2026-10-30", json: APIFixtures.day("2026-10-30", kcal: 650))
        let day = try await DayDataService(api: stub.client()) { _ in nil }.day(Fixtures.day)
        #expect(day.summary.bmrChange == nil)
    }

    @Test func unknownReasonsStillShowTheChange() {
        let change = BmrChange(previousBmrKcal: 1700, bmrKcal: 1690, reason: BmrChange.Reason(rawValue: "somethingNew"), weightKg: 72)
        #expect(change.note == "基础代谢 \(DisplayFormat.number(1700, digits: 0)) → \(DisplayFormat.number(1690, digits: 0))")
    }
}
