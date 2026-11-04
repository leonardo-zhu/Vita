import Foundation

/// 确认卡的内容，按变更种类区分。
enum PendingPreview: Equatable, Codable, Sendable {
    case record(ChangePreview)
    case food(FoodChangePreview)
}

/// 确认卡展示所需的一切。
struct PendingSnapshot: Equatable, Sendable, Identifiable {
    var id: UUID
    var sessionDate: LocalDate
    var status: PendingStatus
    var createdAt: Date
    var expiresAt: Date
    var preview: PendingPreview?
    var resolutionCode: String?
    /// 已确认时：记录变更是 Record ID，食品变更是 Food Product ID。
    var resultRecordID: UUID?
    /// 确认后服务端要接着做的下一步（模型在提案里写的），有它时确认后调 `/continue`。
    var afterConfirm: String? = nil

    var recordPreview: ChangePreview? {
        if case .record(let preview) = preview { preview } else { nil }
    }

    var foodPreview: FoodChangePreview? {
        if case .food(let preview) = preview { preview } else { nil }
    }
}

/// 确认门（ADR-004、TDD §5）：提案只由服务端的 Agent 生成，App 只能确认或取消。过期按服务端时钟判断。
@MainActor
final class PendingService {
    private let api: VitaAPIClient

    init(api: VitaAPIClient) {
        self.api = api
    }

    /// 该日期当前可确认的卡片（最多一张）。
    func active(on date: LocalDate) async throws -> PendingSnapshot? {
        let response: ActivePendingResponseDTO = try await api.get("/v1/days/\(date.isoString)/pending")
        return try response.pending?.domain()
    }

    func pending(_ id: UUID) async throws -> PendingSnapshot {
        let response: PendingResponseDTO = try await api.get("/v1/pending/\(id.apiString)")
        return try response.pending.domain()
    }

    /// 确认并写入。卡片作废（revisionConflict）、过期（expired）等由服务端拒绝，`APIError.userMessage` 说明原因。
    @discardableResult
    func confirm(_ id: UUID) async throws -> PendingSnapshot {
        let response: PendingResponseDTO = try await api.send("POST", "/v1/pending/\(id.apiString)/confirm")
        return try response.pending.domain()
    }

    func cancel(_ id: UUID) async throws {
        let _: PendingResponseDTO = try await api.send("POST", "/v1/pending/\(id.apiString)/cancel")
    }
}
