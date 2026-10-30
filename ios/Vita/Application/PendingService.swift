import CryptoKit
import Foundation
import SwiftData

enum PendingServiceError: Error, Equatable {
    case notFound
    /// 该日期已有活跃 Pending，新的独立写入被拒绝；修正须指明替换它（agent-tools.md 状态机）。
    case anotherPendingActive(UUID)
    case notActive(PendingStatus)
    case expired
    case payloadTampered
    /// 提案之后当天数据（或食品的生效版本）已变化，提案作废，需要重新生成。
    case revisionConflict
}

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

    var recordPreview: ChangePreview? {
        if case .record(let preview) = preview { preview } else { nil }
    }

    var foodPreview: FoodChangePreview? {
        if case .food(let preview) = preview { preview } else { nil }
    }
}

/// 确认门（ADR-004、TDD §5）。模型只能经 `propose` 创建提案；`confirm` / `cancel` 只由卡片交互调用，
/// `expireDue` 由时钟与生命周期事件调用。每个入口先清理过期项。
@MainActor
final class PendingService {
    private let context: ModelContext
    private let records: RecordService
    private let foods: FoodService
    private let now: () -> Date
    private let timeZone: () -> TimeZone

    init(context: ModelContext, records: RecordService, foods: FoodService, now: @escaping () -> Date = Date.init, timeZone: @escaping () -> TimeZone = { .current }) {
        self.context = context
        self.records = records
        self.foods = foods
        self.now = now
        self.timeZone = timeZone
    }

    /// 校验并保存提案。校验与正式写入走同一套规则，校验不过不会产生 Pending。
    /// 该日期已有活跃 Pending 时，只有 `replacing` 指向它才允许替换。
    @discardableResult
    func propose(
        _ change: RecordChange,
        on date: LocalDate,
        expectedRevision: Int,
        replacing: UUID? = nil,
        requestID: UUID? = nil
    ) throws -> PendingSnapshot {
        try store(on: date, expectedRevision: expectedRevision, replacing: replacing, requestID: requestID) {
            (.record(change), .record(try records.preview(change, on: date, expectedRevision: expectedRevision)))
        }
    }

    /// 食品变更的提案。仍占用所在日期的唯一 Pending 名额（agent-tools.md 状态机）。
    @discardableResult
    func propose(food change: FoodChange, on date: LocalDate, replacing: UUID? = nil, requestID: UUID? = nil) throws -> PendingSnapshot {
        try store(on: date, expectedRevision: 0, replacing: replacing, requestID: requestID) {
            (.food(change), .food(try foods.preview(change)))
        }
    }

    private func store(
        on date: LocalDate,
        expectedRevision: Int,
        replacing: UUID?,
        requestID: UUID?,
        validate: () throws -> (PendingChange, PendingPreview)
    ) throws -> PendingSnapshot {
        try expireDue()
        let active = try activeAction(on: date)
        if let active, active.id != replacing {
            throw PendingServiceError.anotherPendingActive(active.id)
        }
        if let replacing, active?.id != replacing {
            throw PendingServiceError.notFound
        }

        let (change, preview) = try validate()
        let createdAt = now()
        let payload = JSONColumn.encode(change)
        let action = PendingAction(
            sessionDate: date,
            expectedRevision: expectedRevision,
            payloadData: payload,
            payloadHash: Self.hash(payload),
            previewData: JSONColumn.encode(preview),
            createdAt: createdAt,
            expiresAt: PendingPolicy.expiresAt(createdAt: createdAt, timeZone: timeZone()),
            requestID: requestID
        )
        active?.resolve(.cancelled, code: "replaced", at: createdAt)
        context.insert(action)
        context.insert(AuditEvent(operation: "pending.propose", targetID: action.id.uuidString, result: .success, requestID: requestID, createdAt: createdAt))
        try save()
        return try snapshot(action)
    }

