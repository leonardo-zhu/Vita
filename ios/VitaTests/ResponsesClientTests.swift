import Foundation
import Testing
@testable import Vita

/// Conduit Responses 子集的契约测试（llm-provider.md §6）：用 URLProtocol 替身回放固定响应。
@Suite(.serialized)
struct ResponsesClientTests {
    /// 按顺序回放响应，并记下收到的请求。
    final class StubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var responses: [(status: Int, body: String)] = []
        nonisolated(unsafe) static var requests: [URLRequest] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            var recorded = request
            if let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                recorded.httpBody = data
            }
            Self.requests.append(recorded)
            let next: (status: Int, body: String) = Self.responses.isEmpty ? (500, "") : Self.responses.removeFirst()
            let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(next.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func client(token: String? = "test-token") -> ResponsesClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return ResponsesClient(
            baseURL: URL(string: "https://conduit.invalid")!,
            token: { token },
            session: URLSession(configuration: configuration),
            retryDelay: .zero
        )
    }

    private func request(streaming: Bool = true, maxRetries: Int = 0) -> LLMRequest {
        LLMRequest(
            model: "vita-chat", instructions: "system",
            input: [.user("你好"), .functionCall(LLMFunctionCall(callID: "c0", name: "getGoals", arguments: "{}")), .functionOutput(callID: "c0", output: "{}")],
            tools: [LLMToolDefinition(name: "getGoals", description: "读目标", parameters: .object(["type": .string("object")]))],
            requestID: UUID(), timeoutSeconds: 5, maxRetries: maxRetries, streaming: streaming
        )
    }

    private func collect(_ client: ResponsesClient, _ request: LLMRequest) async throws -> [LLMEvent] {
        var events: [LLMEvent] = []
        for try await event in client.send(request) { events.append(event) }
        return events
    }

    private func sse(_ events: [String]) -> String {
        events.map { "event: x\ndata: \($0)\n\n" }.joined()
    }

    private func reset(_ responses: [(Int, String)]) {
        StubProtocol.responses = responses.map { (status: $0.0, body: $0.1) }
        StubProtocol.requests = []
    }

    @Test func streamsTextDeltasAndCompletion() async throws {
        reset([(200, sse([
            #"{"type":"response.created","response":{"id":"r1"}}"#,
            #"{"type":"response.output_text.delta","delta":"你"}"#,
            #"{"type":"response.output_text.delta","delta":"好"}"#,
            #"{"type":"response.completed","response":{"id":"r1","output":[],"usage":{"input_tokens":10,"output_tokens":2}}}"#,
            "[DONE]",
        ]))])
        let events = try await collect(client(), request())
        #expect(events == [
            .textDelta("你"), .textDelta("好"),
            .completed(LLMResponseInfo(responseID: "r1", inputTokens: 10, outputTokens: 2)),
        ])
    }

    @Test func emitsEachFunctionCallOnce() async throws {
        let call1 = #"{"type":"function_call","call_id":"c1","name":"searchReferenceFoods","arguments":"{\"query\":\"鸡蛋\"}"}"#
        let call2 = #"{"type":"function_call","call_id":"c2","name":"getGoals","arguments":"{}"}"#
        reset([(200, sse([
            #"{"type":"response.output_item.added","item":{"type":"function_call","call_id":"c1","name":"searchReferenceFoods"}}"#,
            #"{"type":"response.function_call_arguments.delta","delta":"{\"query\""}"#,
            #"{"type":"response.output_item.done","item":\#(call1)}"#,
            // 第二个调用只在完成事件里出现。
            #"{"type":"response.completed","response":{"id":"r2","output":[\#(call1),\#(call2)]}}"#,
        ]))])
        let events = try await collect(client(), request())
        #expect(events == [
            .functionCall(LLMFunctionCall(callID: "c1", name: "searchReferenceFoods", arguments: #"{"query":"鸡蛋"}"#)),
            .functionCall(LLMFunctionCall(callID: "c2", name: "getGoals", arguments: "{}")),
            .completed(LLMResponseInfo(responseID: "r2")),
        ])
    }

    @Test func nonStreamingResponseYieldsSameEvents() async throws {
        reset([(200, #"""
        {"id":"r3","status":"completed","output":[
          {"type":"reasoning","summary":[]},
          {"type":"message","role":"assistant","content":[{"type":"output_text","text":"好的"}]},
          {"type":"function_call","call_id":"c9","name":"getGoals","arguments":"{}"}
        ],"usage":{"input_tokens":3,"output_tokens":4}}
        """#)])
        let events = try await collect(client(), request(streaming: false))
        #expect(events == [
            .textDelta("好的"),
            .functionCall(LLMFunctionCall(callID: "c9", name: "getGoals", arguments: "{}")),
            .completed(LLMResponseInfo(responseID: "r3", inputTokens: 3, outputTokens: 4)),
        ])
    }

    @Test(arguments: [
        (401, "authentication_error", LLMError.authentication),
        (429, "insufficient_quota", LLMError.quotaExceeded),
        (400, "invalid_request_error", LLMError.invalidRequest("bad alias")),
        (503, "upstream_unavailable", LLMError.upstreamUnavailable),
        (502, "upstream_error", LLMError.upstream("bad alias")),
        (504, "upstream_timeout", LLMError.timeout),
    ])
    func mapsConduitErrorTypes(status: Int, type: String, expected: LLMError) async throws {
        reset([(status, #"{"error":{"type":"\#(type)","code":"x","message":"bad alias"}}"#)])
        await #expect(throws: expected) { try await collect(client(), request()) }
    }

    @Test func mapsStatusWhenBodyIsNotJSON() async throws {
        reset([(401, "Unauthorized")])
        await #expect(throws: LLMError.authentication) { try await collect(client(), request()) }
    }

    @Test func inStreamErrorEndsTheTurn() async throws {
        reset([(200, sse([
            #"{"type":"response.output_text.delta","delta":"半"}"#,
            #"{"type":"error","code":"upstream_timeout","message":"服务商 5 分钟没有数据"}"#,
        ]))])
        var received: [LLMEvent] = []
        await #expect(throws: LLMError.timeout) {
            for try await event in client().send(request()) { received.append(event) }
        }
        #expect(received == [.textDelta("半")])
    }

    @Test func streamWithoutCompletionIsAnError() async throws {
        reset([(200, sse([#"{"type":"response.output_text.delta","delta":"半"}"#]))])
        await #expect(throws: LLMError.malformedResponse("stream ended early")) { try await collect(client(), request()) }
    }

    @Test func missingTokenFailsBeforeAnyRequest() async throws {
        reset([])
        await #expect(throws: LLMError.missingToken) { try await collect(client(token: nil), request()) }
        #expect(StubProtocol.requests.isEmpty)
    }

    @Test func retriesOnlyBeforeAnyOutput() async throws {
        reset([
            (502, #"{"error":{"type":"upstream_error","code":"x","message":"down"}}"#),
            (200, sse([#"{"type":"response.completed","response":{"id":"r4"}}"#])),
        ])
        let events = try await collect(client(), request(maxRetries: 1))
        #expect(events == [.completed(LLMResponseInfo(responseID: "r4"))])
        #expect(StubProtocol.requests.count == 2)

        // 已经产出文本后中断的流不重试，避免重复内容。
        reset([
            (200, sse([#"{"type":"response.output_text.delta","delta":"半"}"#, #"{"type":"error","message":"boom"}"#])),
            (200, sse([#"{"type":"response.completed","response":{"id":"r5"}}"#])),
        ])
        await #expect(throws: LLMError.upstream("boom")) { try await collect(client(), request(maxRetries: 1)) }
        #expect(StubProtocol.requests.count == 1)
    }

    @Test func requestIsStatelessAndCarriesHeaders() async throws {
        reset([(200, sse([#"{"type":"response.completed","response":{"id":"r6"}}"#]))])
        let request = request()
        _ = try await collect(client(), request)
        let sent = try #require(StubProtocol.requests.first)
        #expect(sent.url?.absoluteString == "https://conduit.invalid/v1/responses")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(sent.value(forHTTPHeaderField: "X-Request-Id") == request.requestID.uuidString)

        let httpBody = try #require(sent.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        #expect(body["store"] as? Bool == false)
        #expect(body["stream"] as? Bool == true)
        #expect(body["model"] as? String == "vita-chat")
        #expect(body["previous_response_id"] == nil)
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input[0]["role"] as? String == "user")
        #expect(input[1]["type"] as? String == "function_call")
        #expect(input[1]["call_id"] as? String == "c0")
        #expect(input[2]["type"] as? String == "function_call_output")
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools[0]["type"] as? String == "function")
        #expect(tools[0]["name"] as? String == "getGoals")
    }
}
