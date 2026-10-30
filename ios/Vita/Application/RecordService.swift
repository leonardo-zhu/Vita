import Foundation
import SwiftData

enum RecordServiceError: Error, Equatable {
    case revisionConflict(expected: Int, actual: Int)
    case recordNotFound
    case recordNotInSession
    case itemNotFound
    case emptyRecord
    case eventTimeOutsideSession
    case invalidItem(index: Int, reason: ItemRejection)

    /// 写进审计日志的错误码（ADR-010），不含自由文本。
    var auditCode: String {
        switch self {
        case .revisionConflict: "record.revisionConflict"
        case .recordNotFound: "record.notFound"
        case .recordNotInSession: "record.notInSession"
        case .itemNotFound: "record.itemNotFound"
        case .emptyRecord: "record.empty"
        case .eventTimeOutsideSession: "record.eventTimeOutsideSession"
        case .invalidItem(_, let reason): "record.invalidItem.\(reason.code)"
        }
    }
}

enum ItemRejection: Error, Equatable {
    case emptyName
    case emptyAmountText
    /// 没有标准化用量时只能是 AI 估算，且用量来源也须标为估算（TDD §3.3）。
    case quantityRequired
    case amountSourceInconsistent
    case unknownReferenceFood(String)
    case unknownFoodVersion(UUID)
    case retiredFoodVersion(UUID)
    case invalidEstimate
    case calculation(NutritionCalculationError)

    var code: String {
        switch self {
        case .emptyName: "emptyName"
        case .emptyAmountText: "emptyAmountText"
        case .quantityRequired: "quantityRequired"
        case .amountSourceInconsistent: "amountSourceInconsistent"
        case .unknownReferenceFood: "unknownReferenceFood"
        case .unknownFoodVersion: "unknownFoodVersion"
        case .retiredFoodVersion: "retiredFoodVersion"
        case .invalidEstimate: "invalidEstimate"
        case .calculation: "calculation"
        }
    }
}

/// Record 的正式写入。Phase 2 的确认门、手工 UI 都经由这里，模型不直接调用（ADR-004）。
///
/// 每个操作是一个事务（TDD §4.1）：先全部校验，再修改实体、递增 Session revision、写审计，
/// 最后一次保存；任一步失败则回滚，并单独记一条失败审计。
@MainActor
final class RecordService {
    private let context: ModelContext
    private let referenceFoods: ReferenceFoodCatalog
    private let now: () -> Date
    private let timeZone: () -> TimeZone

    init(
        context: ModelContext,
        referenceFoods: ReferenceFoodCatalog,
        now: @escaping () -> Date = Date.init,
        timeZone: @escaping () -> TimeZone = { .current }
    ) {
        self.context = context
        self.referenceFoods = referenceFoods
        self.now = now
        self.timeZone = timeZone
    }

    @discardableResult
    func createRecord(on date: LocalDate, expectedRevision: Int, draft: RecordDraft, requestID: UUID? = nil) throws -> UUID {
        try perform("record.create", requestID: requestID) {
            let session = try self.context.session(on: date)
            try Self.check(expectedRevision, against: session?.revision ?? 0)
            guard draft.eventTime.localDate == date else { throw RecordServiceError.eventTimeOutsideSession }
            let items = try self.resolve(draft.items)

            let timestamp = self.now()
            let target = session ?? {
                let created = DaySession(localDate: date, timeZoneIdentifier: self.timeZone().identifier, now: timestamp)
                self.context.insert(created)
                return created
            }()
            let record = ConsumptionRecord(eventTime: draft.eventTime, mealLabel: draft.mealLabel, note: draft.note, now: timestamp)
            self.context.insert(record)
            record.session = target
            self.insert(items, into: record, startingAt: 0, now: timestamp)
            self.bump(target, now: timestamp)
            return record.id
        }
    }

    func appendItems(_ drafts: [ItemDraft], to recordID: UUID, on date: LocalDate, expectedRevision: Int, requestID: UUID? = nil) throws {
        try perform("record.appendItems", target: recordID, requestID: requestID) {
            let (session, record) = try self.locate(recordID, on: date, expectedRevision: expectedRevision)
            guard !drafts.isEmpty else { throw RecordServiceError.emptyRecord }
            let items = try self.resolve(drafts)
            let timestamp = self.now()
            let next = (record.items.map(\.position).max() ?? -1) + 1
            self.insert(items, into: record, startingAt: next, now: timestamp)
            self.touch(record, now: timestamp)
            self.bump(session, now: timestamp)
        }
    }

    func replaceItem(_ itemID: UUID, with draft: ItemDraft, in recordID: UUID, on date: LocalDate, expectedRevision: Int, requestID: UUID? = nil) throws {
        try perform("record.replaceItem", target: recordID, requestID: requestID) {
            let (session, record) = try self.locate(recordID, on: date, expectedRevision: expectedRevision)
            guard let item = record.items.first(where: { $0.id == itemID }) else { throw RecordServiceError.itemNotFound }
            let resolved = try self.resolve([draft])[0]
            let timestamp = self.now()
            item.apply(draft, snapshot: resolved.snapshot, foodProductID: resolved.foodProductID, now: timestamp)
            self.touch(record, now: timestamp)
            self.bump(session, now: timestamp)
        }
    }

    /// 移除最后一项会留下空 Record，须改用 `deleteRecord`。
    func removeItem(_ itemID: UUID, from recordID: UUID, on date: LocalDate, expectedRevision: Int, requestID: UUID? = nil) throws {
        try perform("record.removeItem", target: recordID, requestID: requestID) {
            let (session, record) = try self.locate(recordID, on: date, expectedRevision: expectedRevision)
            guard let item = record.items.first(where: { $0.id == itemID }) else { throw RecordServiceError.itemNotFound }
            guard record.items.count > 1 else { throw RecordServiceError.emptyRecord }
            let timestamp = self.now()
            record.items.removeAll { $0.id == itemID }
            self.context.delete(item)
            self.touch(record, now: timestamp)
            self.bump(session, now: timestamp)
        }
    }

