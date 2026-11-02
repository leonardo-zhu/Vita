import Foundation
import SwiftData
import Testing
@testable import Vita

@MainActor
struct HealthSyncTests {
    let store = FakeHealthDataStore(writeAuthorization: .authorized)
    let container: AppContainer
    let services: AppServices

    init() throws {
        var container = try AppContainer.inMemory(referenceFoods: try Fixtures.referenceFoods())
        container.healthStore = store
        self.container = container
        services = AppServices(container: container, now: { Fixtures.now }, timeZone: { Fixtures.shanghai })
    }

    private var context: ModelContext { container.modelContainer.mainContext }

    private func energySamples() -> [Decimal] {
        store.samples.values.filter { $0.nutrient == .energyKcal }.map(\.value).sorted()
    }

    @Test func confirmedRecordIsWrittenOnceWithMetadata() async throws {
        let id = try services.records.createRecord(on: Fixtures.day, expectedRevision: 0, draft: try .lunch([.estimate(kcal: 500, protein: 30)]))
        #expect(services.healthSync.state(for: id) == .pending)
        let result = await services.healthSync.run()
        #expect(result.synced == 1)
        #expect(energySamples() == [500])
        // 蛋白质有值才写；脂肪、碳水为 0 不写。
        #expect(Set(store.samples.values.map(\.nutrient)) == [.energyKcal, .proteinG])
        let sample = try #require(store.samples.values.first)
        #expect(sample.metadata["vita.recordID"] == id.uuidString)
        #expect(sample.metadata["vita.timeWasRepresentative"] == "true")
        #expect(sample.metadata["vita.mealPeriod"] == "lunch")
        #expect(services.healthSync.state(for: id) == .synced)
    }

    /// 验收：同一 Record 多次修改后 HealthKit 只有最新版 Sample。
    @Test func repeatedEditsLeaveOnlyLatestSamples() async throws {
        let id = try services.records.createRecord(on: Fixtures.day, expectedRevision: 0, draft: try .lunch([.estimate(kcal: 500)]))
        await services.healthSync.run()
        try services.records.appendItems([.estimate(kcal: 100)], to: id, on: Fixtures.day, expectedRevision: 1)
        await services.healthSync.run()
        // 两次修改积压后再同步。
        try services.records.appendItems([.estimate(kcal: 50)], to: id, on: Fixtures.day, expectedRevision: 2)
        let itemID = try services.dayData.day(Fixtures.day).records[0].items[0].id
        try services.records.replaceItem(itemID, with: .estimate(kcal: 400), in: id, on: Fixtures.day, expectedRevision: 3)
        await services.healthSync.run()
        #expect(energySamples() == [550])
        #expect(try context.fetchCount(FetchDescriptor<HealthSyncMapping>()) == 1)
    }

    /// 场景 4：删除已同步的 Record 时先删旧 Sample 再清映射。
    @Test func deletingRemovesSamplesAndMappings() async throws {
        let id = try services.records.createRecord(on: Fixtures.day, expectedRevision: 0, draft: try .lunch([.estimate(kcal: 500)]))
        await services.healthSync.run()
        try services.records.deleteRecord(id, on: Fixtures.day, expectedRevision: 1)
        await services.healthSync.run()
        #expect(store.samples.isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<HealthSyncMapping>()) == 0)
        #expect(services.healthSync.state(for: id) == nil)
    }

    /// 验收：无写入权限时本地记录仍正确，并显示待解决同步状态；恢复权限后补同步。
    @Test func deniedWriteKeepsLocalDataAndNeedsResolution() async throws {
        store.setWriteAuthorization(.denied)
        let id = try services.records.createRecord(on: Fixtures.day, expectedRevision: 0, draft: try .lunch([.estimate(kcal: 500)]))
        await services.healthSync.run()
        #expect(try services.dayData.day(Fixtures.day).summary.totals.energyKcal == 500)
        #expect(services.healthSync.state(for: id) == .requiresUserResolution)
        #expect(store.samples.isEmpty)

        store.setWriteAuthorization(.authorized)
        await services.healthSync.run()
        #expect(services.healthSync.state(for: id) == .synced)
        #expect(energySamples() == [500])
    }

