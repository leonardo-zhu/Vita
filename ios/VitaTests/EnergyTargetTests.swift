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

@MainActor
struct EnergyGoalTests {
    private func services(activity: [LocalDate: Decimal] = [:], at hour: Int = 12) throws -> (AppServices, FakeHealthDataStore) {
        let store = FakeHealthDataStore()
        store.activeEnergyByDate = activity
        var container = try AppContainer.inMemory()
        container.healthStore = store
        let now = Fixtures.now.addingTimeInterval(TimeInterval((hour - 12) * 3600))
        return (AppServices(container: container, now: { now }, timeZone: { Fixtures.shanghai }), store)
    }

    private let plan = EnergyPlan(kind: .lose, adjustment: .fraction(dec("0.85")), bmrKcal: 1700, baselineActivityKcal: 400, baselineEstimated: false)

    @Test func dayDataUsesCachedActivity() async throws {
        // 前 7 天每天 500，今天到现在 800。
        var activity = Dictionary(uniqueKeysWithValues: (1...7).map { (Fixtures.day.adding(days: -$0), Decimal(500)) })
        activity[Fixtures.day] = 800
        let (services, _) = try services(activity: activity)
        try services.goals.appendGoal(GoalTargets(energyKcal: 1870, proteinG: 120), energyPlan: plan, origin: .initialRecommendation, effectiveFrom: Fixtures.day)

        // 没读活动前用设定时的平时活动 400。
        let before = try services.dayData.day(Fixtures.day).summary
        #expect(before.energy?.baselineActivityKcal == 400)

        await services.health.refreshActivity(on: [Fixtures.day])
        let summary = try services.dayData.day(Fixtures.day).summary
        let energy = try #require(summary.energy)
        #expect(energy.baselineActivityKcal == 500)
        #expect(summary.goal?.targets.energyKcal == energy.targetKcal)
        #expect(summary.goal?.targets.proteinG == 120)
        #expect(summary.balance != nil)
    }

    @Test func fixedGoalsStayFixedAndLegacyRowsStillLoad() throws {
        let (services, _) = try services()
        // 早先的行只存了 GoalTargets，没有 energyPlan 键。
        let context = services.container.modelContainer.mainContext
        let legacy = DailyGoal(effectiveFrom: Fixtures.day, targets: GoalTargets(energyKcal: 2040, proteinG: 126), origin: .initialRecommendation, evidenceData: nil, revision: 1, now: Fixtures.now)
        legacy.targetsData = JSONColumn.encode(GoalTargets(energyKcal: 2040, proteinG: 126))
        context.insert(legacy)
        try context.save()

        let summary = try services.dayData.day(Fixtures.day).summary
        #expect(summary.goal?.targets.energyKcal == 2040)
        #expect(summary.goal?.energyPlan == nil)
        #expect(summary.energy == nil)
        // 没有自动设定过，不能改回自动。
        #expect(throws: GoalServiceError.noEnergyPlan) {
            try services.goals.updateGoal(GoalTargets(), energyPlan: EnergyPlanChange(), effectiveFrom: Fixtures.day)
        }
    }

    @Test func updateGoalSwitchesBetweenFixedAndAuto() async throws {
        let (services, _) = try services()
        try services.goals.appendGoal(GoalTargets(energyKcal: 1870, proteinG: 120), energyPlan: plan, origin: .initialRecommendation, effectiveFrom: Fixtures.day)
        let tools = AgentToolRunner(services: services, now: { Fixtures.now }, timeZone: { Fixtures.shanghai })
        func call(_ arguments: String) async -> String {
            await tools.run(LLMFunctionCall(callID: "c", name: "updateGoal", arguments: arguments), sessionDate: Fixtures.day, requestID: UUID()).output
        }

        // “热量目标改成 2000”：固定。
        let fixed = await call(#"{"energyKcal":2000,"userCommand":"热量目标改成 2000"}"#)
        #expect(fixed.contains(#""energyMode":"fixed""#))
        #expect(try services.dayData.day(Fixtures.day).summary.goal?.targets.energyKcal == 2000)

        // “缺口改成 500 千卡”：恢复随活动计算，沿用上次的 BMR 与平时活动。
        let auto = await call(#"{"energyAdjustmentKcal":-500,"userCommand":"缺口改成 500 千卡"}"#)
        #expect(auto.contains(#""energyMode":"auto""#))
        let goal = try #require(try services.goals.activeGoal(on: Fixtures.day))
        #expect(goal.energyPlan?.adjustment == .kcal(-500))
        #expect(goal.energyPlan?.bmrKcal == 1700)

        // “改成增肌”：类型的默认调整。
        _ = await call(#"{"goalType":"gain","userCommand":"改成增肌"}"#)
        #expect(try services.goals.activeGoal(on: Fixtures.day)?.energyPlan?.adjustment == .fraction(dec("1.10")))

        let both = await call(#"{"energyKcal":2000,"goalType":"lose","userCommand":"x"}"#)
        #expect(both.contains("invalidField"))
        let tooSteep = await call(#"{"energyPercent":30,"userCommand":"x"}"#)
        #expect(tooSteep.contains("invalidField"))
    }
}
