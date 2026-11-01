import Foundation
import SwiftData
import Testing
@testable import Vita

@MainActor
struct DataResetTests {
    let store = FakeHealthDataStore(writeAuthorization: .authorized)
    let secrets = InMemorySecretStore()
    let images = InMemoryLabelImageStore()
    let defaults: UserDefaults
    let container: AppContainer
    let services: AppServices
    let reset: DataResetService

    init() throws {
        var container = try AppContainer.inMemory(secrets: secrets, referenceFoods: try Fixtures.referenceFoods())
        container.healthStore = store
        container.labelImages = images
        self.container = container
        services = AppServices(container: container, now: { Fixtures.now }, timeZone: { Fixtures.shanghai })
        defaults = UserDefaults(suiteName: "DataResetTests-\(UUID().uuidString)")!
        reset = DataResetService(
            context: container.modelContainer.mainContext, secrets: secrets,
            labelImages: images, defaults: defaults
        )
    }

    private var context: ModelContext { container.modelContainer.mainContext }

    /// 一条已同步的记录、一个目标、一张标签照片、令牌、引导标记与调试覆盖。
    private func seed() async throws -> String {
        try services.records.createRecord(on: Fixtures.day, expectedRevision: 0, draft: try .lunch([.estimate(kcal: 500)]))
        await services.healthSync.run()
        try services.goals.updateGoal(GoalTargets(energyKcal: 2000), effectiveFrom: Fixtures.day)
        let image = try images.save(Data("label".utf8))
        try secrets.write("token-1234", for: .conduitToken)
        defaults.set(true, forKey: OnboardingState.key)
        DebugOverrideStore.save(ConfigOverride(modelId: "debug-alias"), to: defaults)
        return image
    }

    @Test func defaultSelectionKeepsTheToken() async throws {
        let image = try await seed()
        try reset.reset(DataResetPart.defaultSelection)

        #expect(try context.fetchCount(FetchDescriptor<ConsumptionRecord>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<HealthSyncMapping>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<DailyGoal>()) == 0)
        // Apple 健康不动。
        #expect(!store.samples.isEmpty)
        #expect(try images.load(image) == nil)
        #expect(defaults.object(forKey: OnboardingState.key) == nil)
        #expect(DebugOverrideStore.load(from: defaults) == nil)
        #expect(try secrets.read(.conduitToken) == "token-1234")
    }

    @Test func onlySelectedPartsAreCleared() async throws {
        _ = try await seed()
        try reset.reset([.goals])

        #expect(try context.fetchCount(FetchDescriptor<DailyGoal>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ConsumptionRecord>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<HealthSyncMapping>()) == 1)
        #expect(DebugOverrideStore.load(from: defaults) != nil)
    }

    @Test func everythingAlsoClearsTokenAndDefaults() async throws {
        _ = try await seed()
        defaults.set("x", forKey: "vita.some.future.key")
        try reset.resetEverything()

        #expect(try secrets.read(.conduitToken) == nil)
        #expect(defaults.object(forKey: "vita.some.future.key") == nil)
        #expect(try context.fetchCount(FetchDescriptor<DaySession>()) == 0)
        #expect(!store.samples.isEmpty)
    }
}