    /// 删除失败不得清映射，否则会留下无法追踪的孤儿 Sample（TDD §6.3）。
    @Test func failedDeleteKeepsMappingAndRetries() async throws {
        let id = try services.records.createRecord(on: Fixtures.day, expectedRevision: 0, draft: try .lunch([.estimate(kcal: 500)]))
        await services.healthSync.run()
        try services.records.deleteRecord(id, on: Fixtures.day, expectedRevision: 1)
        store.failNext(1)
        let failed = await services.healthSync.run()
        #expect(failed.failed == 1)
        #expect(services.healthSync.state(for: id) == .failedRetryable)
        #expect(try context.fetchCount(FetchDescriptor<HealthSyncMapping>()) == 1)
        #expect(energySamples() == [500])

        await services.healthSync.run()
        #expect(store.samples.isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<HealthSyncMapping>()) == 0)
    }

    @Test func neverConnectedStaysQuietlyPending() async throws {
        store.setWriteAuthorization(.notDetermined)
        let id = try services.records.createRecord(on: Fixtures.day, expectedRevision: 0, draft: try .lunch([.estimate(kcal: 500)]))
        let result = await services.healthSync.run()
        #expect(result.waitingForPermission == 1)
        #expect(services.healthSync.state(for: id) == .pending)
    }

    /// 被确认的 Pending 与它的 outbox 项在同一事务里写入：作废的提案不会产生同步。
    @Test func voidedProposalsNeverReachTheOutbox() async throws {
        let pending = try services.pending.propose(.create(try .lunch([.estimate(kcal: 500)])), on: Fixtures.day, expectedRevision: 0)
        try services.pending.cancel(pending.id)
        #expect(try context.fetchCount(FetchDescriptor<HealthSyncOperation>()) == 0)
    }
}

struct GoalRecommendationPolicyTests {
    private func snapshot(weight: Decimal? = 70, active: Decimal? = nil) -> HealthSnapshot {
        var snapshot = HealthSnapshot.empty
        if let weight { snapshot.bodyMassKg = .value(weight, source: .healthKit, measuredAt: nil) }
        snapshot.heightCm = .value(175, source: .healthKit, measuredAt: nil)
        snapshot.dateOfBirth = .value(LocalDate(isoString: "1996-05-20")!, source: .manual, measuredAt: nil)
        snapshot.sex = .value(.male, source: .healthKit, measuredAt: nil)
        if let active { snapshot.averageActiveEnergyKcal = .value(active, source: .healthKit, measuredAt: nil) }
        return snapshot
    }

    @Test func mifflinStJeorWithLightActivityFactor() throws {
        // 30 岁男性，70kg、175cm：BMR = 700 + 1093.75 − 150 + 5 = 1648.75。
        guard case .ready(let result) = GoalRecommendationPolicy.recommend(snapshot: snapshot(), on: Fixtures.day, now: Fixtures.now) else {
            Issue.record("expected recommendation"); return
        }
        #expect(result.input.ageYears == 30)
        #expect(result.bmrKcal == dec("1648.8"))
        #expect(result.tdeeEstimated)
        // 平时消耗 = 1648.75 × 1.375 = 2267.03；默认减脂 85% ≈ 1930，蛋白 1.8 × 70 = 126。
        #expect(result.targets.energyKcal == 1930)
        #expect(result.energyPlan?.kind == .lose)
        #expect(result.energyPlan?.adjustment == .fraction(dec("0.85")))
        #expect(result.energyPlan?.baselineEstimated == true)
        #expect(result.targets.proteinG == 126)
        #expect(result.input.ageSource == .manual)
    }

    @Test func activeEnergyReplacesTheEstimate() {
        guard case .ready(let result) = GoalRecommendationPolicy.recommend(snapshot: snapshot(active: 500), on: Fixtures.day, now: Fixtures.now) else {
            Issue.record("expected recommendation"); return
        }
        #expect(!result.tdeeEstimated)
        #expect(result.tdeeKcal == dec("2148.8"))
        #expect(result.targets.energyKcal == 1830)
        #expect(result.energyPlan?.baselineActivityKcal == 500)
    }

