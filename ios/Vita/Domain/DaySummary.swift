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
    /// 这一天基础代谢最近的一次变化（称重、补录等让 BMR 变了）；没变过为 nil。
    var bmrChange: BmrChange?

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
        goal: GoalSnapshot?, energy: EnergyTarget?, balance: EnergyBalance?, missingExtras: [ExtraNutrient: Int] = [:],
        bmrChange: BmrChange? = nil
    ) {
        self.bmrChange = bmrChange
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

/// 基础代谢的一次变化（随活动计算的目标每天按最新身体数据重算 BMR，服务端在它变了时记一条）。
struct BmrChange: Equatable, Sendable {
    enum Reason: String, Decodable, Sendable {
        case weighing, appleHealth, manual, goal
    }

    var previousBmrKcal: Decimal
    var bmrKcal: Decimal
    /// 服务端以后可能加新的原因：认不出时为 nil，仍显示数值变化。
    var reason: Reason?
    var weightKg: Decimal

    /// Data 页的一行提示，如“称重 72.8 kg，基础代谢 1702 → 1690”。
    var note: String {
        let weight = DisplayFormat.number(weightKg, digits: 1)
        let change = "基础代谢 \(DisplayFormat.number(previousBmrKcal, digits: 0)) → \(DisplayFormat.number(bmrKcal, digits: 0))"
        switch reason {
        case .weighing: return "称重 \(weight) kg，\(change)"
        case .appleHealth: return "Apple 健康里的体重为 \(weight) kg，\(change)"
        case .manual: return "补录了身体数据，\(change)"
        case .goal: return "按当前体重 \(weight) kg 重算，\(change)"
        case nil: return change
        }
    }
}
