import Foundation

/// Google 健康：Google 健康 App 不往 Apple 健康写活动能量与睡眠，改由服务端用 Google Health API 拉。
/// 连接、同步、断开都在 Vita Admin 里做（是服务端的配置）；手机只看状态。健康数据接口返回的这两项会标成 googleHealth。
@MainActor
final class GoogleHealthService {
    private let api: VitaAPIClient

    init(api: VitaAPIClient) {
        self.api = api
    }

    func status() async throws -> GoogleHealthStatusDTO {
        try await api.get("/v1/google-health")
    }
}
