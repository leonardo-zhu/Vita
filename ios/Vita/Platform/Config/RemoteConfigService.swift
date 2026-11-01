import Foundation
import Observation
import os

/// 拉取远程配置的 HTTP 层，测试里替换为替身。
protocol RemoteConfigHTTP: Sendable {
    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// 只认构建配置里的那一个地址：重定向到其他主机直接拒绝（vita-admin.md §7）。
final class URLSessionRemoteConfigHTTP: NSObject, RemoteConfigHTTP, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard request.url?.scheme == "https", request.url?.host() == task.originalRequest?.url?.host() else { return nil }
        return request
    }
}

/// 远程配置（L2）的拉取与生效（vita-admin.md §5）。
///
/// - 不轮询：启动、每次回到前台、设置页“立即刷新”时检查，带 ETag，文件没变时服务器回 304。
/// - 同一时刻只跑一次，进行中的再次触发直接等那一次的结果。
/// - 通过校验才写缓存并交给 `LayeredConfigProvider`；生效时机由读取方决定（新一轮对话开始时读）。
/// - 任何失败都保留当前配置，不打扰用户，只记日志并在设置页显示。
@MainActor
@Observable
final class RemoteConfigService {
    enum Outcome: Equatable {
        case updated(String)
        case unchanged
        case failed(String)
    }

    private(set) var lastCheckedAt: Date?
    private(set) var lastOutcome: Outcome?
    private(set) var isRefreshing = false

    @ObservationIgnored private let url: URL
    @ObservationIgnored private let clientVersion: String
    @ObservationIgnored private let provider: LayeredConfigProvider
    @ObservationIgnored private let cache: any RemoteConfigCache
    @ObservationIgnored private let http: any RemoteConfigHTTP
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var inFlight: Task<Outcome, Never>?

    private static let log = Logger(subsystem: "com.leonardo.vita", category: "config.remote")
    static let timeout: TimeInterval = 5

    init(
        url: URL, clientVersion: String, provider: LayeredConfigProvider, cache: any RemoteConfigCache,
        http: any RemoteConfigHTTP = URLSessionRemoteConfigHTTP(), now: @escaping () -> Date = Date.init
    ) {
        self.url = url
        self.clientVersion = clientVersion
        self.provider = provider
        self.cache = cache
        self.http = http
        self.now = now
        lastCheckedAt = cache.load()?.lastCheckedAt
    }

    @discardableResult
    func refresh() async -> Outcome {
        if let inFlight { return await inFlight.value }
        let task = Task { await fetch() }
        inFlight = task
        isRefreshing = true
        let outcome = await task.value
        inFlight = nil
        isRefreshing = false
        lastOutcome = outcome
        return outcome
    }

    private func fetch() async -> Outcome {
        let cached = cache.load()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.httpMethod = "GET"
        // 只有缓存还有效时才带 ETag；否则拿完整文件重新校验
        if let cached, cached.validConfig(clientVersion: clientVersion) != nil, let etag = cached.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.get(request)
        } catch {
            return fail("config.network", detail: error.localizedDescription)
        }

        let checkedAt = now()
        switch response.statusCode {
        case 304:
            if var cached {
                cached.lastCheckedAt = checkedAt
                try? cache.save(cached)
            }
            lastCheckedAt = checkedAt
            return .unchanged
        case 200:
            break
        default:
            return fail("config.http_\(response.statusCode)")
        }

        do {
            let config = try RemoteConfigValidator.decode(data)
            let current = cached?.validConfig(clientVersion: clientVersion)?.configVersion
            try RemoteConfigValidator.validate(config, clientVersion: clientVersion, current: current)
            let etag = response.value(forHTTPHeaderField: "ETag")
            try cache.save(RemoteConfigCacheEntry(body: data, etag: etag, configVersion: config.configVersion, lastCheckedAt: checkedAt))
            lastCheckedAt = checkedAt
            if config.configVersion == current { return .unchanged }
            provider.setRemote(config)
            Self.log.info("config -> \(config.configVersion, privacy: .public)")
            return .updated(config.configVersion)
        } catch let rejection as RemoteConfigRejection {
            return fail(rejection.code)
        } catch {
            return fail("config.cache_write", detail: error.localizedDescription)
        }
    }

    private func fail(_ code: String, detail: String = "") -> Outcome {
        Self.log.error("config fetch failed: \(code, privacy: .public) \(detail, privacy: .public)")
        return .failed(code)
    }
}
