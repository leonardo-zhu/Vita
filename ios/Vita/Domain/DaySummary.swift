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
    /// 有它时能量目标每天按活动计算（ADR-018），`targets.energyKcal` 是设定时按平时活动算的参考值。
    var energyPlan: EnergyPlan? = nil
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
    /// 计入汇总的条目里，各扩展营养素缺数据的条数。
    var missingExtras: [ExtraNutrient: Int] = [:]
    var excludedItemCount: Int
    var estimatedItemCount: Int
    /// 生效目标。能量目标随活动计算时，`targets.energyKcal` 已换成这一天算出的值。
    var goal: GoalSnapshot?
    /// 能量目标随活动计算时的来历（ADR-018）；固定目标为 nil。
    var energy: EnergyTarget?
    /// 截至现在的热量收支；没有活动数据或没有随活动计算的目标时为 nil。
    var balance: EnergyBalance?

    init(
        items: [(snapshot: NutritionSnapshot, includeInSummary: Bool)],
        goal: GoalSnapshot?,
        energy: EnergyTarget? = nil,
        balance: EnergyBalance? = nil
    ) {
        let included = items.filter(\.includeInSummary)
        totals = included.reduce(.zero) { $0 + $1.snapshot.values }
        includedItemCount = included.count
        missingExtras = Dictionary(uniqueKeysWithValues: ExtraNutrient.allCases.map { extra in
            (extra, included.filter { $0.snapshot.values.value(of: extra) == nil }.count)
        })
        excludedItemCount = items.count - included.count
        estimatedItemCount = included.filter { $0.snapshot.nutritionSource == .aiEstimated }.count
        self.goal = goal
        self.energy = energy
        self.balance = balance
        if let energy { self.goal?.targets.energyKcal = energy.targetKcal }
    }

    /// 服务端算好的汇总（`GET /v1/days/:date`）：能量目标随活动计算时，`goal.targets.energyKcal` 已是当天的值。
    init(
        totals: NutrientValues, includedItemCount: Int, excludedItemCount: Int, estimatedItemCount: Int,
        goal: GoalSnapshot?, energy: EnergyTarget?, balance: EnergyBalance?, missingExtras: [ExtraNutrient: Int] = [:]
    ) {
        self.totals = totals
        self.missingExtras = missingExtras
        self.includedItemCount = includedItemCount
        self.excludedItemCount = excludedItemCount
        self.estimatedItemCount = estimatedItemCount
        self.goal = goal
        self.energy = energy
        self.balance = balance
    }

    var progress: [Progress] {
        Nutrient.allCases.map {
            Progress(nutrient: $0, consumed: $0.value(in: totals), target: goal?.targets.target(for: $0))
        }
    }
}
