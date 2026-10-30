import Foundation
@testable import Vita

extension ItemDraft {
    static func reference(_ id: String, grams: Decimal, name: String = "item", text: String = "some") -> ItemDraft {
        ItemDraft(
            displayName: name, originalAmountText: text, quantity: Quantity(amount: grams, unit: .gram),
            amountSource: .userStated, nutrition: .referenceFood(id), includeInSummary: true
        )
    }

    static func estimate(kcal: Decimal, protein: Decimal = 0, include: Bool = true) -> ItemDraft {
        ItemDraft(
            displayName: "外卖", originalAmountText: "一份", quantity: nil, amountSource: .aiEstimated,
            nutrition: .aiEstimated(NutrientValues(energyKcal: kcal, proteinG: protein, fatG: 0, carbohydrateG: 0), estimateBasis: "按一份估算"),
            includeInSummary: include
        )
    }
}

extension RecordDraft {
    static func lunch(on date: LocalDate = Fixtures.day, _ items: [ItemDraft]) throws -> RecordDraft {
        RecordDraft(
            eventTime: try EventTime(localDate: date, precision: .mealPeriod, mealPeriod: .lunch, timeZoneIdentifier: "Asia/Shanghai"),
            mealLabel: "午餐",
            items: items
        )
    }
}