    /// 用户点击确认：执行保存时的原始 payload，并在同一事务里把 Pending 标为已确认。
    @discardableResult
    func confirm(_ id: UUID) throws -> UUID {
        try expireDue()
        let action = try find(id)
        guard action.status == .readyForConfirmation else {
            throw action.status == .expired ? PendingServiceError.expired : PendingServiceError.notActive(action.status)
        }
        guard let payload = action.payloadData, Self.hash(payload) == action.payloadHash,
              let change = try? JSONColumn.decode(PendingChange.self, from: payload)
        else {
            try invalidate(action, code: "payloadTampered")
            throw PendingServiceError.payloadTampered
        }

        let markConfirmed = { (id: UUID) in action.resolve(.confirmed, code: nil, at: self.now(), recordID: id) }
        do {
            switch change {
            case .record(let change):
                return try records.apply(change, on: action.sessionDate, expectedRevision: action.expectedRevision, requestID: action.requestID, alongside: markConfirmed)
            case .food(let change):
                return try foods.apply(change, requestID: action.requestID, alongside: markConfirmed)
            }
        } catch RecordServiceError.revisionConflict, FoodServiceError.activeVersionChanged {
            try invalidate(action, code: "revisionConflict")
            throw PendingServiceError.revisionConflict
        }
        // 其他失败（如引用的食品版本已退役）保留 Pending，由用户取消或等待过期。
    }

    func cancel(_ id: UUID) throws {
        try expireDue()
        let action = try find(id)
        guard action.status == .readyForConfirmation else { throw PendingServiceError.notActive(action.status) }
        action.resolve(.cancelled, code: "userCancelled", at: now())
        context.insert(AuditEvent(operation: "pending.cancel", targetID: id.uuidString, result: .success, createdAt: now()))
        try save()
    }

    /// 应用启动、回到前台、切换日期、显示卡片和提交前调用（TDD §5.3）。
    func expireDue() throws {
        let timestamp = now()
        let ready = PendingStatus.readyForConfirmation.rawValue
        let due = try context.fetch(FetchDescriptor<PendingAction>(
            predicate: #Predicate { $0.statusRaw == ready && $0.expiresAt <= timestamp }
        ))
        guard !due.isEmpty else { return }
        for action in due {
            action.resolve(.expired, code: nil, at: timestamp)
            context.insert(AuditEvent(operation: "pending.expire", targetID: action.id.uuidString, result: .success, createdAt: timestamp))
        }
        try save()
    }

    /// 该日期当前可确认的 Pending（最多一个）。
    func active(on date: LocalDate) throws -> PendingSnapshot? {
        try expireDue()
        return try activeAction(on: date).map(snapshot)
    }

    func pending(_ id: UUID) throws -> PendingSnapshot {
        try expireDue()
        return try snapshot(find(id))
    }

    // MARK: - 私有

    private func activeAction(on date: LocalDate) throws -> PendingAction? {
        let key = date.isoString
        let ready = PendingStatus.readyForConfirmation.rawValue
        return try context.fetch(FetchDescriptor<PendingAction>(
            predicate: #Predicate { $0.sessionDateKey == key && $0.statusRaw == ready }
        )).first
    }

    private func find(_ id: UUID) throws -> PendingAction {
        var descriptor = FetchDescriptor<PendingAction>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let action = try context.fetch(descriptor).first else { throw PendingServiceError.notFound }
        return action
    }

    private func invalidate(_ action: PendingAction, code: String) throws {
        action.resolve(.cancelled, code: code, at: now())
        context.insert(AuditEvent(operation: "pending.invalidate", targetID: action.id.uuidString, result: .failure, errorCode: "pending.\(code)", createdAt: now()))
        try save()
    }

    private func save() throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    private func snapshot(_ action: PendingAction) throws -> PendingSnapshot {
        PendingSnapshot(
            id: action.id,
            sessionDate: action.sessionDate,
            status: action.status,
            createdAt: action.createdAt,
            expiresAt: action.expiresAt,
            preview: try action.previewData.map { try JSONColumn.decode(PendingPreview.self, from: $0) },
            resolutionCode: action.resolutionCode,
            resultRecordID: action.resultRecordID
        )
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