    @Test func weightIsAHardRequirement() {
        #expect(GoalRecommendationPolicy.recommend(snapshot: snapshot(weight: nil), on: Fixtures.day, now: Fixtures.now) == .missing([.bodyMass]))
    }

    @Test func ageCountsBirthdaysCorrectly() {
        let birth = LocalDate(isoString: "1996-10-31")!
        #expect(GoalRecommendationPolicy.age(of: birth, on: LocalDate(isoString: "2026-10-30")!) == 29)
        #expect(GoalRecommendationPolicy.age(of: birth, on: LocalDate(isoString: "2026-10-31")!) == 30)
    }
}

@MainActor
struct HealthServiceTests {
    @Test func manualMetricsFillGapsButHealthKitWins() async throws {
        let store = FakeHealthDataStore()
        store.body = ManualBodyMetrics(bodyMassKg: 72, enteredAt: Fixtures.now)
        var container = try AppContainer.inMemory()
        container.healthStore = store
        let services = AppServices(container: container, now: { Fixtures.now }, timeZone: { Fixtures.shanghai })

        try services.health.submitManualBodyMetrics(ManualBodyMetrics(bodyMassKg: 80, heightCm: 170, sex: .female, enteredAt: Fixtures.now))
        let snapshot = await services.health.snapshot(on: Fixtures.day)
        #expect(snapshot.bodyMassKg.value == 72)
        #expect(snapshot.bodyMassKg.source == .healthKit)
        #expect(snapshot.heightCm.value == 170)
        #expect(snapshot.heightCm.source == .manual)
        #expect(snapshot.sex.value == .female)
        #expect(snapshot.dateOfBirth == .noData)

        // 再次补录只覆盖给出的项。
        try services.health.submitManualBodyMetrics(ManualBodyMetrics(dateOfBirth: LocalDate(isoString: "1990-01-01"), enteredAt: Fixtures.now))
        #expect(try services.health.manualMetrics()?.heightCm == 170)
        #expect(throws: HealthServiceError.invalidMetrics) {
            try services.health.submitManualBodyMetrics(ManualBodyMetrics(bodyMassKg: 5, enteredAt: Fixtures.now))
        }
    }

    @Test func commitAndUpdateGoalsKeepHistory() throws {
        let services = AppServices(container: try AppContainer.inMemory(), now: { Fixtures.now }, timeZone: { Fixtures.shanghai })
        var snapshot = HealthSnapshot.empty
        snapshot.bodyMassKg = .value(70, source: .manual, measuredAt: nil)
        snapshot.heightCm = .value(175, source: .manual, measuredAt: nil)
        snapshot.dateOfBirth = .value(LocalDate(isoString: "1996-05-20")!, source: .manual, measuredAt: nil)
        snapshot.sex = .value(.male, source: .manual, measuredAt: nil)
        guard case .ready(let recommendation) = GoalRecommendationPolicy.recommend(snapshot: snapshot, on: Fixtures.day, now: Fixtures.now) else {
            Issue.record("expected recommendation"); return
        }
        let first = try services.goals.commitInitialGoals(recommendation, effectiveFrom: Fixtures.day)
        #expect(first.origin == .initialRecommendation)

        // “把蛋白质目标改成 150g”：只改蛋白，能量沿用；返回旧值与新值。
        let (previous, current) = try services.goals.updateGoal(GoalTargets(proteinG: 150), effectiveFrom: Fixtures.day)
        #expect(previous?.targets.proteinG == 126)
        #expect(current.targets.proteinG == 150)
        #expect(current.targets.energyKcal == 1930)
        #expect(current.energyPlan == first.energyPlan)
        #expect(current.origin == .explicitUserCommand)
        // 改回去也只是再追加一行。
        try services.goals.updateGoal(GoalTargets(proteinG: 126), effectiveFrom: Fixtures.day)
        #expect(try services.goals.activeGoal(on: Fixtures.day)?.revision == 3)
    }
}
