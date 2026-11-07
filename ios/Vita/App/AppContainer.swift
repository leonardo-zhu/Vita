import Foundation

/// 依赖装配根。业务数据都在 Vita API（架构设计 §12），手机上只有 Apple 健康、体脂秤、相机，
/// 以及健康同步进度、称重队列这些本机状态。测试里换成替身。
struct AppContainer: Sendable {
    let secrets: any SecretStore
    let environment: BuildEnvironment
    /// 营养库页面浏览用的公共参考库（随 App 打包的那份）；Agent 查的是服务端那份。
    let referenceFoods: ReferenceFoodCatalog
    var healthStore: any HealthDataStore = FakeHealthDataStore(writeAuthorization: .notDetermined)
    var local: any LocalStateStore = InMemoryLocalStateStore()
    /// 1.0 的标签照片（迁移时导出）。
    var legacyLabelImages: any LabelImageStore = InMemoryLabelImageStore()
    /// 测试里换成假的 URLSession。
    var urlSession: URLSession = .shared

    var api: VitaAPIClient {
        let secrets = secrets
        return VitaAPIClient(baseURL: environment.apiBaseURL, token: { try secrets.read(.deviceToken) }, session: urlSession)
    }

    static func live() throws -> AppContainer {
        let environment = try BuildEnvironment.current()
        return AppContainer(
            secrets: KeychainSecretStore(),
            environment: environment,
            referenceFoods: try ReferenceFoodLoader.load(),
            healthStore: HealthKitDataStore(),
            local: try FileLocalStateStore.live(),
            legacyLabelImages: try FileLabelImageStore.live()
        )
    }

    static func inMemory(
        secrets: any SecretStore = InMemorySecretStore(),
        referenceFoods: ReferenceFoodCatalog = .empty,
        urlSession: URLSession = .shared
    ) throws -> AppContainer {
        AppContainer(
            secrets: secrets,
            environment: BuildEnvironment(apiBaseURL: URL(string: "https://vita-api.invalid")!),
            referenceFoods: referenceFoods,
            urlSession: urlSession
        )
    }
}

/// 主线程上的 Application Service。
@MainActor
final class AppServices {
    let container: AppContainer
    let api: VitaAPIClient
    let healthSync: HealthSyncService
    let health: HealthService
    let googleHealth: GoogleHealthService
    let bodyComposition: BodyCompositionService
    let dayData: DayDataService
    let goals: GoalService
    let foods: FoodService
    let pending: PendingService
    let chat: ChatService
    let labels: LabelScanService
    let dataReset: DataResetService

    init(container: AppContainer, now: @escaping () -> Date = Date.init, timeZone: @escaping () -> TimeZone = { .current }) {
        self.container = container
        let api = container.api
        self.api = api
        let sync = HealthSyncService(api: api, store: container.healthStore, local: container.local)
        healthSync = sync
        health = HealthService(api: api, store: container.healthStore, now: now, timeZone: timeZone)
        googleHealth = GoogleHealthService(api: api)
        bodyComposition = BodyCompositionService(api: api, store: container.healthStore, local: container.local, healthSync: sync, now: now)
        dayData = DayDataService(api: api) { sync.state(forRecord: $0) }
        goals = GoalService(api: api)
        foods = FoodService(api: api)
        pending = PendingService(api: api)
        chat = ChatService(api: api)
        labels = LabelScanService(api: api)
        dataReset = DataResetService(secrets: container.secrets, local: container.local)
    }

    /// 本机有没有设备令牌。
    var isConnected: Bool {
        ((try? container.secrets.read(.deviceToken)) ?? nil)?.isEmpty == false
    }

    /// 存下设备令牌前先调 `/v1/me` 确认它有效，返回设备名。
    func connect(token: String) async throws -> String {
        let probe = VitaAPIClient(baseURL: container.environment.apiBaseURL, token: { token }, session: container.urlSession)
        let me: MeResponseDTO = try await probe.get("/v1/me")
        try container.secrets.write(token, for: .deviceToken)
        return me.device.name
    }

    /// 1.0 的数据迁移；这台手机上没有 1.0 的库时为 nil。
    func legacyMigration() throws -> LegacyMigration? {
        guard LegacyMigration.hasLegacyData() else { return nil }
        return LegacyMigration(
            container: try LegacyMigration.open(), storeURL: LegacyMigration.defaultStoreURL,
            labelImages: container.legacyLabelImages, api: api, healthStore: container.healthStore,
            healthSync: healthSync, secrets: container.secrets
        )
    }
}
