import Foundation
import SwiftData

enum AuditResult: String, Codable, Sendable {
    case success, failure
}

/// 本地技术审计（ADR-010）：记录操作、结果、对象 ID 与错误码，
/// 不保存完整自由文本或原始图片。
@Model
final class AuditEvent {
    @Attribute(.unique) var id: UUID
    var operation: String
    var targetID: String?
    var resultRaw: String
    var errorCode: String?
    var requestID: UUID?
    var createdAt: Date

    var result: AuditResult {
        get { AuditResult(rawValue: resultRaw) ?? .failure }
        set { resultRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        operation: String,
        targetID: String? = nil,
        result: AuditResult,
        errorCode: String? = nil,
        requestID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.operation = operation
        self.targetID = targetID
        self.resultRaw = result.rawValue
        self.errorCode = errorCode
        self.requestID = requestID
        self.createdAt = createdAt
    }
}
