import Foundation

/// 断开这台设备：清掉设备令牌和本机状态（健康同步进度、没传上去的称重、引导标记），回到刚装好的样子。
/// 数据都在服务端，不受影响；Apple 健康里已经写进去的也不动。要清服务端的数据去 Admin。
@MainActor
final class DataResetService {
    private let secrets: any SecretStore
    private let local: any LocalStateStore
    private let defaults: UserDefaults

    init(secrets: any SecretStore, local: any LocalStateStore, defaults: UserDefaults = .standard) {
        self.secrets = secrets
        self.local = local
        self.defaults = defaults
    }

    func disconnect() throws {
        try secrets.delete(.deviceToken)
        try local.delete(HealthSyncService.stateName)
        try local.delete(BodyCompositionService.queueName)
        defaults.removeObject(forKey: OnboardingState.key)
    }
}
