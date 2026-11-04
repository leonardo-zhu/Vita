import Foundation

/// 四项宏量/能量。持久化计算源一律使用 `Decimal`（TDD §3.2）。
struct NutrientValues: Equatable, Codable, Sendable {
    var energyKcal: Decimal
    var proteinG: Decimal
    var fatG: Decimal
    var carbohydrateG: Decimal
    /// 可选的扩展营养素（PRD v2.0 §4.3）：来源上有才有，不由 AI 估算补齐。
    var sodiumMg: Decimal? = nil
    var saturatedFatG: Decimal? = nil
    var sugarG: Decimal? = nil

    static let zero = NutrientValues(energyKcal: 0, proteinG: 0, fatG: 0, carbohydrateG: 0)

    var isValid: Bool {
        ([energyKcal, proteinG, fatG, carbohydrateG] + [sodiumMg, saturatedFatG, sugarG].compactMap { $0 }).allSatisfy { $0 >= 0 && !$0.isNaN }
    }

    func value(of extra: ExtraNutrient) -> Decimal? {
        switch extra {
        case .sodiumMg: sodiumMg
        case .saturatedFatG: saturatedFatG
        case .sugarG: sugarG
        }
    }

    /// 扩展项只加有数据的，两边都没有时仍是 nil。
    static func + (lhs: NutrientValues, rhs: NutrientValues) -> NutrientValues {
        func add(_ a: Decimal?, _ b: Decimal?) -> Decimal? { a == nil && b == nil ? nil : (a ?? 0) + (b ?? 0) }
        return NutrientValues(
            energyKcal: lhs.energyKcal + rhs.energyKcal,
            proteinG: lhs.proteinG + rhs.proteinG,
            fatG: lhs.fatG + rhs.fatG,
            carbohydrateG: lhs.carbohydrateG + rhs.carbohydrateG,
            sodiumMg: add(lhs.sodiumMg, rhs.sodiumMg),
            saturatedFatG: add(lhs.saturatedFatG, rhs.saturatedFatG),
            sugarG: add(lhs.sugarG, rhs.sugarG)
        )
    }
}

/// 钠、饱和脂肪、糖。
enum ExtraNutrient: String, CaseIterable, Sendable {
    case sodiumMg, saturatedFatG, sugarG

    var label: String {
        switch self {
        case .sodiumMg: "钠"
        case .saturatedFatG: "饱和脂肪"
        case .sugarG: "糖"
        }
    }

    var unit: String { self == .sodiumMg ? "mg" : "g" }
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
    /// 计算基准：每 `basisQuantity` 含多少营养。aiEstimated 没有基准。
    var basisQuantity: Quantity?
    var basisNutrients: NutrientValues?
    /// 参与计算的标准化用量（已换算到基准单位）。aiEstimated 且用量无法标准化时为空。
    var quantityUsed: Quantity?
    var computedBy: NutritionComputedBy
    /// 仅 aiEstimated：模型给出的一句话估算依据。
    var estimateBasis: String?
    /// 计算结果。
    var values: NutrientValues
}
