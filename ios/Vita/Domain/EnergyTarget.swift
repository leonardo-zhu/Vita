import Foundation

/// 能量目标的设定（TDD §6.2、ADR-018）：保存规则而不是一个数，每天按当天的活动算出目标。
/// 存在 `DailyGoal` 的目标列里；没有它的目标是固定能量目标。
struct EnergyPlan: Equatable, Codable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case maintain, lose, gain
    }

    /// 相对每日消耗的调整：比例（0.85 = 少吃 15%）或千卡（−400 = 每天少吃 400）。
    enum Adjustment: Equatable, Codable, Sendable {
        case fraction(Decimal)
        case kcal(Decimal)
    }

    var kind: Kind
    var adjustment: Adjustment
    var bmrKcal: Decimal
    /// 设定时的平时活动（7 日日均）；读不到当天活动时用它，数字不会在加载前后跳动。
    var baselineActivityKcal: Decimal
    /// 平时活动是否按 BMR × 0.375 估算（设定时没有足够的活动数据）。
    var baselineEstimated: Bool

    /// 比例 0.5–1.5，千卡 −1500…+1500。
    var isValid: Bool {
        switch adjustment {
        case .fraction(let fraction): fraction >= Decimal(string: "0.5")! && fraction <= Decimal(string: "1.5")!
        case .kcal(let kcal): kcal >= -1500 && kcal <= 1500
        }
    }

    static func defaultAdjustment(for kind: Kind) -> Adjustment {
        switch kind {
        case .maintain: .fraction(1)
        case .lose: .fraction(EnergyTargetPolicy.defaultLoseFraction)
        case .gain: .fraction(EnergyTargetPolicy.defaultGainFraction)
        }
    }
}

/// 某天的活动读数。今天的是截至现在的累计；过去的日子是全天。
struct DayActivity: Equatable, Sendable {
    /// 当天已消耗的活动能量；没有数据为 nil。
    var activeKcal: Decimal?
    /// 这一天之前 7 个完整日的日均活动；有数据的天数不足时为 nil。
    var dailyAverageKcal: Decimal?
}

/// 某天的能量目标与它的来历，供 Data 页解释数字为什么变了。
struct EnergyTarget: Equatable, Sendable {
    var targetKcal: Decimal
    var bmrKcal: Decimal
    /// 平时活动（7 日日均或设定时的值）。
    var baselineActivityKcal: Decimal
    /// 当天活动预估（今天是“已消耗 + 平时 × 剩余比例”，过去是全天实际）。
    var projectedActivityKcal: Decimal
    /// 计入消耗的活动：超出平时的部分打了折。
    var countedActivityKcal: Decimal
    var tdeeKcal: Decimal
    /// 目标相对消耗的调整（负数为缺口）。
    var adjustmentKcal: Decimal
    /// 被 BMR 下限抬高过。
    var raisedToBMR: Bool
    /// 没有当天的活动数据，按平时活动估算。
    var activityEstimated: Bool
}

/// 当前为止的热量收支：负数表示缺口（消耗多于摄入）。
struct EnergyBalance: Equatable, Sendable {
    var burnedKcal: Decimal
    var consumedKcal: Decimal
    var balanceKcal: Decimal { consumedKcal - burnedKcal }
}

/// 每日能量目标的计算（TDD §6.2）。系数都在这里。
enum EnergyTargetPolicy {
    static let defaultLoseFraction = Decimal(string: "0.85")!
    static let defaultGainFraction = Decimal(string: "1.10")!
    /// 没有活动数据时的平时活动 = BMR × 0.375（即 TDEE = BMR × 1.375）。
    static let estimatedActivityShareOfBMR = Decimal(string: "0.375")!
    /// 超出平时的活动计入的比例。
    static let extraActivityShare = Decimal(string: "0.5")!
    /// 活跃时段 7:00–23:00，用来估计今天剩下的活动。
    static let activeStartHour = 7
    static let activeEndHour = 23

    enum Day: Equatable, Sendable {
        /// 今天，`elapsed` 为已过的秒数（从 0 点算起）。
        case today(elapsed: TimeInterval)
        case past
        case future
    }

    static func target(plan: EnergyPlan, activity: DayActivity?, day: Day) -> EnergyTarget {
        let baseline = activity?.dailyAverageKcal ?? plan.baselineActivityKcal
        let measured = activity?.activeKcal
        let projected: Decimal = switch day {
        case .future: baseline
        case .past: measured ?? baseline
        // 一点活动数据都没有（没戴手表或没授权）时按平时活动，不当作 0。
        case .today(let elapsed): measured.map { $0 + baseline * remainingActiveShare(elapsed: elapsed) } ?? baseline
        }
        let counted = projected <= baseline ? projected : baseline + (projected - baseline) * extraActivityShare
        let tdee = plan.bmrKcal + counted
        let adjusted: Decimal = switch plan.adjustment {
        case .fraction(let fraction): tdee * fraction
        case .kcal(let kcal): tdee + kcal
        }
        let raised = adjusted < plan.bmrKcal
        let target = rounded(max(adjusted, plan.bmrKcal), to: 10)
        return EnergyTarget(
            targetKcal: target, bmrKcal: plan.bmrKcal, baselineActivityKcal: baseline,
            projectedActivityKcal: projected, countedActivityKcal: counted, tdeeKcal: tdee,
            adjustmentKcal: target - tdee, raisedToBMR: raised,
            activityEstimated: measured == nil && day != .future
        )
    }

    /// 截至现在的收支：BMR 按当天已过的时间折算，加上已消耗的活动；过去的日子按全天。
    static func balance(bmrKcal: Decimal, activity: DayActivity?, day: Day, consumedKcal: Decimal) -> EnergyBalance? {
        guard day != .future, let active = activity?.activeKcal else { return nil }
        let basal: Decimal = switch day {
        case .today(let elapsed): bmrKcal * Decimal(min(max(elapsed / 86_400, 0), 1))
        case .past, .future: bmrKcal
        }
        return EnergyBalance(burnedKcal: rounded(basal + active, to: 1), consumedKcal: consumedKcal)
    }

    /// 活跃时段里还剩下的比例：7 点前为 1，23 点后为 0。
    static func remainingActiveShare(elapsed: TimeInterval) -> Decimal {
        let start = TimeInterval(activeStartHour * 3600)
        let end = TimeInterval(activeEndHour * 3600)
        let remaining = min(max((end - elapsed) / (end - start), 0), 1)
        return Decimal(remaining)
    }

    static func rounded(_ value: Decimal, to step: Decimal) -> Decimal {
        var scaled = value / step
        var result = Decimal()
        NSDecimalRound(&result, &scaled, 0, .plain)
        return result * step
    }
}
