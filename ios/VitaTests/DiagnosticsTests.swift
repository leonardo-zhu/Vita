import Foundation
import Testing
@testable import Vita

/// 记下所有事件，测试里看业务代码记了什么。
final class RecordingDiagnostics: DiagnosticsRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [DiagnosticEvent] = []
    var events: [DiagnosticEvent] { lock.withLock { _events } }
    func record(_ event: DiagnosticEvent) { lock.withLock { _events.append(event) } }
}

private final class FakeTransport: DiagnosticsTransport, @unchecked Sendable {
    private let lock = NSLock()
    var statuses: [Int]
    private(set) var bodies: [Data] = []

    init(_ statuses: [Int]) { self.statuses = statuses }

    func post(_ request: URLRequest) async throws -> HTTPURLResponse {
        let status = lock.withLock {
            bodies.append(request.httpBody ?? Data())
            return statuses.isEmpty ? 200 : statuses.removeFirst()
        }
        if status == 0 { throw URLError(.notConnectedToInternet) }
        return HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

struct DiagnosticsTests {
    private static let url = URL(string: "https://vita.example/api/ingest/events")!

    private func defaults() -> UserDefaults {
        let name = "diagnostics-tests-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    private func make(_ statuses: [Int] = [], now: @escaping () -> Date = Date.init) -> (DiagnosticsService, FakeTransport, InMemoryDiagnosticsQueue) {
        let transport = FakeTransport(statuses)
        let queue = InMemoryDiagnosticsQueue()
        let service = DiagnosticsService(
            url: Self.url, appVersion: "0.1.0", osVersion: "27.0", queue: queue, transport: transport, defaults: defaults(), now: now
        )
        return (service, transport, queue)
    }

    private func event(_ type: DiagnosticEvent.Kind = .configFetch) -> DiagnosticEvent {
        DiagnosticEvent(occurredAt: .now, type: type, outcome: "unchanged", latencyMs: 12)
    }

    /// iOS 编出来的字段名与取值形状要和共用示例一致，Admin 按同一份 schema 校验这个示例。
    @Test func encodingMatchesTheSharedExample() throws {
        let url = try #require(Fixtures.bundle.url(forResource: "example-batch", withExtension: "json"))
        let data = try Data(contentsOf: url)
        struct Example: Decodable { var installId: UUID; var appVersion: String; var osVersion: String?; var events: [DiagnosticEvent] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let example = try decoder.decode(Example.self, from: data)

        let encoded = try DiagnosticsBatch.encoder.encode(DiagnosticsBatch(
            installId: example.installId, appVersion: example.appVersion, osVersion: example.osVersion, events: example.events
        ))
        let ours = try JSONSerialization.jsonObject(with: encoded) as! NSDictionary
        let theirs = try JSONSerialization.jsonObject(with: data) as! NSDictionary
        #expect(ours == theirs)
    }

    @Test func codesAreSquashedToTheAllowedShape() {
        #expect(DiagnosticEvent.code("config.invalid.prompts.tools.getGoals") == "config.invalid.prompts.tools.getgoals")
        #expect(DiagnosticEvent.code("请求没有被接受") == "x_______")
        #expect(DiagnosticEvent.resultCode("recordNotFound") == "recordNotFound")
        #expect(DiagnosticEvent.resultCode("{\"x\":1}") == "x1")
        #expect(DiagnosticEvent.resultCode("1abc") == "other")
    }

    @Test func uploadsInBatchesAndClearsWhatWasSent() async throws {
        let (service, transport, queue) = make()
        for _ in 0..<150 { service.record(event()) }
        // 攒够 20 条会自动开始上报；等它结束再看
        await service.flush()
        #expect(queue.load().isEmpty)
        #expect(transport.bodies.count >= 2)
        let first = try JSONSerialization.jsonObject(with: transport.bodies[0]) as! [String: Any]
        #expect((first["events"] as! [Any]).count <= DiagnosticsService.batchSize)
        #expect(first["appVersion"] as? String == "0.1.0")
    }

    @Test func keepsEventsOnServerErrorsAndDropsRejectedBatches() async {
        let (service, _, queue) = make([500, 0, 400])
        service.setEnabled(true)
        for _ in 0..<3 { service.record(event()) }
        await service.flush()
        #expect(queue.load().count == 3)
        await service.flush()
        #expect(queue.load().count == 3)
        await service.flush()
        #expect(queue.load().isEmpty)
    }

    @Test func revokedInstallStopsUploading() async {
        let (service, transport, queue) = make([403])
        service.record(event())
        await service.flush()
        #expect(queue.load().isEmpty)
        service.record(event())
        await service.flush()
        #expect(transport.bodies.count == 1)
    }

    @Test func turningOffStopsRecordingAndDropsTheQueue() {
        let (service, _, queue) = make()
        service.record(event())
        service.setEnabled(false)
        #expect(queue.load().isEmpty)
        service.record(event())
        #expect(queue.load().isEmpty)
        #expect(!service.isEnabled)
    }

    @Test func queueIsCapped() {
        let (service, _, queue) = make([0])
        // 不触发自动上报会更快：直接塞满
        queue.save((0..<DiagnosticsService.maxQueued).map { _ in event() })
        service.record(event())
        #expect(queue.load().count == DiagnosticsService.maxQueued)
    }

    @Test func installIDRotatesAfterThirtyDays() {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let (service, _, _) = make(now: { clock })
        let first = service.installID()
        clock += 29 * 86400
        #expect(service.installID() == first)
        clock += 2 * 86400
        #expect(service.installID() != first)
    }
}

@MainActor
struct DiagnosticsRecordingTests {
    private func make(_ rounds: [Result<[LLMEvent], LLMError>]) throws -> (ChatOrchestrator, RecordingDiagnostics) {
        let client = ScriptedLLMClient(rounds)
        let recorder = RecordingDiagnostics()
        var container = try AppContainer.inMemory(referenceFoods: try Fixtures.referenceFoods())
        container.llmClient = client
        container.diagnostics = recorder
        let services = AppServices(container: container, now: { Fixtures.now }, timeZone: { Fixtures.shanghai })
        return (ChatOrchestrator(services: services, client: client, now: { Fixtures.now }, timeZone: { Fixtures.shanghai }), recorder)
    }

    @Test func recordsTheTurnAndEachToolCall() async throws {
        let (orchestrator, recorder) = try make([
            .success([.functionCall(LLMFunctionCall(callID: "c1", name: "getGoals", arguments: "{}")), .completed(LLMResponseInfo(inputTokens: 1000, outputTokens: 20))]),
            .success([.textDelta("目标还没设置。"), .completed(LLMResponseInfo(inputTokens: 1100, outputTokens: 30))]),
        ])
        _ = try await orchestrator.send("我的目标是多少", on: Fixtures.day)

        let tool = try #require(recorder.events.first { $0.type == .toolCall })
        #expect(tool.tool == "getGoals")
        #expect(tool.resultCode == "ok")
        #expect(tool.toolDescriptionVersion == 2)

        let turn = try #require(recorder.events.first { $0.type == .chatTurn })
        #expect(turn.outcome == "ok")
        #expect(turn.rounds == 2)
        #expect(turn.toolCalls == 1)
        #expect(turn.tokensIn == 2100)
        #expect(turn.tokensOut == 50)
        #expect(turn.createdPending == false)
        #expect(turn.claimedCardWithoutTool == false)
        #expect(turn.requestId == tool.requestId)
        #expect(turn.modelAlias == "vita-chat")
    }

    @Test func recordsFailuresByCodeOnly() async throws {
        let (orchestrator, recorder) = try make([.failure(.invalidRequest("model vita-x not found"))])
        await #expect(throws: LLMError.self) { try await orchestrator.send("你好", on: Fixtures.day) }
        let turn = try #require(recorder.events.first)
        #expect(turn.outcome == "error")
        #expect(turn.errorCode == "llm.invalid_request")
    }

    @Test func flagsAReplyThatClaimsACardWithoutTheTool() async throws {
        let (orchestrator, recorder) = try make([.success([.textDelta("已生成确认卡，请确认。"), .completed(LLMResponseInfo())])])
        _ = try await orchestrator.send("中午吃了米饭", on: Fixtures.day)
        #expect(recorder.events.first?.claimedCardWithoutTool == true)
    }
}
