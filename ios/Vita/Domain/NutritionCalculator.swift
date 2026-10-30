import Foundation

enum UnitNormalizationError: Error, Equatable {
    case unsupportedUnit(String)
    case nonPositiveAmount
}

/// 把“数值 + 单位写法”换算为内部只用的 g / ml（TDD §3.3）。只处理确定的质量与体积单位；
/// “一个”“一碗”这类计数单位需要包装规格或估算，不在这里猜。
enum UnitNormalizer {
    private static let factors: [String: (Decimal, QuantityUnit)] = [
        "g": (1, .gram), "克": (1, .gram), "gram": (1, .gram), "grams": (1, .gram),
        "kg": (1000, .gram), "千克": (1000, .gram), "公斤": (1000, .gram),
        "mg": (Decimal(string: "0.001")!, .gram), "毫克": (Decimal(string: "0.001")!, .gram),
        "斤": (500, .gram),
        // 作为单位的“两”是 50g；“两个”里的“两”是数词，由调用方在拆出单位前处理。
        "两": (50, .gram),
        "ml": (1, .milliliter), "毫升": (1, .milliliter),
        "l": (1000, .milliliter), "升": (1000, .milliliter),
    ]

    static func normalize(amount: Decimal, unit: String) throws -> Quantity {
        guard amount > 0 else { throw UnitNormalizationError.nonPositiveAmount }
        let key = unit.trimmingCharacters(in: .whitespaces).lowercased()
        guard let (factor, base) = factors[key] else { throw UnitNormalizationError.unsupportedUnit(unit) }
        return Quantity(amount: amount * factor, unit: base)
    }
}

enum NutritionCalculationError: Error, Equatable {
    case nonPositiveQuantity
    case invalidBasis
    /// g 与 ml 之间没有经审阅的密度，不能按 1ml = 1g 换算（reference-food-library.md §3）。
    case unitMismatch(basis: QuantityUnit, input: QuantityUnit)
}

/// 客户端营养计算（TDD §4.2）：每基准营养 × 用量，全程 `Decimal`。
enum NutritionCalculator {
    /// 把用量换算到基准单位。只有给出密度时才在 g / ml 之间换算。
    static func convert(_ quantity: Quantity, to unit: QuantityUnit, densityGPerMl: Decimal?) throws -> Quantity {
        guard quantity.amount > 0 else { throw NutritionCalculationError.nonPositiveQuantity }
        if quantity.unit == unit { return quantity }
        guard let density = densityGPerMl, density > 0 else {
            throw NutritionCalculationError.unitMismatch(basis: unit, input: quantity.unit)
        }
        switch (quantity.unit, unit) {
        case (.milliliter, .gram): return Quantity(amount: quantity.amount * density, unit: .gram)
        case (.gram, .milliliter): return Quantity(amount: quantity.amount / density, unit: .milliliter)
        default: return quantity
        }
    }

    /// 由数据源计算的快照（personal / reference），`computedBy = .client`。
    static func snapshot(
        source: NutritionSource,
        sourceRef: String,
        basisQuantity: Quantity,
        basisNutrients: NutrientValues,
        quantity: Quantity,
        densityGPerMl: Decimal? = nil
    ) throws -> NutritionSnapshot {
        guard basisQuantity.amount > 0, basisNutrients.isValid else { throw NutritionCalculationError.invalidBasis }
        let used = try convert(quantity, to: basisQuantity.unit, densityGPerMl: densityGPerMl)
        // 先乘后除，减少中间结果的截断。
        func scale(_ value: Decimal) -> Decimal { value * used.amount / basisQuantity.amount }
        return NutritionSnapshot(
            nutritionSource: source,
            sourceRef: sourceRef,
            basisQuantity: basisQuantity,
            basisNutrients: basisNutrients,
            quantityUsed: used,
            computedBy: .client,
            estimateBasis: nil,
            values: NutrientValues(
                energyKcal: scale(basisNutrients.energyKcal),
                proteinG: scale(basisNutrients.proteinG),
                fatG: scale(basisNutrients.fatG),
                carbohydrateG: scale(basisNutrients.carbohydrateG)
            )
        )
    }

    /// AI 估算的快照：采用模型给出的数值，必须带估算依据。
    static func estimatedSnapshot(values: NutrientValues, estimateBasis: String, quantity: Quantity?) -> NutritionSnapshot {
        NutritionSnapshot(
            nutritionSource: .aiEstimated,
            sourceRef: nil,
            basisQuantity: nil,
            basisNutrients: nil,
            quantityUsed: quantity,
            computedBy: .model,
            estimateBasis: estimateBasis,
            values: values
        )
    }
}
