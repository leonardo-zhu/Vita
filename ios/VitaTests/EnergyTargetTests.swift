import Foundation
import SwiftData
import Testing
@testable import Vita

/// 能量目标随活动计算（TDD §6.2、ADR-018）。例子同设计讨论：BMR 1700、平时活动 500、减脂 85%。
struct EnergyTargetPolicyTests {
    private let plan = EnergyPlan(kind: .lose, adjustment: .fraction(dec("0.85")), bmrKcal: 1700, baselineActivityKcal: 500, baselineEstimated: false)
    private func hours(_ h: Double) -> EnergyTargetPolicy.Day { .today(elapsed: h * 3600) }

    @Test func morningUsesTheUsualActivity() {
        let target = EnergyTargetPolicy.target(plan: plan, activity: DayActivity(activeKcal: 0, dailyAverageKcal: 500), day: hours(7))
        #expect(target.projectedActivityKcal == 500)
        #expect(target.tdeeKcal == 2200)
        #expect(target.targetKcal == 1870)
        #expect(target.adjustmentKcal == -330)
    }

    @Test func extraActivityCountsHalf() {
        // 18 点跑完步已消耗 1000，剩余时段还有 500 × 5/16：预估 1156.25，超出平时 656.25，计入一半。
        let target = EnergyTargetPolicy.target(plan: plan, activity: DayActivity(activeKcal: 1000, dailyAverageKcal: 500), day: hours(18))
        #expect(target.projectedActivityKcal == dec("1156.25"))
        #expect(target.countedActivityKcal == dec("828.125"))
        #expect(target.targetKcal == 2150)
    }

    @Test func quietDaysLowerTheTargetButNotBelowBMR() {
        let quiet = EnergyTargetPolicy.target(plan: plan, activity: DayActivity(activeKcal: 400, dailyAverageKcal: 500), day: .past)
        #expect(quiet.countedActivityKcal == 400)
        #expect(quiet.targetKcal == 1790)
        #expect(!quiet.raisedToBMR)
        // 几乎没动：2100 × 0.85 = 1785 以下继续降，1800 × 0.85 = 1530 低于 BMR，按 BMR 计。
        let still = EnergyTargetPolicy.target(plan: plan, activity: DayActivity(activeKcal: 100, dailyAverageKcal: 500), day: .past)
        #expect(still.targetKcal == 1700)
        #expect(still.raisedToBMR)

        var steep = plan
        steep.adjustment = .kcal(-1000)
        let floored = EnergyTargetPolicy.target(plan: steep, activity: DayActivity(activeKcal: 0, dailyAverageKcal: 500), day: .past)
        #expect(floored.targetKcal == 1700)
        #expect(floored.raisedToBMR)
    }

    @Test func kcalAdjustmentAndMissingActivity() {
        var byKcal = plan
        byKcal.adjustment = .kcal(-400)
        // 还没读到活动：按设定时保存的平时活动，标记为估算。
        let target = EnergyTargetPolicy.target(plan: byKcal, activity: nil, day: hours(23))
        #expect(target.projectedActivityKcal == 500)
        #expect(target.targetKcal == 1800)
        #expect(target.activityEstimated)
        let future = EnergyTargetPolicy.target(plan: byKcal, activity: nil, day: .future)
        #expect(future.targetKcal == 1800)
        #expect(!future.activityEstimated)
    }

    @Test func balanceProratesBMRThroughTheDay() throws {
        let noon = try #require(EnergyTargetPolicy.balance(bmrKcal: 1700, activity: DayActivity(activeKcal: 300), day: hours(12), consumedKcal: 900))
        #expect(noon.burnedKcal == 1150)
        #expect(noon.balanceKcal == -250)
        #expect(EnergyTargetPolicy.balance(bmrKcal: 1700, activity: nil, day: .past, consumedKcal: 900) == nil)
    }
}
