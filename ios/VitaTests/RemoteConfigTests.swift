import Foundation
import Testing
@testable import Vita

struct RemoteConfigValidatorTests {
    private func config(_ version: String = "2026-11-01.1", mutate: (inout RemoteConfig) -> Void = { _ in }) -> RemoteConfig {
        var config = RemoteConfig(schemaVersion: 1, configVersion: version)
        config.llm = .init(modelId: "vita-chat", timeoutSeconds: 60, maxRetries: 1, streaming: true)
        mutate(&config)
        return config
    }

    @Test func comparesConfigVersionsNumerically() {
        #expect(ConfigVersion.compare("2026-11-01.10", "2026-11-01.9") == .orderedDescending)
        #expect(ConfigVersion.compare("2026-10-31.9", "2026-11-01.1") == .orderedAscending)
        #expect(ConfigVersion.compare("2026-11-01.2", "2026-11-01.2") == .orderedSame)
        #expect(ConfigVersion.compare("latest", "2026-11-01.1") == nil)
    }

    @Test func acceptsAValidConfig() throws {
        try RemoteConfigValidator.validate(config(), clientVersion: "0.1.0", current: "2026-10-31.3")
    }

    @Test func rejectsEachOutOfRangeField() {
        let cases: [(RemoteConfig, RemoteConfigRejection)] = [
            (config { $0.schemaVersion = 2 }, .unsupportedSchema(2)),
            (config { $0.minClientVersion = "0.2.0" }, .clientTooOld(minimum: "0.2.0")),
            (config("next"), .malformedVersion("next")),
            (config { $0.llm?.timeoutSeconds = 1 }, .invalidField("llm.timeoutSeconds")),
            (config { $0.llm?.maxRetries = 4 }, .invalidField("llm.maxRetries")),
            (config { $0.llm?.modelId = "" }, .invalidField("llm.modelId")),
            (config { $0.context = .init(maxRecentMessages: 0) }, .invalidField("context.maxRecentMessages")),
            (config { $0.prompts = .init(system: PromptText(id: "agent.system", version: 4, text: "")) }, .invalidField("prompts.system.text")),
        ]
        for (config, rejection) in cases {
            #expect(throws: rejection) {
                try RemoteConfigValidator.validate(config, clientVersion: "0.1.0", current: nil)
            }
        }
    }

    @Test func rejectsReplayOfAnOlderVersion() {
        #expect(throws: RemoteConfigRejection.olderThanCurrent("2026-11-01.1")) {
            try RemoteConfigValidator.validate(config(), clientVersion: "0.1.0", current: "2026-11-01.2")
        }
    }
}

@MainActor
struct RemoteConfigServiceTests {
    private static let url = URL(string: "https://vita.example/config/stable.json")!

    private final class FakeHTTP: RemoteConfigHTTP, @unchecked Sendable {
        var responses: [(Int, String, [String: String])]
        private(set) var requests: [URLRequest] = []
        var delay: Duration = .zero

        init(_ responses: [(Int, String, [String: String])]) {
            self.responses = responses
        }

        func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            if delay != .zero { try await Task.sleep(for: delay) }
            let (status, body, headers) = responses.removeFirst()
            if status == 0 { throw URLError(.timedOut) }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (Data(body.utf8), response)
        }
    }

    private func body(_ version: String, modelId: String = "vita-remote") -> String {
        #"{"schemaVersion":1,"configVersion":"\#(version)","channel":"stable","llm":{"modelId":"\#(modelId)","timeoutSeconds":90,"maxRetries":1,"streaming":true},"context":{"maxRecentMessages":20,"includePersonalFoodSummary":true},"prompts":{"tools":{}},"features":{}}"#
    }

    private func make(_ http: FakeHTTP, cache: InMemoryRemoteConfigCache = .init()) throws -> (RemoteConfigService, LayeredConfigProvider, InMemoryRemoteConfigCache) {
        let provider = LayeredConfigProvider(builtin: try VitaConfig.loadBuiltin(from: .main))
        let service = RemoteConfigService(url: Self.url, clientVersion: "0.1.0", provider: provider, cache: cache, http: http)
        return (service, provider, cache)
    }

    @Test func appliesANewConfigAndCachesItWithItsETag() async throws {
        let http = FakeHTTP([(200, body("2026-11-01.1"), ["ETag": "\"abc\""])])
        let (service, provider, cache) = try make(http)

        #expect(await service.refresh() == .updated("2026-11-01.1"))
        #expect(provider.effectiveConfig().values.llm.modelId == "vita-remote")
        #expect(provider.effectiveConfig().source(of: .modelId) == .remote(configVersion: "2026-11-01.1"))
        #expect(cache.load()?.etag == "\"abc\"")
        #expect(service.lastCheckedAt != nil)
        #expect(http.requests[0].value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func sendsTheETagAndTreats304AsUnchanged() async throws {
        let http = FakeHTTP([(200, body("2026-11-01.1"), ["ETag": "\"abc\""]), (304, "", [:])])
        let (service, provider, _) = try make(http)
        await service.refresh()

        #expect(await service.refresh() == .unchanged)
        #expect(http.requests[1].value(forHTTPHeaderField: "If-None-Match") == "\"abc\"")
        #expect(provider.effectiveConfig().values.configVersion == "2026-11-01.1")
    }

    @Test func keepsTheCurrentConfigWhenTheNewOneIsInvalidOrOlder() async throws {
        let http = FakeHTTP([
            (200, body("2026-11-01.2"), [:]),
            (200, body("2026-11-01.3", modelId: ""), [:]),
            (200, body("2026-11-01.1"), [:]),
            (500, "", [:]),
            (0, "", [:]),
        ])
        let (service, provider, cache) = try make(http)
        await service.refresh()

        #expect(await service.refresh() == .failed("config.invalid.llm.modelId"))
        #expect(await service.refresh() == .failed("config.older_than_current"))
        #expect(await service.refresh() == .failed("config.http_500"))
        #expect(await service.refresh() == .failed("config.network"))
        #expect(provider.effectiveConfig().values.configVersion == "2026-11-01.2")
        #expect(cache.load()?.configVersion == "2026-11-01.2")
    }

    @Test func sameVersionWithA200IsUnchanged() async throws {
        let http = FakeHTTP([(200, body("2026-11-01.1"), [:]), (200, body("2026-11-01.1"), [:])])
        let (service, _, _) = try make(http)
        await service.refresh()
        #expect(await service.refresh() == .unchanged)
    }

    @Test func concurrentRefreshesShareOneRequest() async throws {
        let http = FakeHTTP([(200, body("2026-11-01.1"), [:])])
        http.delay = .milliseconds(50)
        let (service, _, _) = try make(http)

        async let first = service.refresh()
        async let second = service.refresh()
        let outcomes = await [first, second]
        #expect(outcomes == [.updated("2026-11-01.1"), .updated("2026-11-01.1")])
        #expect(http.requests.count == 1)
    }

    @Test func cachedConfigIsRevalidatedAtLaunch() throws {
        let entry = RemoteConfigCacheEntry(
            body: Data(body("2026-11-01.1").utf8), etag: nil, configVersion: "2026-11-01.1", lastCheckedAt: .now
        )
        #expect(entry.validConfig(clientVersion: "0.1.0")?.configVersion == "2026-11-01.1")

        var tooNew = entry
        tooNew.body = Data(body("2026-11-01.1").replacingOccurrences(of: #""channel""#, with: #""minClientVersion":"9.0.0","channel""#).utf8)
        #expect(tooNew.validConfig(clientVersion: "0.1.0") == nil)
    }
}
