import Foundation

/// configVersion `YYYY-MM-DD.n` 的比较：先比日期再按数字比序号，不能按字符串比（`.10` 会排在 `.9` 前面）。
/// 规则与 Admin 的 `admin/src/server/config/version.ts` 相同。
enum ConfigVersion {
    /// 格式不对返回 nil。
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let a = parse(lhs), let b = parse(rhs) else { return nil }
        if a.date != b.date { return a.date < b.date ? .orderedAscending : .orderedDescending }
        if a.n != b.n { return a.n < b.n ? .orderedAscending : .orderedDescending }
        return .orderedSame
    }

    private static func parse(_ value: String) -> (date: String, n: Int)? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 10, let n = Int(parts[1]), n >= 0,
              parts[0].allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "-") }) else { return nil }
        return (String(parts[0]), n)
    }
}

/// `x.y.z` 的版本比较，用于 `minClientVersion`。
enum SemanticVersion {
    static func isAtLeast(_ version: String, minimum: String) -> Bool? {
        guard let v = parse(version), let m = parse(minimum) else { return nil }
        return v.lexicographicallyPrecedes(m) == false
    }

    private static func parse(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".").map { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return parts.compactMap { $0 }
    }
}

enum RemoteConfigRejection: Error, Equatable {
    case undecodable
    case unsupportedSchema(Int)
    case clientTooOld(minimum: String)
    case malformedVersion(String)
    /// 比当前缓存旧：防止被旧文件回放（vita-admin.md §5）。
    case olderThanCurrent(String)
    case invalidField(String)

    /// 写日志与设置页用的错误码。
    var code: String {
        switch self {
        case .undecodable: "config.undecodable"
        case .unsupportedSchema: "config.unsupported_schema"
        case .clientTooOld: "config.client_too_old"
        case .malformedVersion: "config.malformed_version"
        case .olderThanCurrent: "config.older_than_current"
        case .invalidField(let field): "config.invalid.\(field)"
        }
    }
}

/// 远程配置生效前的校验（vita-admin.md §6），任何一项不过整份拒绝。
/// 与 `shared/config-schema/config.schema.json` 的取值范围一致；未知工具名不在这里拒绝，由 `ConfigResolver` 忽略。
enum RemoteConfigValidator {
    static let supportedSchemaVersion = 1

    static func decode(_ data: Data) throws -> RemoteConfig {
        do {
            return try JSONDecoder().decode(RemoteConfig.self, from: data)
        } catch {
            throw RemoteConfigRejection.undecodable
        }
    }

    /// `current` 是当前缓存的 configVersion；比它旧的拒绝，相同的由调用方当作没有变化。
    static func validate(_ config: RemoteConfig, clientVersion: String, current: String?) throws {
        guard config.schemaVersion <= supportedSchemaVersion else {
            throw RemoteConfigRejection.unsupportedSchema(config.schemaVersion)
        }
        if let minimum = config.minClientVersion {
            guard let ok = SemanticVersion.isAtLeast(clientVersion, minimum: minimum) else {
                throw RemoteConfigRejection.invalidField("minClientVersion")
            }
            if !ok { throw RemoteConfigRejection.clientTooOld(minimum: minimum) }
        }
        guard ConfigVersion.compare(config.configVersion, config.configVersion) != nil else {
            throw RemoteConfigRejection.malformedVersion(config.configVersion)
        }
        if let current, ConfigVersion.compare(config.configVersion, current) == .orderedAscending {
            throw RemoteConfigRejection.olderThanCurrent(config.configVersion)
        }

        func require(_ condition: Bool, _ field: String) throws {
            if !condition { throw RemoteConfigRejection.invalidField(field) }
        }
        if let llm = config.llm {
            if let modelId = llm.modelId { try require((1...128).contains(modelId.count), "llm.modelId") }
            if let timeout = llm.timeoutSeconds { try require((5...180).contains(timeout), "llm.timeoutSeconds") }
            if let retries = llm.maxRetries { try require((0...3).contains(retries), "llm.maxRetries") }
        }
        if let messages = config.context?.maxRecentMessages {
            try require((1...100).contains(messages), "context.maxRecentMessages")
        }
        if let system = config.prompts?.system {
            try require(!system.id.isEmpty && system.version >= 1, "prompts.system")
            try require((1...20_000).contains(system.text.count), "prompts.system.text")
        }
        for (name, tool) in config.prompts?.tools ?? [:] {
            try require(tool.version >= 1 && (1...2_000).contains(tool.description.count), "prompts.tools.\(name)")
        }
    }
}
