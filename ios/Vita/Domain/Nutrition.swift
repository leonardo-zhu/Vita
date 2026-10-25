import Foundation

/// 四项宏量/能量。持久化计算源一律使用 `Decimal`（TDD §3.2）。
struct NutrientValues: Equatable, Codable, Sendable {
    var energyKcal: Decimal
    var proteinG: Decimal
    var fatG: Decimal
    var carbohydrateG: Decimal

    static let zero = NutrientValues(energyKcal: 0, proteinG: 0, fatG: 0, carbohydrateG: 0)

    var isValid: Bool {
        [energyKcal, proteinG, fatG, carbohydrateG].allSatisfy { $0 >= 0 && !$0.isNaN }
    }

    static func + (lhs: NutrientValues, rhs: NutrientValues) -> NutrientValues {
        NutrientValues(
            energyKcal: lhs.energyKcal + rhs.energyKcal,
            proteinG: lhs.proteinG + rhs.proteinG,
            fatG: lhs.fatG + rhs.fatG,
            carbohydrateG: lhs.carbohydrateG + rhs.carbohydrateG
        )
    }
}

struct Quantity: Equatable, Codable, Sendable {
    var amount: Decimal
    var unit: QuantityUnit
}

/// 谁计算了快照里的数字（agent-tools.md）：命中数据源时由客户端重算，
/// 只有 AI 估算才采用模型给出的数值。
enum NutritionComputedBy: String, Codable, Sendable {
    case client, model
}

/// Item 创建/修改当时的营养快照，同时记录“这组数怎么来的”（TDD §3.2）。
struct NutritionSnapshot: Equatable, Codable, Sendable {
    var nutritionSource: NutritionSource
    /// Food Version ID 或参考条目 ID；aiEstimated 为空。
    var sourceRef: String?
    /// 计算基准：每 `basis.quantity` 含多少营养。
    var basisQuantity: Quantity
    var basisNutrients: NutrientValues
    /// 参与计算的标准化用量。
    var quantityUsed: Quantity
    var computedBy: NutritionComputedBy
    /// 仅 aiEstimated：模型给出的一句话估算依据。
    var estimateBasis: String?
    /// 计算结果。
    var values: NutrientValues
}
