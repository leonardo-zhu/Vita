import Foundation
import Testing
@testable import Vita

struct ConfigTests {
    private func builtin() throws -> VitaConfig {
        try VitaConfig.loadBuiltin(from: .main)
    }

    @Test func builtinDefaultLoadsFromAppBundle() throws {
        let config = try builtin()
        #expect(config.schemaVersion == 1)
        #expect(config.llm.modelId == "vita-chat")
        #expect((5...180).contains(config.llm.timeoutSeconds))
        #expect((0...3).contains(config.llm.maxRetries))
        #expect((1...100).contains(config.context.maxRecentMessages))
        #expect(!config.prompts.system.text.isEmpty)
    }

    @Test func builtinOnlyResolvesToBuiltinSources() throws {
        let config = try builtin()
        let effective = ConfigResolver.resolve(builtin: config, remote: nil, override: nil)
        #expect(effective.values == config)
        #expect(effective.sources.isEmpty)
        #expect(effective.source(of: .modelId) == .builtin)
    }

    @Test func remoteOverridesOnlyFieldsItCarries() throws {
        let config = try builtin()
        let remote = RemoteConfig(
            schemaVersion: 1,
            configVersion: "2026-11-01.1",
            llm: .init(modelId: "vita-chat-2", timeoutSeconds: nil, maxRetries: 2, streaming: nil)
        )
        let effective = ConfigResolver.resolve(builtin: config, remote: remote, override: nil)
        #expect(effective.values.configVersion == "2026-11-01.1")
        #expect(effective.values.llm.modelId == "vita-chat-2")
        #expect(effective.values.llm.maxRetries == 2)
        #expect(effective.values.llm.timeoutSeconds == config.llm.timeoutSeconds)
        #expect(effective.values.prompts.system == config.prompts.system)
        #expect(effective.source(of: .modelId) == .remote(configVersion: "2026-11-01.1"))
        #expect(effective.source(of: .timeoutSeconds) == .builtin)
    }

    @Test func localOverrideBeatsRemotePerField() throws {
        let config = try builtin()
        let remote = RemoteConfig(
            schemaVersion: 1,
            configVersion: "2026-11-01.1",
            llm: .init(modelId: "remote-alias", timeoutSeconds: 90, maxRetries: nil, streaming: nil),
            prompts: .init(system: PromptText(id: "agent.system", version: 7, text: "remote"), tools: nil)
        )
        let override = ConfigOverride(modelId: "local-alias", timeoutSeconds: nil, systemPromptText: "local")
        let effective = ConfigResolver.resolve(builtin: config, remote: remote, override: override)
        #expect(effective.values.llm.modelId == "local-alias")
        #expect(effective.source(of: .modelId) == .localOverride)
        #expect(effective.values.llm.timeoutSeconds == 90)
        #expect(effective.source(of: .timeoutSeconds) == .remote(configVersion: "2026-11-01.1"))
        // 覆盖只换文本，prompt 的 id 与版本仍来自下一层，便于审计。
        #expect(effective.values.prompts.system == PromptText(id: "agent.system", version: 7, text: "local"))
        #expect(effective.source(of: .systemPrompt) == .localOverride)
    }

    @Test func remoteCannotAddUnknownToolsOrFeatures() throws {
        var config = try builtin()
        config.prompts.tools = ["searchReferenceFoods": ToolPrompt(version: 1, description: "builtin")]
        config.features = ["knownFlag": false]
        let remote = RemoteConfig(
            schemaVersion: 1,
            configVersion: "2026-11-01.1",
            prompts: .init(system: nil, tools: [
                "searchReferenceFoods": ToolPrompt(version: 2, description: "remote"),
                "deleteEverything": ToolPrompt(version: 1, description: "injected"),
            ]),
            features: ["knownFlag": true, "unknownFlag": true]
        )
        let effective = ConfigResolver.resolve(builtin: config, remote: remote, override: nil)
        #expect(effective.values.prompts.tools.keys.sorted() == ["searchReferenceFoods"])
        #expect(effective.values.prompts.tools["searchReferenceFoods"]?.description == "remote")
        #expect(effective.values.features == ["knownFlag": true])
    }

    @Test func remoteIgnoresUnknownJSONFields() throws {
        let json = #"{"schemaVersion":1,"configVersion":"2026-11-01.1","llm":{"modelId":"x","future":1},"brandNew":{}}"#
        let remote = try JSONDecoder().decode(RemoteConfig.self, from: Data(json.utf8))
        #expect(remote.llm?.modelId == "x")
        #expect(remote.context == nil)
    }

    @Test func layeredProviderPicksUpNewLayers() throws {
        let provider = LayeredConfigProvider(builtin: try builtin())
        #expect(provider.effectiveConfig().values.llm.modelId == "vita-chat")
        provider.setOverride(ConfigOverride(modelId: "debug"))
        #expect(provider.effectiveConfig().values.llm.modelId == "debug")
        provider.setOverride(nil)
        #expect(provider.effectiveConfig().source(of: .modelId) == .builtin)
    }
}

struct BuildEnvironmentTests {
    @Test func appBundleCarriesConduitBaseURL() throws {
        let environment = try BuildEnvironment.current(bundle: .main)
        #expect(environment.conduitBaseURL.scheme == "https")
    }

    @Test func rejectsMissingInsecureAndUnexpandedValues() {
        #expect(throws: BuildEnvironmentError.missingConduitBaseURL) {
            try BuildEnvironment.load(from: [:])
        }
        #expect(throws: BuildEnvironmentError.invalidConduitBaseURL("http://example.com")) {
            try BuildEnvironment.load(from: [BuildEnvironment.conduitBaseURLKey: "http://example.com"])
        }
        #expect(throws: BuildEnvironmentError.invalidConduitBaseURL("$(CONDUIT_BASE_URL)")) {
            try BuildEnvironment.load(from: [BuildEnvironment.conduitBaseURLKey: "$(CONDUIT_BASE_URL)"])
        }
    }
}
