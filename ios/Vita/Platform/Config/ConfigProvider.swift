import Foundation

enum ConfigSource: Equatable, Sendable {
    case builtin
    case remote(configVersion: String)
    case localOverride
}

enum ConfigField: Hashable, Sendable {
    case modelId, timeoutSeconds, maxRetries, streaming
    case maxRecentMessages, includePersonalFoodSummary
    case systemPrompt
    case toolPrompt(String)
    case feature(String)
}

/// 生效配置：每个字段取优先级最高的一层，并记下来源，供调试页与审计使用（vita-admin.md §9 / §10）。
struct EffectiveConfig: Equatable, Sendable {
    var values: VitaConfig
    var sources: [ConfigField: ConfigSource]

    func source(of field: ConfigField) -> ConfigSource {
        sources[field] ?? .builtin
    }
}

/// 业务层只依赖此协议（vita-admin.md §10）。新配置只在新一轮对话开始时读取，由调用方决定读取时机。
protocol ConfigProvider: Sendable {
    func effectiveConfig() -> EffectiveConfig
}

enum ConfigResolver {
    /// 按字段合并：本地覆盖 > 远程 > 内置（vita-admin.md §2）。远程配置须在传入前通过验签与校验。
    static func resolve(builtin: VitaConfig, remote: RemoteConfig?, override: ConfigOverride?) -> EffectiveConfig {
        var values = builtin
        var sources: [ConfigField: ConfigSource] = [:]

        func apply<T>(_ value: T?, to keyPath: WritableKeyPath<VitaConfig, T>, field: ConfigField, source: ConfigSource) {
            guard let value else { return }
            values[keyPath: keyPath] = value
            sources[field] = source
        }

        if let remote {
            let source = ConfigSource.remote(configVersion: remote.configVersion)
            values.configVersion = remote.configVersion
            apply(remote.llm?.modelId, to: \.llm.modelId, field: .modelId, source: source)
            apply(remote.llm?.timeoutSeconds, to: \.llm.timeoutSeconds, field: .timeoutSeconds, source: source)
            apply(remote.llm?.maxRetries, to: \.llm.maxRetries, field: .maxRetries, source: source)
            apply(remote.llm?.streaming, to: \.llm.streaming, field: .streaming, source: source)
            apply(remote.context?.maxRecentMessages, to: \.context.maxRecentMessages, field: .maxRecentMessages, source: source)
            apply(
                remote.context?.includePersonalFoodSummary,
                to: \.context.includePersonalFoodSummary, field: .includePersonalFoodSummary, source: source
            )
            apply(remote.prompts?.system, to: \.prompts.system, field: .systemPrompt, source: source)
            // 只接受客户端已知的工具与开关，未知键忽略。
            for (name, prompt) in remote.prompts?.tools ?? [:] where builtin.prompts.tools[name] != nil {
                apply(prompt, to: \.prompts.tools[name], field: .toolPrompt(name), source: source)
            }
            for (name, enabled) in remote.features ?? [:] where builtin.features[name] != nil {
                apply(enabled, to: \.features[name], field: .feature(name), source: source)
            }
        }

        if let override {
            apply(override.modelId, to: \.llm.modelId, field: .modelId, source: .localOverride)
            apply(override.timeoutSeconds, to: \.llm.timeoutSeconds, field: .timeoutSeconds, source: .localOverride)
            apply(override.systemPromptText, to: \.prompts.system.text, field: .systemPrompt, source: .localOverride)
        }

        return EffectiveConfig(values: values, sources: sources)
    }
}

/// 持有三层并按需合并。Phase 5 的拉取与调试页通过 `setRemote` / `setOverride` 更新层；
/// 测试直接使用它作为内存实现。
final class LayeredConfigProvider: ConfigProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let builtin: VitaConfig
    private var remote: RemoteConfig?
    private var override: ConfigOverride?

    init(builtin: VitaConfig, remote: RemoteConfig? = nil, override: ConfigOverride? = nil) {
        self.builtin = builtin
        self.remote = remote
        self.override = override
    }

    func setRemote(_ remote: RemoteConfig?) {
        lock.withLock { self.remote = remote }
    }

    func setOverride(_ override: ConfigOverride?) {
        lock.withLock { self.override = override }
    }

    func effectiveConfig() -> EffectiveConfig {
        lock.withLock { ConfigResolver.resolve(builtin: builtin, remote: remote, override: override) }
    }
}
