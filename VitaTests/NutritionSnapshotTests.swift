import Foundation
import Testing
@testable import Vita

struct NutritionSnapshotTests {
    @Test func decimalSurvivesJSONRoundTripWithoutBinaryFloatError() throws {
        let snapshot = NutritionSnapshot(
            nutritionSource: .referenceFood,
            sourceRef: "vita.reference.chicken-breast.raw",
            basisQuantity: Quantity(amount: 100, unit: .gram),
            basisNutrients: NutrientValues(
                energyKcal: Decimal(string: "120.5")!, proteinG: Decimal(string: "22.3")!,
                fatG: Decimal(string: "2.6")!, carbohydrateG: Decimal(string: "0.1")!
            ),
            quantityUsed: Quantity(amount: 200, unit: .gram),
            computedBy: .client,
            estimateBasis: nil,
            values: NutrientValues(
                energyKcal: Decimal(string: "241")!, proteinG: Decimal(string: "44.6")!,
                fatG: Decimal(string: "5.2")!, carbohydrateG: Decimal(string: "0.2")!
            )
        )
        let decoded = try JSONDecoder().decode(NutritionSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
        #expect(decoded.values.proteinG == Decimal(string: "44.6")!)
    }

    @Test func nutrientValuesRejectNegatives() {
        #expect(NutrientValues.zero.isValid)
        var bad = NutrientValues.zero
        bad.fatG = -1
        #expect(!bad.isValid)
    }

    @Test func nutrientValuesAdd() {
        let a = NutrientValues(energyKcal: 100, proteinG: 10, fatG: 1, carbohydrateG: 5)
        let b = NutrientValues(energyKcal: 50, proteinG: Decimal(string: "2.5")!, fatG: 0, carbohydrateG: 1)
        let sum = a + b
        #expect(sum.energyKcal == 150)
        #expect(sum.proteinG == Decimal(string: "12.5")!)
    }
}
