import Foundation

/// 界面显示的一条消息。
struct ChatEntry: Equatable, Sendable, Identifiable {
    var id: UUID
    var role: ChatRole
    var text: String
    var cardRef: ChatCardRef?
    var createdAt: Date
}

/// 一轮对话的结果。
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
            case "getBodyComposition": "读取身体成分"
            case "getGoalRecommendation": "计算目标建议"
            case "attachNutritionLabel": "读取营养标签"
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

/// 这一轮服务端没有保存（用户消息也没有），界面把原文放回输入框。
struct ChatTurnError: Error, Equatable {
    var code: String
    var message: String
}

/// 对话（架构设计 §10）：Agent 在服务端跑，进度经 SSE 推回。一个日期一个会话，历史存在服务端。
/// 客户端断线时这一轮在服务端照样跑完并保存，只有 `stop()` 调停止接口才中止。
@MainActor
final class ChatService {
    private let api: VitaAPIClient
    /// 进行中那一轮的 ID，停止时用。
    private var runningRequestID: UUID?

    init(api: VitaAPIClient) {
        self.api = api
    }

    func messages(on date: LocalDate) async throws -> [ChatEntry] {
        let response: MessagesResponseDTO = try await api.get("/v1/days/\(date.isoString)/messages")
        return response.messages.map(\.domain)
    }

    /// 发一条消息。照片先经 `LabelScanService.upload` 传上去，这里只带它的 ID。
    func send(_ text: String, on date: LocalDate, labelScan: UUID? = nil, onProgress: @escaping (ChatProgress) -> Void = { _ in }) async throws -> ChatTurnResult {
        try await run(api.stream("/v1/days/\(date.isoString)/chat", body: ChatRequestDTO(text: text, labelScanId: labelScan)), onProgress: onProgress)
    }

    /// 确认了一张带 `afterConfirm` 的卡片后接着跑一轮。每张卡片只能接续一次。
    func continueAfterConfirm(_ pendingID: UUID, onProgress: @escaping (ChatProgress) -> Void = { _ in }) async throws -> ChatTurnResult {
        try await run(api.stream("/v1/pending/\(pendingID.apiString)/continue", body: Optional<ChatRequestDTO>.none), onProgress: onProgress)
    }

    /// 让服务端停止进行中的那一轮；这一轮什么都不保存。在取消本地任务之前调用（取消后就不知道是哪一轮了）。
    func stop() {
        guard let id = runningRequestID else { return }
        let api = api
        Task { try? await api.perform("POST", "/v1/chat-turns/\(id.apiString)/cancel") }
    }

    private func run(_ events: AsyncThrowingStream<ChatEventDTO, Error>, onProgress: @escaping (ChatProgress) -> Void) async throws -> ChatTurnResult {
        var progress = ChatProgress(text: "", activity: .thinking)
        /// 服务端的步骤序号 → 清单里的位置。
        var stepPositions: [Int: Int] = [:]
        defer { runningRequestID = nil }
        for try await event in events {
            switch event {
            case .started(let id):
                runningRequestID = id
            case .reasoning(let delta):
                progress.thinking += delta
                if progress.activity == nil || progress.text.isEmpty { progress.activity = .thinking }
            case .text(let delta):
                progress.text += delta
                progress.activity = nil
            case .step(let index, let tool, let status):
                if let position = stepPositions[index] {
                    progress.steps[position].done = status != "running"
                    progress.steps[position].failed = status == "failed"
                    progress.activity = .thinking
                } else {
                    stepPositions[index] = progress.steps.count
                    progress.steps.append(.init(tool: tool, done: status != "running", failed: status == "failed"))
                    progress.activity = .tool(tool)
                }
                // 工具结束后模型重新开始思考，推理摘要从头显示。
                progress.thinking = ""
            case .done(let reply, let pendingID, let requestedDate, let goalChanged):
                return ChatTurnResult(reply: reply.domain, pendingID: pendingID, requestedDate: requestedDate, goalChanged: goalChanged)
            case .error(let code, let message):
                if code == "cancelled" { throw CancellationError() }
                throw ChatTurnError(code: code, message: message)
            }
            onProgress(progress)
        }
        // 流断了却没有收到结果：这一轮可能还在服务端跑，界面重新读历史即可看到。
        throw APIError.offline("stream ended without a result")
    }
}
