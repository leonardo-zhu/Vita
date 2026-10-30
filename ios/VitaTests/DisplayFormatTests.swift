import Foundation
import Testing
@testable import Vita

struct DisplayFormatTests {
    @Test func displayRoundingMatchesTDD() {
        #expect(DisplayFormat.energy(dec("154.5")) == "155 kcal")
        #expect(DisplayFormat.grams(dec("13.608")) == "13.6 g")
        #expect(DisplayFormat.grams(dec("0.25")) == "0.3 g")
    }

    @Test func eventTimeKeepsOriginalPrecision() throws {
        let lunch = try EventTime(localDate: Fixtures.day, precision: .mealPeriod, mealPeriod: .lunch, timeZoneIdentifier: "Asia/Shanghai")
        let dateOnly = try EventTime(localDate: Fixtures.day, precision: .dateOnly, timeZoneIdentifier: "Asia/Shanghai")
        #expect(DisplayFormat.eventTime(lunch) == "午餐")
        #expect(DisplayFormat.eventTime(dateOnly) == "时间未说明")
    }
}
