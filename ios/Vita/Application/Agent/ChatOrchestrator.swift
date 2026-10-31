import Foundation

/// 一轮对话的结果，界面据此显示回复、确认卡与“切换日期”按钮。
struct ChatTurnResult: Equatable, Sendable {
    var reply: ChatEntry?
    var pendingID: UUID?
    var requestedDate: LocalDate?
    var goalChanged: Bool
}

/// 一轮进行中的状态：已经生成的文字，以及此刻在做什么（思考、调用哪个工具）。
struct ChatProgress: Equatable, Sendable {
    enum Activity: Equatable, Sendable {
        case thinking
        case tool(String)

        var label: String {
            switch self {
            case .thinking: "正在思考…"
            case .tool(let name): "正在" + Self.title(name) + "…"
            }
        }

        /// 工具步骤的短名，用在步骤列表里。
        static func title(_ tool: String) -> String {
            switch tool {
            case "getDaySummary", "getRecordDetail": "查看当天记录"
            case "searchPersonalFoods": "查个人食品库"
            case "searchReferenceFoods": "查公共营养库"
            case "getGoals": "查看目标"
            case "getHealthSnapshot": "读取健康数据"
            case "getGoalRecommendation": "计算目标建议"
            case "updateGoal": "修改目标"
            case "proposeRecordChange", "proposeRecordDeletion", "proposeFoodChange": "生成确认卡"
            default: "处理请求"
            }
        }
    }

    /// 这一轮已经调用过的工具，按顺序；界面列成步骤清单。
    struct Step: Equatable, Sendable {
        var tool: String
        var done: Bool
        /// 工具返回了错误（如参数不合法、需要切换日期），模型通常会据此改正。
        var failed = false
    }

    var text: String
    var steps: [Step] = []
    /// nil 表示正在输出正文。
    var activity: Activity?
    /// 本次请求里模型的推理摘要，只在思考时展示。
    var thinking = ""
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

    /// 跑完工具循环后一起保存用户消息与回复。`onProgress` 给出到目前为止的文字与当前步骤。
    /// 模型调用失败或被取消时什么都不保存，抛出错误，由界面把原文放回输入框。
    /// （这一轮里已经生成的确认卡保留：它不是正式数据，用户仍可确认或取消。）
    func send(_ text: String, on date: LocalDate, onProgress: @escaping (ChatProgress) -> Void = { _ in }) async throws -> ChatTurnResult {
        let config = services.container.config.effectiveConfig().values
        let history = try services.chatHistory.messages(on: date)
        try services.pending.expireDue()

        let pending = services.pending
        var input = Self.historyInput(history, limit: config.context.maxRecentMessages) { ref in
            guard case .pending(let id) = ref else { return nil }
            return try? pending.pending(id).status
        }
        input.append(.user(text))
        let definitions = AgentToolCatalog.definitions(descriptions: config.prompts.tools)
        let requestID = UUID()

        var reply = ""
        var steps: [ChatProgress.Step] = []
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
            var thinking = ""
            var calls: [LLMFunctionCall] = []
            // 等第一个事件时多半是模型在推理。
            onProgress(ChatProgress(text: reply, steps: steps, activity: .thinking))
            for try await event in client.send(request) {
                switch event {
                case .reasoning(let delta):
                    thinking += delta
                    if roundText.isEmpty, !delta.isEmpty {
                        onProgress(ChatProgress(text: reply, steps: steps, activity: .thinking, thinking: thinking))
                    }
                case .textDelta(let delta):
                    roundText += delta
                    onProgress(ChatProgress(text: Self.join(reply, roundText), steps: steps, activity: nil))
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
                steps.append(ChatProgress.Step(tool: call.name, done: false))
                onProgress(ChatProgress(text: reply, steps: steps, activity: .tool(call.name)))
                let outcome = await tools.run(call, sessionDate: date, requestID: requestID)
                steps[steps.count - 1].done = true
                steps[steps.count - 1].failed = outcome.output.hasPrefix(#"{"error""#) || outcome.output.contains(#""ok":false"#)
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
    /// 附带确认卡的回复后面加一句客户端注记：历史里只有文字，模型会照着“已生成确认卡”的说法
    /// 直接回答而不调用工具；注记让它看到卡片只来自工具。没有卡片的回复不加注记。
    static func historyInput(_ history: [ChatEntry], limit: Int, cardStatus: (ChatCardRef) -> PendingStatus? = { _ in nil }) -> [LLMInputItem] {
        history.suffix(max(limit, 0)).compactMap { entry in
            switch entry.role {
            case .user:
                return .user(entry.text)
            case .assistant:
                guard let ref = entry.cardRef else { return .assistant(entry.text) }
                let status = switch cardStatus(ref) {
                case .confirmed: "用户已确认，已保存"
                case .cancelled: "用户已取消，没有保存"
                case .expired: "已过期，没有保存"
                case .readyForConfirmation, nil: "等待用户确认"
                }
                return .assistant(entry.text + "\n\n［客户端注：这条回复附带一张由提案工具生成的确认卡，\(status)。］")
            case .toolSummary:
                return nil
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