    func deleteRecord(_ recordID: UUID, on date: LocalDate, expectedRevision: Int, requestID: UUID? = nil) throws {
        try perform("record.delete", target: recordID, requestID: requestID) {
            let (session, record) = try self.locate(recordID, on: date, expectedRevision: expectedRevision)
            session.records.removeAll { $0.id == recordID }
            self.context.delete(record)
            self.bump(session, now: self.now())
        }
    }

    // MARK: - 事务

    private func perform<T>(_ operation: String, target: UUID? = nil, requestID: UUID?, _ body: () throws -> T) throws -> T {
        do {
            let result = try body()
            let targetID = target ?? (result as? UUID)
            context.insert(AuditEvent(operation: operation, targetID: targetID?.uuidString, result: .success, requestID: requestID, createdAt: now()))
            try context.save()
            return result
        } catch {
            context.rollback()
            let code = (error as? RecordServiceError)?.auditCode ?? "record.persistence"
            context.insert(AuditEvent(operation: operation, targetID: target?.uuidString, result: .failure, errorCode: code, requestID: requestID, createdAt: now()))
            try? context.save()
            throw error
        }
    }

    private static func check(_ expected: Int, against actual: Int) throws {
        guard expected == actual else { throw RecordServiceError.revisionConflict(expected: expected, actual: actual) }
    }

    /// 取目标 Record 并确认它属于当前 Session，模型不能借 ID 跨日期操作（agent-tools.md 公共信封）。
    private func locate(_ recordID: UUID, on date: LocalDate, expectedRevision: Int) throws -> (DaySession, ConsumptionRecord) {
        guard let session = try context.session(on: date) else { throw RecordServiceError.recordNotFound }
        try Self.check(expectedRevision, against: session.revision)
        guard let record = try context.record(id: recordID) else { throw RecordServiceError.recordNotFound }
        guard record.session?.id == session.id else { throw RecordServiceError.recordNotInSession }
        return (session, record)
    }

    private func bump(_ session: DaySession, now: Date) {
        session.revision += 1
        session.updatedAt = now
    }

    private func touch(_ record: ConsumptionRecord, now: Date) {
        record.revision += 1
        record.updatedAt = now
    }

    // MARK: - Item 校验与营养计算

    private struct ResolvedItem {
        var draft: ItemDraft
        var snapshot: NutritionSnapshot
        var foodProductID: UUID?
    }

    private func insert(_ items: [ResolvedItem], into record: ConsumptionRecord, startingAt position: Int, now: Date) {
        for (offset, resolved) in items.enumerated() {
            let item = ConsumptionItem(position: position + offset, now: now)
            context.insert(item)
            item.apply(resolved.draft, snapshot: resolved.snapshot, foodProductID: resolved.foodProductID, now: now)
            item.record = record
        }
    }

    private func resolve(_ drafts: [ItemDraft]) throws -> [ResolvedItem] {
        guard !drafts.isEmpty else { throw RecordServiceError.emptyRecord }
        return try drafts.enumerated().map { index, draft in
            do {
                return try resolve(draft)
            } catch let rejection as ItemRejection {
                throw RecordServiceError.invalidItem(index: index, reason: rejection)
            }
        }
    }

    private func resolve(_ draft: ItemDraft) throws -> ResolvedItem {
        guard !draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ItemRejection.emptyName }
        guard !draft.originalAmountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ItemRejection.emptyAmountText
        }
        if draft.quantity == nil, draft.amountSource != .aiEstimated { throw ItemRejection.amountSourceInconsistent }

        do {
            switch draft.nutrition {
            case .referenceFood(let referenceID):
                guard let quantity = draft.quantity else { throw ItemRejection.quantityRequired }
                guard let food = referenceFoods.food(id: referenceID) else { throw ItemRejection.unknownReferenceFood(referenceID) }
                let snapshot = try NutritionCalculator.snapshot(
                    source: .referenceFood, sourceRef: food.id,
                    basisQuantity: food.base.asQuantity, basisNutrients: food.nutrients,
                    quantity: quantity, densityGPerMl: food.densityGPerMl
                )
                return ResolvedItem(draft: draft, snapshot: snapshot)

            case .personalFoodVersion(let versionID):
                guard let quantity = draft.quantity else { throw ItemRejection.quantityRequired }
                guard let version = try context.foodVersion(id: versionID) else { throw ItemRejection.unknownFoodVersion(versionID) }
                guard version.retiredAt == nil else { throw ItemRejection.retiredFoodVersion(versionID) }
                let basis = try version.basis()
                let snapshot = try NutritionCalculator.snapshot(
                    source: .personalFoodVersion, sourceRef: versionID.uuidString,
                    basisQuantity: basis.quantity, basisNutrients: basis.nutrients, quantity: quantity
                )
                return ResolvedItem(draft: draft, snapshot: snapshot, foodProductID: version.product?.id)

            case .aiEstimated(let values, let estimateBasis):
                guard values.isValid, !estimateBasis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ItemRejection.invalidEstimate
                }
                if let quantity = draft.quantity, quantity.amount <= 0 { throw ItemRejection.calculation(.nonPositiveQuantity) }
                let snapshot = NutritionCalculator.estimatedSnapshot(values: values, estimateBasis: estimateBasis, quantity: draft.quantity)
                return ResolvedItem(draft: draft, snapshot: snapshot)
            }
        } catch let error as NutritionCalculationError {
            throw ItemRejection.calculation(error)
        }
    }
}
