import Foundation
import Testing
@testable import Vita

struct UnitNormalizerTests {
    @Test func convertsMassAndVolumeUnits() throws {
        #expect(try UnitNormalizer.normalize(amount: dec("0.5"), unit: "kg") == Quantity(amount: 500, unit: .gram))
        #expect(try UnitNormalizer.normalize(amount: 1, unit: "斤") == Quantity(amount: 500, unit: .gram))
        #expect(try UnitNormalizer.normalize(amount: 2, unit: "两") == Quantity(amount: 100, unit: .gram))
        #expect(try UnitNormalizer.normalize(amount: 250, unit: "mg") == Quantity(amount: dec("0.25"), unit: .gram))
        #expect(try UnitNormalizer.normalize(amount: dec("1.5"), unit: "L") == Quantity(amount: 1500, unit: .milliliter))
        #expect(try UnitNormalizer.normalize(amount: 200, unit: " 毫升 ") == Quantity(amount: 200, unit: .milliliter))
    }

    @Test func rejectsCountUnitsAndNonPositiveAmounts() {
        #expect(throws: UnitNormalizationError.unsupportedUnit("个")) { try UnitNormalizer.normalize(amount: 2, unit: "个") }
        #expect(throws: UnitNormalizationError.nonPositiveAmount) { try UnitNormalizer.normalize(amount: 0, unit: "g") }
    }
}

struct NutritionCalculatorTests {
    private let per100g = NutrientValues(energyKcal: 143, proteinG: dec("12.6"), fatG: dec("9.5"), carbohydrateG: dec("0.7"))

    @Test func scalesBasisByQuantityInDecimal() throws {
        let snapshot = try NutritionCalculator.snapshot(
            source: .referenceFood, sourceRef: "egg",
            basisQuantity: Quantity(amount: 100, unit: .gram), basisNutrients: per100g,
            quantity: Quantity(amount: 108, unit: .gram)
        )
        #expect(snapshot.values.energyKcal == dec("154.44"))
        #expect(snapshot.values.proteinG == dec("13.608"))
        #expect(snapshot.values.fatG == dec("10.26"))
        #expect(snapshot.computedBy == .client)
        #expect(snapshot.quantityUsed == Quantity(amount: 108, unit: .gram))
    }

    @Test func convertsVolumeOnlyWithDensity() throws {
        let basis = Quantity(amount: 100, unit: .gram)
        #expect(throws: NutritionCalculationError.unitMismatch(basis: .gram, input: .milliliter)) {
            try NutritionCalculator.snapshot(
                source: .referenceFood, sourceRef: "milk", basisQuantity: basis, basisNutrients: per100g,
                quantity: Quantity(amount: 250, unit: .milliliter)
            )
        }
        let snapshot = try NutritionCalculator.snapshot(
            source: .referenceFood, sourceRef: "milk", basisQuantity: basis, basisNutrients: per100g,
            quantity: Quantity(amount: 250, unit: .milliliter), densityGPerMl: dec("1.03")
        )
        #expect(snapshot.quantityUsed == Quantity(amount: dec("257.5"), unit: .gram))
    }

    @Test func estimatedSnapshotKeepsModelValuesAndBasis() {
        let values = NutrientValues(energyKcal: 720, proteinG: 32, fatG: 26, carbohydrateG: 88)
        let snapshot = NutritionCalculator.estimatedSnapshot(values: values, estimateBasis: "一份约 450g", quantity: nil)
        #expect(snapshot.values == values)
        #expect(snapshot.computedBy == .model)
        #expect(snapshot.basisQuantity == nil)
        #expect(snapshot.estimateBasis == "一份约 450g")
    }

    @Test func representativeTimesFollowTDD() throws {
        let tz = "Asia/Shanghai"
        let lunch = try EventTime(localDate: Fixtures.day, precision: .mealPeriod, mealPeriod: .lunch, timeZoneIdentifier: tz)
        let dateOnly = try EventTime(localDate: Fixtures.day, precision: .dateOnly, timeZoneIdentifier: tz)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Fixtures.shanghai
        #expect(calendar.dateComponents([.hour, .minute], from: lunch.representativeTimestamp) == DateComponents(hour: 12, minute: 30))
        #expect(calendar.dateComponents([.hour, .minute], from: dateOnly.representativeTimestamp) == DateComponents(hour: 12, minute: 0))
        #expect(LocalDate(date: lunch.representativeTimestamp, timeZone: Fixtures.shanghai) == Fixtures.day)
    }
}

struct DaySummaryTests {
    @Test func totalsOnlyIncludedItemsAndComputesProgress() {
        let a = NutritionCalculator.estimatedSnapshot(values: NutrientValues(energyKcal: 500, proteinG: 40, fatG: 10, carbohydrateG: 50), estimateBasis: "x", quantity: nil)
        let b = NutritionCalculator.estimatedSnapshot(values: NutrientValues(energyKcal: 45, proteinG: 0, fatG: 5, carbohydrateG: 0), estimateBasis: "y", quantity: nil)
        let goal = GoalSnapshot(id: UUID(), effectiveFrom: Fixtures.day, targets: GoalTargets(energyKcal: 2000, proteinG: 160), origin: .manualOnboarding, revision: 1)
        let summary = DaySummary(items: [(a, true), (b, false)], goal: goal)
        #expect(summary.totals.energyKcal == 500)
        #expect(summary.excludedItemCount == 1)
        #expect(summary.estimatedItemCount == 1)
        let protein = summary.progress.first { $0.nutrient == .proteinG }!
        #expect(protein.fraction == dec("0.25"))
        #expect(summary.progress.first { $0.nutrient == .fatG }?.fraction == nil)
    }
}
