import Foundation

enum Nutrient: String, CaseIterable, Codable, Sendable {
    case energyKcal, proteinG, fatG, carbohydrateG

    func value(in values: NutrientValues) -> Decimal {
        switch self {
        case .energyKcal: values.energyKcal
        case .proteinG: values.proteinG
        case .fatG: values.fatG
        case .carbohydrateG: values.carbohydrateG
        }
    }
}

/// 每日目标值；未设的项为空。
struct GoalTargets: Equatable, Codable, Sendable {
    var energyKcal: Decimal?
    var proteinG: Decimal?
    var fatG: Decimal?
    var carbohydrateG: Decimal?

    func target(for nutrient: Nutrient) -> Decimal? {
        switch nutrient {
        case .energyKcal: energyKcal
        case .proteinG: proteinG
        case .fatG: fatG
        case .carbohydrateG: carbohydrateG
        }
    }

    /// 至少一项，且每项为正数。
    var isValid: Bool {
        let present = Nutrient.allCases.compactMap(target(for:))
        return !present.isEmpty && present.allSatisfy { $0 > 0 }
    }
}

struct GoalSnapshot: Equatable, Sendable {
    var id: UUID
    var effectiveFrom: LocalDate
    var targets: GoalTargets
    var origin: GoalOrigin
    var revision: Int
}

/// 一天的营养汇总。总量每次由 Item 快照重算，不作为持久化的真相（TDD §4.2）。
struct DaySummary: Equatable, Sendable {
    struct Progress: Equatable, Sendable {
        var nutrient: Nutrient
        var consumed: Decimal
        var target: Decimal?

        /// 完成度，0 起、可超过 1；没有目标时为空。
        var fraction: Decimal? {
            guard let target, target > 0 else { return nil }
            return consumed / target
        }
    }

    var totals: NutrientValues
    var includedItemCount: Int
    var excludedItemCount: Int
    var estimatedItemCount: Int
    var goal: GoalSnapshot?

    init(items: [(snapshot: NutritionSnapshot, includeInSummary: Bool)], goal: GoalSnapshot?) {
        let included = items.filter(\.includeInSummary)
        totals = included.reduce(.zero) { $0 + $1.snapshot.values }
        includedItemCount = included.count
        excludedItemCount = items.count - included.count
        estimatedItemCount = included.filter { $0.snapshot.nutritionSource == .aiEstimated }.count
        self.goal = goal
    }

    var progress: [Progress] {
        Nutrient.allCases.map {
            Progress(nutrient: $0, consumed: $0.value(in: totals), target: goal?.targets.target(for: $0))
        }
    }
}
