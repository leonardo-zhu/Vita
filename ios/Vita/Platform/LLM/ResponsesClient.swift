import Foundation

/// `LLMClient` 的唯一生产实现：经 Conduit 的 `/v1/responses` 调用模型（llm-provider.md §1）。
/// 用 `URLSession` + `Codable` 自己实现无状态子集：`store: false`、SSE 流式文本与 function calling。
struct ResponsesClient: LLMClient {
    let baseURL: URL
    /// 每次请求时读取，令牌更新后不必重建客户端。返回 nil 表示还没设置。
    let token: @Sendable () throws -> String?
    var session: URLSession = .shared
    /// 重试前的等待；测试里设为 0。
    var retryDelay: Duration = .seconds(1)

    func send(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var attempt = 0
                while true {
                    var yielded = false
                    do {
                        try await perform(request) { event in
                            yielded = true
                            continuation.yield(event)
                        }
                        continuation.finish()
                        return
                    } catch let error as LLMError where error.isRetryable && !yielded && attempt < request.maxRetries {
                        attempt += 1
                        try? await Task.sleep(for: retryDelay)
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func perform(_ request: LLMRequest, yield: (LLMEvent) -> Void) async throws {
        guard let token = try? token(), !token.isEmpty else { throw LLMError.missingToken }
        let urlRequest = try makeURLRequest(request, token: token)
        do {
            if request.streaming {
                let (bytes, response) = try await session.bytes(for: urlRequest)
                try await Self.check(response) { try await Self.collect(bytes) }
                var parser = ResponsesStreamParser()
                for try await line in bytes.lines {
                    try parser.consume(line: line).forEach(yield)
                }
                try parser.finish().forEach(yield)
            } else {
                let (data, response) = try await session.data(for: urlRequest)
                try await Self.check(response) { data }
                try ResponsesStreamParser.events(fromResponse: data).forEach(yield)
            }
        } catch let error as URLError {
            throw Self.map(error)
        }
    }

    private func makeURLRequest(_ request: LLMRequest, token: String) throws -> URLRequest {
        var urlRequest = URLRequest(url: baseURL.appending(path: "v1/responses"))
        urlRequest.httpMethod = "POST"
        // 流式时是两次数据之间的最长等待，非流式时是等完整响应的时间。
        urlRequest.timeoutInterval = TimeInterval(request.timeoutSeconds)
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(request.requestID.uuidString, forHTTPHeaderField: "X-Request-Id")
        if request.streaming { urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        urlRequest.httpBody = try JSONEncoder().encode(ResponsesRequestBody(request))
        return urlRequest
    }

    // MARK: - 错误

    /// 非 2xx 时读出错误体，按 Conduit 的 `error.type` 映射；读不出时按状态码。
    private static func check(_ response: URLResponse, body: () async throws -> Data) async throws {
        guard let http = response as? HTTPURLResponse else { throw LLMError.malformedResponse("not http") }
        guard !(200..<300).contains(http.statusCode) else { return }
        let data = (try? await body()) ?? Data()
        let failure = try? JSONDecoder().decode(ErrorBody.self, from: data).error
        throw map(type: failure?.type, message: failure?.message, status: http.statusCode)
    }

    private static func collect(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > 64 * 1024 { break }
        }
        return data
    }

    static func map(type: String?, message: String?, status: Int) -> LLMError {
        switch type {
        case "authentication_error": return .authentication
        case "insufficient_quota": return .quotaExceeded
        case "invalid_request_error": return .invalidRequest(message ?? "invalid request")
        case "upstream_unavailable": return .upstreamUnavailable
        case "upstream_timeout": return .timeout
        case "upstream_error": return .upstream(message ?? "upstream error")
        default: break
        }
        return switch status {
        case 401, 403: .authentication
        case 429: .quotaExceeded
        case 400..<500: .invalidRequest(message ?? "HTTP \(status)")
        case 503: .upstreamUnavailable
        case 504: .timeout
        default: .upstream(message ?? "HTTP \(status)")
        }
    }

    private static func map(_ error: URLError) -> Error {
        switch error.code {
        case .cancelled: CancellationError()
        case .timedOut: LLMError.timeout
        default: LLMError.network(error.code.rawValue.description)
        }
    }

    private struct ErrorBody: Decodable {
        struct Failure: Decodable {
            var type: String?
            var code: String?
            var message: String?
        }

        var error: Failure
    }
}

// MARK: - 请求体

/// Responses API 请求体。消息用简写形式（`role` + 字符串 `content`），函数调用与输出用 item 形式。
struct ResponsesRequestBody: Encodable {
    var model: String
    var instructions: String
    var input: [Item]
    var tools: [Tool]
    var stream: Bool
    /// 无状态：Conduit 首期不保存会话，也不接受 `previous_response_id`（llm-provider.md §5）。
    var store = false

    init(_ request: LLMRequest) {
        model = request.model
        instructions = request.instructions
        input = request.input.map(Item.init)
        tools = request.tools.map { Tool(name: $0.name, description: $0.description, parameters: $0.parameters) }
        stream = request.streaming
    }

    struct Tool: Encodable {
        var type = "function"
        var name: String
        var description: String
        var parameters: JSONValue
    }

    struct Item: Encodable {
        var type: String?
        var role: String?
        var content: String?
        var callID: String?
        var name: String?
        var arguments: String?
        var output: String?

        enum CodingKeys: String, CodingKey {
            case type, role, content, name, arguments, output
            case callID = "call_id"
        }

        init(_ item: LLMInputItem) {
            switch item {
            case .user(let text):
                role = "user"
                content = text
            case .assistant(let text):
                role = "assistant"
                content = text
            case .functionCall(let call):
                type = "function_call"
                callID = call.callID
                name = call.name
                arguments = call.arguments
            case .functionOutput(let callID, let output):
                type = "function_call_output"
                self.callID = callID
                self.output = output
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(type, forKey: .type)
            try container.encodeIfPresent(role, forKey: .role)
            try container.encodeIfPresent(content, forKey: .content)
            try container.encodeIfPresent(callID, forKey: .callID)
            try container.encodeIfPresent(name, forKey: .name)
            try container.encodeIfPresent(arguments, forKey: .arguments)
            try container.encodeIfPresent(output, forKey: .output)
        }
    }
}

// MARK: - 响应解析

/// 把 SSE 的 `data:` 行转成 `LLMEvent`。Responses 的每个事件都是一行带 `type` 的 JSON，
/// 所以逐行解析即可，不依赖空行分隔（`URLSession.AsyncBytes.lines` 不产出空行）。
struct ResponsesStreamParser {
    private var emittedCallIDs: Set<String> = []
    private var completed = false

    mutating func consume(line: String) throws -> [LLMEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", !payload.isEmpty else { return [] }
        guard let event = try? JSONDecoder().decode(StreamEvent.self, from: Data(payload.utf8)) else {
            throw LLMError.malformedResponse("event")
        }
        switch event.type {
        case "response.output_text.delta":
            return event.delta.map { [.textDelta($0)] } ?? []
        case "response.output_item.done":
            guard let item = event.item, let call = item.functionCall else { return [] }
            return emit(call)
        case "response.completed", "response.incomplete":
            // 个别实现只在完成事件里给出函数调用，这里补上还没发出的。
            completed = true
            let calls = (event.response?.output ?? []).compactMap(\.functionCall).flatMap { emit($0) }
            return calls + [.completed(event.response?.info ?? LLMResponseInfo())]
        case "response.failed":
            throw LLMError.upstream(event.response?.error?.message ?? "response.failed")
        case "error":
            // Conduit 自己的流内错误是 `{type, code, message}`，上游的可能把细节放在 `error` 里。
            let code = event.code ?? event.error?.code ?? event.error?.type
            if code == "upstream_timeout" || code == "timeout_error" { throw LLMError.timeout }
            throw LLMError.upstream(event.message ?? event.error?.message ?? "stream error")
        default:
            return []
        }
    }

    /// 流结束却没有完成事件，说明连接中途断了。
    func finish() throws -> [LLMEvent] {
        guard completed else { throw LLMError.malformedResponse("stream ended early") }
        return []
    }

    private mutating func emit(_ call: LLMFunctionCall) -> [LLMEvent] {
        guard emittedCallIDs.insert(call.callID).inserted else { return [] }
        return [.functionCall(call)]
    }

    /// 非流式响应：按输出顺序转成同样的事件序列。
    static func events(fromResponse data: Data) throws -> [LLMEvent] {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw LLMError.malformedResponse("response")
        }
        if response.status == "failed" { throw LLMError.upstream(response.error?.message ?? "response.failed") }
        var events: [LLMEvent] = []
        for item in response.output ?? [] {
            if let call = item.functionCall {
                events.append(.functionCall(call))
            } else if item.type == "message" {
                let text = (item.content ?? []).compactMap { $0.type == "output_text" ? $0.text : nil }.joined()
                if !text.isEmpty { events.append(.textDelta(text)) }
            }
        }
        return events + [.completed(response.info)]
    }

    private struct StreamEvent: Decodable {
        var type: String
        var delta: String?
        var item: OutputItem?
        var response: Response?
        var code: String?
        var message: String?
        var error: Failure?
    }

    private struct Failure: Decodable {
        var type: String?
        var code: String?
        var message: String?
    }

    private struct Response: Decodable {
        struct Usage: Decodable {
            var inputTokens: Int?
            var outputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
            }
        }

        var id: String?
        var status: String?
        var output: [OutputItem]?
        var usage: Usage?
        var error: Failure?

        var info: LLMResponseInfo {
            LLMResponseInfo(responseID: id, inputTokens: usage?.inputTokens, outputTokens: usage?.outputTokens)
        }
    }

    private struct OutputItem: Decodable {
        struct Content: Decodable {
            var type: String
            var text: String?
        }

        var type: String
        var callID: String?
        var name: String?
        var arguments: String?
        var content: [Content]?

        enum CodingKeys: String, CodingKey {
            case type, name, arguments, content
            case callID = "call_id"
        }

        var functionCall: LLMFunctionCall? {
            guard type == "function_call", let callID, let name else { return nil }
            return LLMFunctionCall(callID: callID, name: name, arguments: arguments ?? "{}")
        }
    }
}
