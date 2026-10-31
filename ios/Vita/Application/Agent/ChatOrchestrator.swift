import Foundation

/// 一轮对话的结果，界面据此显示回复、确认卡与“切换日期”按钮。
struct ChatTurnResult: Equatable, Sendable {
    var reply: ChatEntry?
    var pendingID: UUID?
    var requestedDate: LocalDate?
    var goalChanged: Bool
}

/// 组装请求、驱动工具循环、保存对话（TDD §5.1）。模型只能查询与提案；确认由界面直接调用 `PendingService`，
/// 模型在这里拿不到 `confirmPending`。每轮开始时读取一次生效配置，一轮中途不切换（vita-admin.md §5）。
@MainActor
final class ChatOrchestrator {
    /// 一轮里最多来回几次工具调用，防止模型陷入循环。
    static let maxToolRounds = 8

    private let services: AppServices
    private let client: any LLMClient
    private let tools: AgentToolRunner
    private let now: () -> Date
    private let timeZone: () -> TimeZone

    init(
        services: AppServices,
        client: any LLMClient,
        now: @escaping () -> Date = Date.init,
        timeZone: @escaping () -> TimeZone = { .current }
    ) {
        self.services = services
        self.client = client
        self.now = now
        self.timeZone = timeZone
        tools = AgentToolRunner(services: services, now: now, timeZone: timeZone)
    }

    /// 跑完工具循环后一起保存用户消息与回复。`onText` 随流式输出给出本轮到目前为止的完整文字。
    /// 模型调用失败或被取消时什么都不保存，抛出错误，由界面把原文放回输入框。
    /// （这一轮里已经生成的确认卡保留：它不是正式数据，用户仍可确认或取消。）
    func send(_ text: String, on date: LocalDate, onText: @escaping (String) -> Void = { _ in }) async throws -> ChatTurnResult {
        let config = services.container.config.effectiveConfig().values
        let history = try services.chatHistory.messages(on: date)
        try services.pending.expireDue()

        var input = Self.historyInput(history, limit: config.context.maxRecentMessages)
        input.append(.user(text))
        let definitions = AgentToolCatalog.definitions(descriptions: config.prompts.tools)
        let requestID = UUID()

        var reply = ""
        var pendingID: UUID?
        var requestedDate: LocalDate?
        var goalChanged = false

        for round in 0..<Self.maxToolRounds {
            let request = LLMRequest(
                model: config.llm.modelId,
                instructions: try instructions(config: config, date: date),
                input: input,
                tools: definitions,
                requestID: round == 0 ? requestID : UUID(),
                timeoutSeconds: config.llm.timeoutSeconds,
                maxRetries: config.llm.maxRetries,
                streaming: config.llm.streaming
            )
            var roundText = ""
            var calls: [LLMFunctionCall] = []
            for try await event in client.send(request) {
                switch event {
                case .textDelta(let delta):
                    roundText += delta
                    onText(Self.join(reply, roundText))
                case .functionCall(let call):
                    calls.append(call)
                case .completed:
                    break
                }
            }
            reply = Self.join(reply, roundText)
            if !roundText.isEmpty { input.append(.assistant(roundText)) }
            guard !calls.isEmpty else { break }

            for call in calls {
                let outcome = await tools.run(call, sessionDate: date, requestID: requestID)
                input.append(.functionCall(call))
                input.append(.functionOutput(callID: call.callID, output: outcome.output))
                if let id = outcome.pendingID { pendingID = id }
                if let raw = outcome.requestedDate, let requested = LocalDate(isoString: raw) { requestedDate = requested }
                goalChanged = goalChanged || outcome.goalChanged
            }
            if round == Self.maxToolRounds - 1 {
                reply = Self.join(reply, "这次处理步骤太多，我先停在这里。请换个说法再试一次。")
            }
        }

        if reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reply = pendingID != nil ? "请确认下面的卡片。" : "好的。"
        }
        try services.chatHistory.append(.user, text: text, on: date)
        let entry = try services.chatHistory.append(.assistant, text: reply, cardRef: pendingID.map(ChatCardRef.pending), on: date)
        return ChatTurnResult(reply: entry, pendingID: pendingID, requestedDate: requestedDate, goalChanged: goalChanged)
    }

    // MARK: - 上下文

    /// 最近的若干条用户与助手文字。工具调用不重放，模型需要时再查。
    static func historyInput(_ history: [ChatEntry], limit: Int) -> [LLMInputItem] {
        history.suffix(max(limit, 0)).compactMap { entry in
            switch entry.role {
            case .user: .user(entry.text)
            case .assistant: .assistant(entry.text)
            case .toolSummary: nil
            }
        }
    }

    /// 系统 prompt 之后附上本轮的客户端状态：会话日期由导航决定，模型不能自己推断（agent-tools.md）。
    func instructions(config: VitaConfig, date: LocalDate) throws -> String {
        let zone = timeZone()
        let today = LocalDate(date: now(), timeZone: zone)
        let day = try services.dayData.day(date)
        let pending = try services.pending.active(on: date)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: now())
        let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
        let weekday = calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day))
            .map { weekdays[calendar.component(.weekday, from: $0) - 1] } ?? ""

        var lines = [
            "## 当前状态（由客户端提供）",
            "- 会话日期：\(date.isoString)（星期\(weekday)）\(date == today ? "，就是今天" : "，今天是 \(today.isoString)")。只能写这一天。",
            "- 现在的本地时间：\(String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0))，时区 \(zone.identifier)。",
            "- 当天 revision：\(day.revision)。提案时作为 expectedRevision。",
        ]
        if let pending {
            lines.append("- 当天有一张待确认卡片：\(pending.id.uuidString)。修正它时填 replacesPendingId；用户要记别的内容，先请用户确认或取消这张卡片。")
        }
        if day.records.isEmpty {
            lines.append("- 当天还没有记录。")
        } else {
            lines.append("- 当天的记录（修改时用 ID；需要用量与营养细节时调用 getDaySummary）：")
            for record in day.records {
                let label = record.mealLabel ?? record.eventTime.mealPeriod?.rawValue ?? record.eventTime.precision.rawValue
                let items = record.items.map { "\($0.displayName)［\($0.id.uuidString)］\($0.originalAmountText)" }.joined(separator: "；")
                lines.append("  - \(label)［\(record.id.uuidString)］：\(items)")
            }
        }
        if config.context.includePersonalFoodSummary {
            let products = try services.foods.products()
            if !products.isEmpty {
                lines.append("- 个人食品库（优先使用；精确 ID 用 searchPersonalFoods 取得）：" + products.map(\.name).joined(separator: "、"))
            }
        }
        return config.prompts.system.text + "\n\n" + lines.joined(separator: "\n")
    }

    private static func join(_ first: String, _ second: String) -> String {
        if first.isEmpty { return second }
        if second.isEmpty { return first }
        return first + "\n\n" + second
    }
}
