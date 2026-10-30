import Foundation
import SwiftData

/// 正式写入前的可恢复提案（ADR-008）。落盘以便重启后恢复，但不是正式数据，从不计入汇总。
/// 结束（确认、取消、过期）后清空 payload 与预览，只保留状态，供对话中的卡片显示结果。
@Model
final class PendingAction {
    @Attribute(.unique) var id: UUID
    var sessionDateKey: String
    /// 创建时捕获的 Session revision；确认时不一致即作废（TDD §5.2）。
    var expectedRevision: Int
    var payloadData: Data?
    /// payload 的 SHA-256，确认前核对，防止落盘内容被改动后仍被执行。
    var payloadHash: String
    var previewData: Data?
    var statusRaw: String
    var createdAt: Date
    var expiresAt: Date
    var resolvedAt: Date?
    /// 结束原因的机器码，如 `replaced`、`revisionConflict`。
    var resolutionCode: String?
    var resultRecordID: UUID?
    var requestID: UUID?

    init(
        id: UUID = UUID(),
        sessionDate: LocalDate,
        expectedRevision: Int,
        payloadData: Data,
        payloadHash: String,
        previewData: Data,
        createdAt: Date,
        expiresAt: Date,
        requestID: UUID?
    ) {
        self.id = id
        self.sessionDateKey = sessionDate.isoString
        self.expectedRevision = expectedRevision
        self.payloadData = payloadData
        self.payloadHash = payloadHash
        self.previewData = previewData
        self.statusRaw = PendingStatus.readyForConfirmation.rawValue
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.requestID = requestID
    }

    var status: PendingStatus {
        PendingStatus(rawValue: statusRaw) ?? .expired
    }

    var sessionDate: LocalDate {
        LocalDate(isoString: sessionDateKey)!
    }

    func resolve(_ status: PendingStatus, code: String?, at date: Date, recordID: UUID? = nil) {
        statusRaw = status.rawValue
        resolutionCode = code
        resolvedAt = date
        resultRecordID = recordID
        payloadData = nil
        previewData = nil
    }
}
