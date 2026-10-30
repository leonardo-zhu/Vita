import Foundation
import SwiftData

/// 依赖装配根。Presentation 只拿到 Application Service，不直接接触 SwiftData / Keychain；
/// 后续 LLMClient、HealthKitAdapter 在此装配，并在测试中替换为替身。
struct AppContainer: Sendable {
    let modelContainer: ModelContainer
    let secrets: any SecretStore
    let config: any ConfigProvider
    let environment: BuildEnvironment
    let referenceFoods: ReferenceFoodCatalog
    /// 测试默认用内存实现与空识别结果。
    var labelImages: any LabelImageStore = InMemoryLabelImageStore()
    var textRecognizer: any TextRecognizer = StubTextRecognizer(lines: [])
    var healthStore: any HealthDataStore = FakeHealthDataStore(writeAuthorization: .notDetermined)

    static func live() throws -> AppContainer {
        AppContainer(
            modelContainer: try PersistenceStore.makeContainer(inMemory: false),
            secrets: KeychainSecretStore(),
            config: LayeredConfigProvider(builtin: try VitaConfig.loadBuiltin()),
            environment: try BuildEnvironment.current(),
            referenceFoods: try ReferenceFoodLoader.load(),
            labelImages: try FileLabelImageStore.live(),
            textRecognizer: VisionTextRecognizer(),
            healthStore: HealthKitDataStore()
        )
    }

    static func inMemory(
        secrets: any SecretStore = InMemorySecretStore(),
        referenceFoods: ReferenceFoodCatalog = .empty
    ) throws -> AppContainer {
        AppContainer(
            modelContainer: try PersistenceStore.makeContainer(inMemory: true),
            secrets: secrets,
            config: LayeredConfigProvider(builtin: try VitaConfig.loadBuiltin()),
            environment: BuildEnvironment(conduitBaseURL: URL(string: "https://conduit.invalid")!),
            referenceFoods: referenceFoods
        )
    }
}

/// 主线程上的 Application Service，共用 `mainContext`。
@MainActor
final class AppServices {
    let container: AppContainer
    let records: RecordService
    let goals: GoalService
    let dayData: DayDataService
    let foods: FoodService
    let pending: PendingService
    let labels: LabelScanService
    let health: HealthService
    let healthSync: HealthSyncService

    init(container: AppContainer, now: @escaping () -> Date = Date.init, timeZone: @escaping () -> TimeZone = { .current }) {
        let context = container.modelContainer.mainContext
        self.container = container
        healthSync = HealthSyncService(context: context, store: container.healthStore, now: now)
        health = HealthService(context: context, store: container.healthStore, now: now, timeZone: timeZone)
        records = RecordService(context: context, referenceFoods: container.referenceFoods, now: now, timeZone: timeZone, observer: healthSync)
        goals = GoalService(context: context, now: now)
        let sync = healthSync
        dayData = DayDataService(context: context, referenceFoods: container.referenceFoods, goals: goals) { sync.state(for: $0) }
        foods = FoodService(context: context, referenceFoods: container.referenceFoods, now: now)
        pending = PendingService(context: context, records: records, foods: foods, now: now, timeZone: timeZone)
        labels = LabelScanService(context: context, images: container.labelImages, recognizer: container.textRecognizer, now: now)
    }
}
