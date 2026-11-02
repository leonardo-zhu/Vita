import Foundation

/// 模型调用的领域协议（llm-provider.md §4）。上层只认识这里的类型，不认识 URL、Bearer 头、SSE 事件名或上游 DTO。
/// 工具循环由 `ChatOrchestrator` 驱动，这里只负责一次请求。
protocol LLMClient: Sendable {
    /// 发出一次请求，按到达顺序产出文本增量、函数调用与完成事件。`streaming` 关闭时一次性产出全部事件。
    func send(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error>
}

/// 测试与预览的默认实现：不发网络请求，总是提示没有令牌。
struct UnavailableLLMClient: LLMClient {
    func send(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: LLMError.missingToken) }
    }
}

struct LLMRequest: Sendable {
    /// Conduit 的逻辑别名（如 `vita-chat`），来自生效配置。
    var model: String
    /// 系统指令：配置里的系统 prompt 加较少变化的上下文（个人食品库）。保持稳定，前缀才能命中服务商缓存。
    var instructions: String
    var input: [LLMInputItem]
    var tools: [LLMToolDefinition]
    /// 同时作为 `X-Request-Id`，用来和 Conduit 日志对应。
    var requestID: UUID
    var timeoutSeconds: Int
    var maxRetries: Int
    var streaming: Bool
    /// `reasoning.effort`；nil 表示不传。
    var reasoningEffort: String? = nil
    /// 原样合并进请求体的其他参数（远程配置 `llm.extraBody`）。
    var extraBody: [String: JSONValue] = [:]
}

/// 无状态请求的上下文：每次都由客户端完整提供（`store: false`，不用 `previous_response_id`）。
enum LLMInputItem: Equatable, Sendable {
    case user(String)
    /// 带图片的用户消息，如营养标签照片。
    case userImages(String, [LLMImage])
    /// 放在输入中间的系统消息：每轮都变的客户端状态放在这里，不打断前面可缓存的前缀。
    case system(String)
    case assistant(String)
    /// 模型上一步发出的函数调用，回传时须原样带回，才能接上对应的输出。
    case functionCall(LLMFunctionCall)
    case functionOutput(callID: String, output: String)
}

struct LLMImage: Equatable, Sendable {
    /// `data:image/jpeg;base64,…`
    var dataURL: String
    /// `input_image` 的 `detail`（low / high / xhigh）。
    var detail: String
}

struct LLMFunctionCall: Equatable, Sendable {
    var callID: String
    var name: String
    /// 原始 JSON 文本；由工具处理器解析与校验，不信任其内容。
    var arguments: String
}

struct LLMToolDefinition: Sendable {
    var name: String
    var description: String
    /// JSON Schema（`type: object`）。schema 只随客户端发布，远程配置只能改描述（vita-admin.md §3.2）。
    var parameters: JSONValue
}

enum LLMEvent: Equatable, Sendable {
    /// 模型的推理摘要增量（可能为空，只表示开始推理）。只在生成过程中展示，不保存、不回传。
    case reasoning(String)
    case textDelta(String)
    case functionCall(LLMFunctionCall)
    case completed(LLMResponseInfo)
}

/// 最小诊断信息（llm-provider.md §6）：不含令牌与内容。
struct LLMResponseInfo: Equatable, Sendable {
    var responseID: String?
    var inputTokens: Int?
    var outputTokens: Int?
    /// 输入里命中服务商缓存的部分。
    var cachedTokens: Int?
}

/// Conduit 统一错误类型加客户端自己的网络错误，各自对应不同的用户提示（llm-provider.md §6）。
/// 关联值只有机器码或简短说明，不含令牌或请求内容。
enum LLMError: Error, Equatable {
    case missingToken
    /// 401：令牌无效、过期或被吊销。
    case authentication
    /// 429：额度用尽。
    case quotaExceeded
    /// 400：参数不合法、别名不可用。
    case invalidRequest(String)
    /// 503：别名指向的上游已停用。
    case upstreamUnavailable
    /// 502：上游报错或连不上；流内错误也归到这里。
    case upstream(String)
    /// 504 或客户端等待超时。
    case timeout
    case network(String)
    case malformedResponse(String)

    /// 只有还没产出任何事件时才重试，避免重复的文本或工具调用（llm-provider.md §3）。
    var isRetryable: Bool {
        switch self {
        case .upstream, .upstreamUnavailable, .timeout, .network: true
        case .missingToken, .authentication, .quotaExceeded, .invalidRequest, .malformedResponse: false
        }
    }

    var userMessage: String {
        switch self {
        case .missingToken: "还没有设置 Conduit 访问令牌，请到设置里填写。"
        case .authentication: "Conduit 访问令牌无效或已过期，请到设置里更新。"
        case .quotaExceeded: "模型额度已用完，请稍后再试或在 Conduit 调整额度。"
        case .invalidRequest(let message): "请求没有被接受：\(message)"
        case .upstreamUnavailable: "模型服务暂时停用，请稍后再试。"
        case .upstream: "模型服务出错了，请稍后再试。"
        case .timeout: "模型响应超时，请再试一次。"
        case .network: "网络连接失败，请检查网络后再试。"
        case .malformedResponse: "模型返回的内容无法解析，请再试一次。"
        }
    }
}

/// 任意 JSON 值，用于工具 schema 与工具结果。
enum JSONValue: Equatable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    var intValue: Int? {
        if case .number(let value) = self { Int(exactly: value) } else { nil }
    }
}
