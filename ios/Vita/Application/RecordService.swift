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
    /// 用量来源是“按包装换算”，但引用的不是带包装规格的个人食品，或单位与包装不符。
    case packageUnavailable
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
        case .packageUnavailable: "packageUnavailable"
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
    private let sourceLabels: SourceLabeler
    /// 在同一事务里登记 HealthKit 同步（TDD §4.1）。
    private weak var observer: (any RecordChangeObserver)?

    init(
        context: ModelContext,
        referenceFoods: ReferenceFoodCatalog,
        now: @escaping () -> Date = Date.init,
        timeZone: @escaping () -> TimeZone = { .current },
        observer: (any RecordChangeObserver)? = nil
    ) {
        self.observer = observer
        self.context = context
        self.referenceFoods = referenceFoods
        self.now = now
        self.timeZone = timeZone
        self.sourceLabels = SourceLabeler(context: context, referenceFoods: referenceFoods)
    }

    // MARK: - 变更入口

    /// 只校验、不写入，返回变更后的预览。Pending 创建时用它确认提案可以执行（agent-tools.md）。
    func preview(_ change: RecordChange, on date: LocalDate, expectedRevision: Int) throws -> ChangePreview {
        try prepare(change, on: date, expectedRevision: expectedRevision).preview
    }

    /// 执行变更。`alongside` 与变更处于同一事务，供确认 Pending 时一并更新其状态（TDD §4.1）。
    /// 返回受影响的 Record ID（删除时为被删的 ID）。
    @discardableResult
    func apply(
        _ change: RecordChange,
        on date: LocalDate,
        expectedRevision: Int,
        requestID: UUID? = nil,
        alongside: (UUID) throws -> Void = { _ in }
    ) throws -> UUID {
        try perform(change.auditOperation, target: change.targetRecordID, requestID: requestID) {
            let recordID = try self.prepare(change, on: date, expectedRevision: expectedRevision).commit()
            if case .deleteRecord = change {
                try self.observer?.recordChanged(recordID, deleted: true)
            } else {
                try self.observer?.recordChanged(recordID, deleted: false)
            }
            try alongside(recordID)
            return recordID
        }
    }

    @discardableResult
    func createRecord(on date: LocalDate, expectedRevision: Int, draft: RecordDraft, requestID: UUID? = nil) throws -> UUID {
        try apply(.create(draft), on: date, expectedRevision: expectedRevision, requestID: requestID)
    }

    func appendItems(_ drafts: [ItemDraft], to recordID: UUID, on date: LocalDate, expectedRevision: Int, requestID: UUID? = nil) throws {
        try apply(.appendItems(recordID: recordID, items: drafts), on: date, expectedRevision: expectedRevision, requestID: requestID)
    }

    func replaceItem(_ itemID: UUID, with draft: ItemDraft, in recordID: UUID, on date: LocalDate, expectedRevision: Int, requestID: UUID? = nil) throws {
        try apply(.replaceItem(recordID: recordID, itemID: itemID, item: draft), on: date, expectedRevision: expectedRevision, requestID: requestID)
    }

    /// 移除最后一项会留下空 Record，须改用 `deleteRecord`。
    func removeItem(_ itemID: UUID, from recordID: UUID, on date: LocalDate, expectedRevision: Int, requestID: UUID? = nil) throws {
        try apply(.removeItem(recordID: recordID, itemID: itemID), on: date, expectedRevision: expectedRevision, requestID: requestID)
    }

    func deleteRecord(_ recordID: UUID, on date: LocalDate, expectedRevision: Int, requestID: UUID? = nil) throws {
        try apply(.deleteRecord(recordID: recordID), on: date, expectedRevision: expectedRevision, requestID: requestID)
    }

    // MARK: - 校验与执行

    /// 校验全部在这里完成且不修改任何实体；`commit` 只做已校验的修改，不再失败。
    private struct Prepared {
        var preview: ChangePreview
        var commit: () -> UUID
    }

    private func prepare(_ change: RecordChange, on date: LocalDate, expectedRevision: Int) throws -> Prepared {
        switch change {
        case .create(let draft):
            let session = try context.session(on: date)
            try Self.check(expectedRevision, against: session?.revision ?? 0)
            guard draft.eventTime.localDate == date else { throw RecordServiceError.eventTimeOutsideSession }
            let items = try resolve(draft.items)
            let preview = ChangePreview(
                kind: .create, recordLabel: draft.mealLabel, eventTime: draft.eventTime,
                items: try items.map(previewItem), removedItemNames: []
            )
            return Prepared(preview: preview) {
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

        case .appendItems(let recordID, let drafts):
            let (session, record) = try locate(recordID, on: date, expectedRevision: expectedRevision)
            let items = try resolve(drafts)
            let preview = try recordPreview(.appendItems, record, items: try items.map(previewItem), removed: [])
            return Prepared(preview: preview) {
                let timestamp = self.now()
                let next = (record.items.map(\.position).max() ?? -1) + 1
                self.insert(items, into: record, startingAt: next, now: timestamp)
                self.touch(record, now: timestamp)
                self.bump(session, now: timestamp)
                return record.id
            }

        case .replaceItem(let recordID, let itemID, let draft):
            let (session, record) = try locate(recordID, on: date, expectedRevision: expectedRevision)
            guard let item = record.items.first(where: { $0.id == itemID }) else { throw RecordServiceError.itemNotFound }
            let resolved = try resolve([draft])[0]
            let preview = try recordPreview(.replaceItem, record, items: [try previewItem(resolved)], removed: [item.displayName])
            return Prepared(preview: preview) {
                let timestamp = self.now()
                item.apply(draft, snapshot: resolved.snapshot, foodProductID: resolved.foodProductID, now: timestamp)
                self.touch(record, now: timestamp)
                self.bump(session, now: timestamp)
                return record.id
            }

        case .removeItem(let recordID, let itemID):
            let (session, record) = try locate(recordID, on: date, expectedRevision: expectedRevision)
            guard let item = record.items.first(where: { $0.id == itemID }) else { throw RecordServiceError.itemNotFound }
            guard record.items.count > 1 else { throw RecordServiceError.emptyRecord }
            let preview = try recordPreview(.removeItem, record, items: [], removed: [item.displayName])
            return Prepared(preview: preview) {
                let timestamp = self.now()
                record.items.removeAll { $0.id == itemID }
                self.context.delete(item)
                self.touch(record, now: timestamp)
                self.bump(session, now: timestamp)
                return record.id
            }

        case .deleteRecord(let recordID):
            let (session, record) = try locate(recordID, on: date, expectedRevision: expectedRevision)
            let preview = try recordPreview(.deleteRecord, record, items: [], removed: record.orderedItems.map(\.displayName))
            return Prepared(preview: preview) {
                session.records.removeAll { $0.id == recordID }
                self.context.delete(record)
                self.bump(session, now: self.now())
                return recordID
            }
        }
    }

    private func recordPreview(_ kind: ChangePreview.Kind, _ record: ConsumptionRecord, items: [DayData.Item], removed: [String]) throws -> ChangePreview {
        ChangePreview(kind: kind, recordLabel: record.mealLabel, eventTime: try record.eventTime(), items: items, removedItemNames: removed)
    }

    private func previewItem(_ resolved: ResolvedItem) throws -> DayData.Item {
        let draft = resolved.draft
        let label: String? = switch draft.nutrition {
        case .referenceFood(let id): try sourceLabels.label(referenceFoodID: id, foodVersionID: nil)
        case .personalFoodVersion(let id): try sourceLabels.label(referenceFoodID: nil, foodVersionID: id)
        case .aiEstimated: nil
        }
        return DayData.Item(
            id: UUID(), displayName: draft.displayName, groupName: draft.groupName,
            originalAmountText: draft.originalAmountText, quantity: draft.quantity,
            amountSource: draft.amountSource, includeInSummary: draft.includeInSummary,
            snapshot: resolved.snapshot, sourceLabel: label
        )
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
        // “一盒、半瓶”只能按个人食品的包装规格换算（PRD §3.2.1 package_size）。
        if draft.amountSource == .packageConversion {
            guard case .personalFoodVersion = draft.nutrition else { throw ItemRejection.packageUnavailable }
        }

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
                if draft.amountSource == .packageConversion {
                    guard let package = try version.product?.package(), package.unit == quantity.unit else {
                        throw ItemRejection.packageUnavailable
                    }
                }
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
