import Foundation
import Testing
@testable import Vita

/// 按脚本回放模型事件，并记下每次请求，用来检查工具循环与上下文。
final class ScriptedLLMClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var rounds: [Result<[LLMEvent], LLMError>]
    private(set) var requests: [LLMRequest] = []

    init(_ rounds: [Result<[LLMEvent], LLMError>]) {
        self.rounds = rounds
    }

    func send(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        let next: Result<[LLMEvent], LLMError> = lock.withLock {
            requests.append(request)
            return rounds.isEmpty ? .failure(.malformedResponse("script exhausted")) : rounds.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            switch next {
            case .success(let events):
                events.forEach { continuation.yield($0) }
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
    }
}

@MainActor
struct ChatOrchestratorTests {
    private func make(_ rounds: [Result<[LLMEvent], LLMError>]) throws -> (AppServices, ChatOrchestrator, ScriptedLLMClient) {
        let client = ScriptedLLMClient(rounds)
        var container = try AppContainer.inMemory(referenceFoods: try Fixtures.referenceFoods())
        container.llmClient = client
        let services = AppServices(container: container, now: { Fixtures.now }, timeZone: { Fixtures.shanghai })
        let orchestrator = ChatOrchestrator(services: services, client: client, now: { Fixtures.now }, timeZone: { Fixtures.shanghai })
        return (services, orchestrator, client)
    }

    private func call(_ id: String, _ name: String, _ arguments: String) -> LLMEvent {
        .functionCall(LLMFunctionCall(callID: id, name: name, arguments: arguments))
    }

    private let done = LLMEvent.completed(LLMResponseInfo())

    /// 不带 requestId 与 expectedRevision：由客户端补上。
    private let eggProposal = #"""
    {"sessionDate":"2026-10-30","payload":{"intent":"create","record":{
      "eventTime":{"precision":"mealPeriod","mealPeriod":"lunch"},"mealLabel":"午餐",
      "items":[{"displayName":"水煮蛋","originalAmountText":"2 个鸡蛋、共 108g","quantity":{"amount":108,"unit":"g"},
                "amountSource":"userMeasured","nutrition":{"source":"referenceFood","referenceFoodId":"vita.reference.egg.whole.boiled"}}]}}}
    """#

    @Test func recordConfirmCorrectAndDeleteGoThroughTheConfirmGate() async throws {
        let (services, orchestrator, client) = try make([
            .success([.reasoning("先查参考库"), .textDelta("我查一下。"), call("c1", "searchReferenceFoods", #"{"query":"水煮蛋"}"#), done]),
            .success([call("c2", "proposeRecordChange", eggProposal), done]),
            .success([.textDelta("请确认这条午餐。"), done]),
        ])

        var progress: [ChatProgress] = []
        let first = try await orchestrator.send("中午吃了 2 个水煮蛋，称了一共 108g", on: Fixtures.day) { progress.append($0) }
        let pendingID = try #require(first.pendingID)
        #expect(first.reply?.cardRef == .pending(pendingID))
        #expect(first.reply?.text == "我查一下。\n\n请确认这条午餐。")
        #expect(progress.last?.text == "我查一下。\n\n请确认这条午餐。")
        #expect(progress.last?.activity == nil)
        #expect(progress.last?.steps == [
            ChatProgress.Step(tool: "searchReferenceFoods", done: true),
            ChatProgress.Step(tool: "proposeRecordChange", done: true),
        ])
        #expect(progress.contains(ChatProgress(text: "", activity: .thinking, thinking: "先查参考库")))
        // 等待时依次提示：思考、查参考库、思考、生成确认卡、思考，最后输出正文。
        let activities = progress.compactMap(\.activity).reduce(into: [ChatProgress.Activity]()) { result, activity in
            if result.last != activity { result.append(activity) }
        }
        #expect(activities == [.thinking, .tool("searchReferenceFoods"), .thinking, .tool("proposeRecordChange"), .thinking])
        // 提案不写正式数据。
        #expect(try services.dayData.day(Fixtures.day).records.isEmpty)

        // 第二轮请求带回了函数调用与输出；查询结果来自客户端。
        let second = client.requests[1]
        #expect(second.input.contains(.functionCall(LLMFunctionCall(callID: "c1", name: "searchReferenceFoods", arguments: #"{"query":"水煮蛋"}"#))))
        let searchOutput = second.input.compactMap { item -> String? in
            if case .functionOutput("c1", let output) = item { output } else { nil }
        }.first
        #expect(searchOutput?.contains("vita.reference.egg.whole.boiled") == true)

        // 用户在卡片上确认，客户端直接提交；模型不参与。
        let recordID = try services.pending.confirm(pendingID)
        let day = try services.dayData.day(Fixtures.day)
        #expect(day.records.map(\.id) == [recordID])
        #expect(day.records[0].items[0].quantity == Quantity(amount: 108, unit: .gram))

        // 删除同样要确认。
        let (services2, orchestrator2) = (services, ChatOrchestrator(
            services: services,
            client: ScriptedLLMClient([
                .success([call("c3", "proposeRecordDeletion", #"{"sessionDate":"2026-10-30","payload":{"recordId":"\#(recordID.uuidString)"}}"#), done]),
                .success([.textDelta("确认后删除。"), done]),
            ]),
            now: { Fixtures.now }, timeZone: { Fixtures.shanghai }
        ))
        let deletion = try await orchestrator2.send("中午那条删了", on: Fixtures.day)
        #expect(try services2.dayData.day(Fixtures.day).records.count == 1)
        _ = try services2.pending.confirm(try #require(deletion.pendingID))
        #expect(try services2.dayData.day(Fixtures.day).records.isEmpty)

        let history = try services.chatHistory.messages(on: Fixtures.day)
        #expect(history.map(\.role) == [.user, .assistant, .user, .assistant])
    }

    @Test func afterConfirmContinuesWithoutSavingAUserMessage() async throws {
        let withStep = eggProposal.replacingOccurrences(of: #"{"sessionDate""#, with: #"{"afterConfirm":"再记一杯牛奶","sessionDate""#)
        let (services, orchestrator, client) = try make([
            .success([call("c1", "proposeRecordChange", withStep), done]),
            .success([.textDelta("先确认这条午餐，确认后我再记牛奶。"), done]),
            .success([.textDelta("接着记牛奶。"), done]),
        ])
        let first = try await orchestrator.send("中午两个水煮蛋 108g，还喝了一杯牛奶", on: Fixtures.day)
        let pendingID = try #require(first.pendingID)
        #expect(first.afterConfirm == "再记一杯牛奶")

        _ = try services.pending.confirm(pendingID)
        let next = try await orchestrator.continueAfterConfirm(pendingID, step: "再记一杯牛奶", on: Fixtures.day)
        #expect(next.reply?.text == "接着记牛奶。")
        // 接续轮把“已确认 + 下一步”作为客户端消息放在最后，历史里的卡片注记也已变成已确认。
        let input = client.requests[2].input
        guard case .system(let note) = input.last else { Issue.record("最后一项应是客户端消息"); return }
        #expect(note.contains(pendingID.uuidString) && note.contains("再记一杯牛奶"))
        #expect(input.contains { if case .assistant(let text) = $0 { text.contains("用户已确认，已保存") } else { false } })
        // 只多了一条助手回复，没有用户消息。
        #expect(try services.chatHistory.messages(on: Fixtures.day).map(\.role) == [.user, .assistant, .assistant])
    }

    @Test func otherDateAsksToSwitchWithoutWriting() async throws {
        let yesterday = eggProposal.replacingOccurrences(of: "2026-10-30", with: "2026-10-29")
        let (services, orchestrator, _) = try make([
            .success([call("c1", "proposeRecordChange", yesterday), done]),
            .success([.textDelta("这是昨天的内容，要切到昨天记录吗？"), done]),
        ])
        let result = try await orchestrator.send("昨天中午吃了两个鸡蛋", on: Fixtures.day)
        #expect(result.requestedDate == LocalDate(isoString: "2026-10-29"))
        #expect(result.pendingID == nil)
        #expect(try services.pending.active(on: Fixtures.day) == nil)
        #expect(try services.pending.active(on: LocalDate(isoString: "2026-10-29")!) == nil)
    }

    @Test func modelFailureSavesNothing() async throws {
        let (services, orchestrator, _) = try make([.failure(.authentication)])
        await #expect(throws: LLMError.authentication) {
            try await orchestrator.send("早上喝了牛奶", on: Fixtures.day)
        }
        #expect(try services.chatHistory.messages(on: Fixtures.day).isEmpty)
    }

    @Test func updateGoalReturnsOldAndNewValues() async throws {
        let (services, orchestrator, client) = try make([
            .success([call("c1", "updateGoal", #"{"proteinG":150,"userCommand":"把蛋白质目标改成 150g"}"#), done]),
            .success([.textDelta("已改为 150g。"), done]),
        ])
        _ = try services.goals.appendGoal(GoalTargets(energyKcal: 1800, proteinG: 120), origin: .manualOnboarding, effectiveFrom: Fixtures.day)
        let result = try await orchestrator.send("把蛋白质目标改成 150g", on: Fixtures.day)
        #expect(result.goalChanged)
        #expect(try services.goals.activeGoal(on: Fixtures.day)?.targets == GoalTargets(energyKcal: 1800, proteinG: 150))
        let output = client.requests[1].input.compactMap { item -> String? in
            if case .functionOutput(_, let output) = item { output } else { nil }
        }.first ?? ""
        #expect(output.contains(#""previous":{"#) && output.contains(#""proteinG":120"#) && output.contains(#""proteinG":150"#))
    }

    @Test func unknownAndClientOnlyToolsAreRejected() async throws {
        let (services, orchestrator, client) = try make([
            .success([call("c1", "confirmPending", #"{"pendingId":"x"}"#), call("c2", "getGoals", "not json"), done]),
            .success([.textDelta("好的"), done]),
        ])
        _ = try await orchestrator.send("确认", on: Fixtures.day)
        let outputs = client.requests[1].input.compactMap { item -> String? in
            if case .functionOutput(_, let output) = item { output } else { nil }
        }
        #expect(outputs.count == 2)
        #expect(outputs[0].contains("unknownTool"))
        #expect(outputs[1].contains("malformedArguments"))
        #expect(try services.dayData.day(Fixtures.day).records.isEmpty)
    }

    @Test func stopsAfterTooManyToolRounds() async throws {
        let rounds = (0..<ChatOrchestrator.maxToolRounds).map { index in
            Result<[LLMEvent], LLMError>.success([call("c\(index)", "getGoals", "{}"), done])
        }
        let (_, orchestrator, client) = try make(rounds)
        let result = try await orchestrator.send("你好", on: Fixtures.day)
        #expect(client.requests.count == ChatOrchestrator.maxToolRounds)
        #expect(result.reply?.text.contains("步骤太多") == true)
    }

    @Test func requestCarriesConfigSessionStateAndHistory() async throws {
        let (services, orchestrator, client) = try make([
            .success([.textDelta("第一句回复"), done]),
            .success([.textDelta("第二句回复"), done]),
        ])
        _ = try await orchestrator.send("你好", on: Fixtures.day)
        _ = try await orchestrator.send("再说一次", on: Fixtures.day)

        let request = client.requests[1]
        let config = services.container.config.effectiveConfig().values
        #expect(request.model == config.llm.modelId)
        #expect(request.streaming == config.llm.streaming)
        #expect(request.reasoningEffort == config.llm.reasoningEffort)
        #expect(request.instructions.hasPrefix(config.prompts.system.text))
        // 每轮都变的客户端状态不进系统指令，作为系统消息放在本轮用户消息前，前面的内容才能命中缓存。
        #expect(!request.instructions.contains("会话日期："))
        #expect(request.instructions == client.requests[0].instructions)
        #expect(request.input.count == 4)
        #expect(Array(request.input.prefix(2)) == [.user("你好"), .assistant("第一句回复")])
        guard case .system(let state) = request.input[2] else { Issue.record("no client state"); return }
        #expect(state.contains("会话日期：2026-10-30"))
        #expect(state.contains("revision：0"))
        #expect(request.input[3] == .user("再说一次"))
        // 只暴露契约里的工具，client-only 工具不在其中。
        let names = Set(request.tools.map(\.name))
        #expect(names == AgentToolCatalog.names)
        #expect(names.isDisjoint(with: ["confirmPending", "cancelPending", "commitInitialGoals", "submitManualBodyMetrics", "runHealthSync"]))
        for tool in request.tools {
            #expect(tool.parameters["type"] == .string("object"), "\(tool.name)")
        }
    }

    @Test func historyMarksRepliesThatCarriedACard() {
        let card = UUID()
        let history = [
            ChatEntry(id: UUID(), role: .user, text: "早上喝了牛奶", createdAt: Fixtures.now),
            ChatEntry(id: UUID(), role: .assistant, text: "请确认卡片。", cardRef: .pending(card), createdAt: Fixtures.now),
            ChatEntry(id: UUID(), role: .assistant, text: "是全脂还是脱脂？", createdAt: Fixtures.now),
        ]
        let input = ChatOrchestrator.historyInput(history, limit: 20) { _ in .confirmed }
        #expect(input[0] == .user("早上喝了牛奶"))
        #expect(input[1] == .assistant("请确认卡片。\n\n［客户端注：这条回复附带一张由提案工具生成的确认卡，用户已确认，已保存。］"))
        #expect(input[2] == .assistant("是全脂还是脱脂？"))
    }

    @Test func labelPhotoIsSentToTheModelWithItsScanID() async throws {
        let client = ScriptedLLMClient([
            .success([.textDelta("这是什么牌子的？"), done]),
            .success([.textDelta("好的"), done]),
        ])
        var container = try AppContainer.inMemory(referenceFoods: try Fixtures.referenceFoods())
        container.llmClient = client
        let services = AppServices(container: container, now: { Fixtures.now }, timeZone: { Fixtures.shanghai })
        let orchestrator = ChatOrchestrator(services: services, client: client, now: { Fixtures.now }, timeZone: { Fixtures.shanghai })

        let scan = try services.labels.scan(LabelImageTests.photo(width: 2400, height: 1800))
        _ = try await orchestrator.send("", on: Fixtures.day, labelScan: scan.scanID)

        guard case .userImages(let sent, let images) = client.requests[0].input.last else { Issue.record("no image"); return }
        #expect(sent.contains("labelScanId: \(scan.scanID.uuidString)"))
        // 本地路径不交给模型。
        #expect(!sent.contains(scan.imageReference))
        #expect(images.count == 1)
        #expect(images[0].dataURL.hasPrefix("data:image/jpeg;base64,"))
        #expect(images[0].detail == services.container.config.effectiveConfig().values.labelImage.detail)

        let history = try services.chatHistory.messages(on: Fixtures.day)
        #expect(history.first?.cardRef == .label(scan.scanID))

        // 下一轮重放历史时照片还在，模型仍看得到标签和 labelScanId。
        _ = try await orchestrator.send("是伊利纯牛奶", on: Fixtures.day)
        guard case .userImages(let replayed, _) = client.requests[1].input.first else { Issue.record("no history"); return }
        #expect(replayed.contains("labelScanId: \(scan.scanID.uuidString)"))
        #expect(ChatCardRef(rawValue: ChatCardRef.label(scan.scanID).rawValue) == .label(scan.scanID))
    }

    /// 个人库不做字符串匹配：整库进上下文，搜索工具也返回整库，由模型做语义匹配（PRD §3.1）。
    @Test func personalLibraryIsGivenWholeToTheModel() async throws {
        let (services, orchestrator, client) = try make([
            .success([call("c1", "searchPersonalFoods", #"{"query":"原味的那个脆片"}"#), done]),
            .success([.textDelta("好的"), done]),
        ])
        let version = FoodVersionDraft(
            basis: FoodVersionBasis(quantity: Quantity(amount: 100, unit: .gram), nutrients: NutrientValues(energyKcal: 411, proteinG: 10.5, fatG: 15.2, carbohydrateG: 62)),
            sourceKind: .manualEntry
        )
        _ = try services.foods.apply(.createProduct(FoodProductDraft(name: "燕麦脆（原味）", brandOrSupplier: nil, package: Quantity(amount: 300, unit: .gram), note: nil), version: version))
        let productID = try #require(try services.foods.products().first?.id)

        _ = try await orchestrator.send("下午吃了半包原味的那个脆片", on: Fixtures.day)
        #expect(client.requests[0].instructions.contains("燕麦脆（原味）［productId \(productID.uuidString)］"))
        let output = client.requests[1].input.compactMap { item -> String? in
            if case .functionOutput(_, let output) = item { output } else { nil }
        }.first ?? ""
        #expect(output.contains(productID.uuidString))
    }

    @Test func toolDescriptionsCanBeOverriddenButNotAdded() {
        let definitions = AgentToolCatalog.definitions(descriptions: [
            "getGoals": ToolPrompt(version: 2, description: "新描述"),
            "deleteEverything": ToolPrompt(version: 1, description: "不该出现"),
        ])
        #expect(definitions.first { $0.name == "getGoals" }?.description == "新描述")
        #expect(!definitions.contains { $0.name == "deleteEverything" })
    }
}
