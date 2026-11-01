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
    /// 测试默认不发任何网络请求。
    var llmClient: any LLMClient = UnavailableLLMClient()
    /// 远程配置的本地缓存；为 nil 时不拉取远程配置（测试与预览）。
    var remoteConfigCache: (any RemoteConfigCache)?
    /// 诊断日志；测试与预览默认不记录。
    var diagnostics: any DiagnosticsRecording = NoDiagnostics()

    static func live() throws -> AppContainer {
        let secrets = KeychainSecretStore()
        let environment = try BuildEnvironment.current()
        // 上次通过校验的远程配置先生效，启动后再在后台检查新版本（vita-admin.md §5）
        let remoteCache = try FileRemoteConfigCache.live()
        let cachedRemote = remoteCache.load()?.validConfig(clientVersion: AppVersion.current)
        return AppContainer(
            modelContainer: try PersistenceStore.makeContainer(inMemory: false),
            secrets: secrets,
            config: LayeredConfigProvider(builtin: try VitaConfig.loadBuiltin(), remote: cachedRemote, override: DebugOverrideStore.load()),
            environment: environment,
            referenceFoods: try ReferenceFoodLoader.load(),
            labelImages: try FileLabelImageStore.live(),
            textRecognizer: VisionTextRecognizer(),
            healthStore: HealthKitDataStore(),
            llmClient: ResponsesClient(baseURL: environment.conduitBaseURL) { try secrets.read(.conduitToken) },
            remoteConfigCache: remoteCache,
            diagnostics: DiagnosticsService(
                url: environment.diagnosticsURL, appVersion: AppVersion.current, osVersion: AppVersion.os,
                queue: try FileDiagnosticsQueue.live()
            )
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
    let chatHistory: ChatHistoryService
    let dataReset: DataResetService
    /// 远程配置的拉取；没有缓存位置（测试）或配置不是分层实现时为 nil。
    let remoteConfig: RemoteConfigService?

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
        chatHistory = ChatHistoryService(context: context, now: now, timeZone: timeZone)
        labels = LabelScanService(context: context, images: container.labelImages, recognizer: container.textRecognizer, now: now)
        if let cache = container.remoteConfigCache, let layered = container.config as? LayeredConfigProvider {
            remoteConfig = RemoteConfigService(
                url: container.environment.remoteConfigURL, clientVersion: AppVersion.current, provider: layered, cache: cache,
                diagnostics: container.diagnostics
            )
        } else {
            remoteConfig = nil
        }
        dataReset = DataResetService(context: context, secrets: container.secrets, labelImages: container.labelImages)
    }
}
