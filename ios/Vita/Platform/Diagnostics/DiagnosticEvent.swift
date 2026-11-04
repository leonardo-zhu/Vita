import Foundation

/// 诊断日志的一条事件（`shared/diagnostics/batch.schema.json`，ADR-014）。只有元数据：错误码、版本、耗时、
/// token 数与计数，不含 prompt、消息、饮食、健康数据或任何自由文本。没有值的字段编码时省略。
struct DiagnosticEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case chatTurn = "chat_turn"
        case toolCall = "tool_call"
        case configFetch = "config_fetch"
    }

    var eventId = UUID()
    var occurredAt: Date
    var dataClass = "diagnostic"
    var configVersion: String?
    var type: Kind
    var outcome: String?
    var errorCode: String?
    var requestId: UUID?
    var modelAlias: String?
    var systemPromptVersion: Int?
    var latencyMs: Int
    var rounds: Int?
    var toolCalls: Int?
    var tokensIn: Int?
    var tokensOut: Int?
    var tokensCached: Int?
    var createdPending: Bool?
    var claimedCardWithoutTool: Bool?
    var hitMaxRounds: Bool?
    var tool: String?
    var toolDescriptionVersion: Int?
    var resultCode: String?

    /// 错误码只能是 `a-z0-9_.`：把客户端内部的码压成这个形状，避免带出别的文字。
    static func code(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_.")
        let mapped = String(raw.lowercased().map { allowed.contains($0) ? $0 : "_" }.prefix(64))
        return mapped.first?.isLetter == true ? mapped : "x" + mapped.prefix(63)
    }

    /// 工具结果码同样只留字母数字，长度有限。
    static func resultCode(_ raw: String) -> String {
        let cleaned = raw.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }
        guard let first = cleaned.first, first.isLetter else { return "other" }
        return String(cleaned.prefix(64))
    }

    static func milliseconds(since start: Date, now: Date = Date()) -> Int {
        max(0, Int(now.timeIntervalSince(start) * 1000))
    }
}

/// 一次上报的批次。
struct DiagnosticsBatch: Encodable, Sendable {
    var installId: UUID
    var appVersion: String
    var osVersion: String?
    var events: [DiagnosticEvent]

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

/// 业务代码只依赖它；测试与预览用空实现。
protocol DiagnosticsRecording: Sendable {
    func record(_ event: DiagnosticEvent)
}

struct NoDiagnostics: DiagnosticsRecording {
    func record(_ event: DiagnosticEvent) {}
}
