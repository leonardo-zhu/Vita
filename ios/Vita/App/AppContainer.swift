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

    static func live() throws -> AppContainer {
        AppContainer(
            modelContainer: try PersistenceStore.makeContainer(inMemory: false),
            secrets: KeychainSecretStore(),
            config: LayeredConfigProvider(builtin: try VitaConfig.loadBuiltin()),
            environment: try BuildEnvironment.current(),
            referenceFoods: try ReferenceFoodLoader.load()
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

    init(container: AppContainer, now: @escaping () -> Date = Date.init, timeZone: @escaping () -> TimeZone = { .current }) {
        let context = container.modelContainer.mainContext
        self.container = container
        records = RecordService(context: context, referenceFoods: container.referenceFoods, now: now, timeZone: timeZone)
        goals = GoalService(context: context, now: now)
        dayData = DayDataService(context: context, referenceFoods: container.referenceFoods, goals: goals)
    }
}
