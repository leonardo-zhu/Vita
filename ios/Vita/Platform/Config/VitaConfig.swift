import Foundation

/// 带版本的 prompt 文本（vita-admin.md §4）。
struct PromptText: Equatable, Codable, Sendable {
    var id: String
    var version: Int
    var text: String
}

/// 工具描述文字。远程只能改描述，不能新增工具或改参数 schema（vita-admin.md §3.2）。
struct ToolPrompt: Equatable, Codable, Sendable {
    var version: Int
    var description: String
}

/// 完整的一份配置：内置默认值（L1）就是这个形状，生效配置也是。
struct VitaConfig: Equatable, Codable, Sendable {
    struct LLM: Equatable, Codable, Sendable {
        /// Conduit 的逻辑别名，如 `vita-chat`。
        var modelId: String
        var timeoutSeconds: Int
        var maxRetries: Int
        var streaming: Bool
        /// Responses 的 `reasoning.effort`；`default` 表示不传，用模型自己的默认值。
        var reasoningEffort: String
        /// 原样合并进请求体的其他参数，键已在校验时排除客户端自己管理的字段。
        var extraBody: [String: JSONValue]
    }

    struct Context: Equatable, Codable, Sendable {
        var maxRecentMessages: Int
        var includePersonalFoodSummary: Bool
    }

    struct Prompts: Equatable, Codable, Sendable {
        var system: PromptText
        var tools: [String: ToolPrompt]
    }

    /// 营养标签照片发给模型前的缩放与压缩。
    struct LabelImage: Equatable, Codable, Sendable {
        var maxDimension: Int
        var jpegQuality: Double
        /// Responses `input_image` 的 `detail`。
        var detail: String
    }

    var schemaVersion: Int
    var configVersion: String
    var llm: LLM
    var context: Context
    var prompts: Prompts
    var labelImage: LabelImage
    /// 开关只能启用或关闭已随客户端发布的能力：键集合以内置默认值为准。
    var features: [String: Bool]

    static let builtinResourceName = "DefaultConfig"

    /// 读取打包进 App 的内置默认值。它是构建产物，读取失败说明构建有误，由调用方按启动失败处理。
    static func loadBuiltin(from bundle: Bundle = .main) throws -> VitaConfig {
        guard let url = bundle.url(forResource: builtinResourceName, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(VitaConfig.self, from: Data(contentsOf: url))
    }
}

/// L2 远程配置。缺失的字段回落到下一层；未知字段在解码时忽略（vita-admin.md §4）。
/// 拉取见 `RemoteConfigService`，§6 校验见 `RemoteConfigValidator`。
struct RemoteConfig: Equatable, Codable, Sendable {
    struct LLM: Equatable, Codable, Sendable {
        var modelId: String?
        var timeoutSeconds: Int?
        var maxRetries: Int?
        var streaming: Bool?
        var reasoningEffort: String?
        var extraBody: [String: JSONValue]?
    }

    struct Context: Equatable, Codable, Sendable {
        var maxRecentMessages: Int?
        var includePersonalFoodSummary: Bool?
    }

    struct Prompts: Equatable, Codable, Sendable {
        var system: PromptText?
        var tools: [String: ToolPrompt]?
    }

    struct LabelImage: Equatable, Codable, Sendable {
        var maxDimension: Int?
        var jpegQuality: Double?
        var detail: String?
    }

    var schemaVersion: Int
    var configVersion: String
    var minClientVersion: String?
    var channel: String?
    var llm: LLM?
    var context: Context?
    var prompts: Prompts?
    var labelImage: LabelImage?
    var features: [String: Bool]?
}

/// L3 本地调试覆盖，范围限定在 vita-admin.md §9（渠道选择属于拉取参数，随 Phase 5 加入）。
struct ConfigOverride: Equatable, Codable, Sendable {
    var modelId: String?
    var timeoutSeconds: Int?
    var systemPromptText: String?
}
