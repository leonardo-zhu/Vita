import Foundation
import SwiftData

/// Record 正式写入时在同一事务里调用，登记需要同步的变化。
@MainActor
protocol RecordChangeObserver: AnyObject {
    func recordChanged(_ recordID: UUID, deleted: Bool) throws
}

/// 把已确认的饮食记录同步到 Apple 健康（ADR-009、TDD §6.3）。
///
/// 每条记录在“健康”里只对应一组 Sample。任何一次同步都先删掉映射里的旧 Sample，再按提交时的快照写新 Sample；
/// 所以同一条记录积压了多次修改时，只需执行最新的一次，结果就只剩最新版。
/// 删除失败不清映射；没有写入权限时本地记录照常，同步状态显示为待处理。
@MainActor
final class HealthSyncService: RecordChangeObserver {
    static let metadataSchemaVersion = "1"

    private let context: ModelContext
    private let store: any HealthDataStore
    private let now: () -> Date
    private var isRunning = false

    init(context: ModelContext, store: any HealthDataStore, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.store = store
        self.now = now
    }

    // MARK: - 登记（与 Record 同一事务，不单独保存）

    func recordChanged(_ recordID: UUID, deleted: Bool) throws {
        let samples: [DietarySample]?
        if deleted {
            samples = nil
        } else {
            guard let record = try context.record(id: recordID) else { return }
            samples = try Self.samples(for: record)
        }
        let last = try context.fetch(FetchDescriptor<HealthSyncOperation>(sortBy: [SortDescriptor(\.sequence, order: .reverse)])).first
        context.insert(HealthSyncOperation(
            recordID: recordID, kind: deleted ? .delete : .write,
            sequence: (last?.sequence ?? 0) + 1, samples: samples, now: now()
        ))
    }

    /// 每项营养一条 Sample，值为计入汇总的 Item 之和；为 0 的不写。时间按 TDD §6.4。
    static func samples(for record: ConsumptionRecord) throws -> [DietarySample] {
        let eventTime = try record.eventTime()
        var totals = NutrientValues.zero
        for item in record.items where item.includeInSummary {
            totals = totals + (try item.snapshot().values)
        }
        var metadata = [
            "vita.recordID": record.id.uuidString,
            "vita.recordRevision": String(record.revision),
            "vita.timePrecision": eventTime.precision.rawValue,
            "vita.schemaVersion": metadataSchemaVersion,
        ]
        switch eventTime.precision {
        case .mealPeriod:
            metadata["vita.timeWasRepresentative"] = "true"
            metadata["vita.mealPeriod"] = eventTime.mealPeriod?.rawValue
        case .dateOnly:
            metadata["vita.timeWasRepresentative"] = "true"
        case .defaultedEntryTime:
            metadata["vita.timeDefaultedAtEntry"] = "true"
        case .exact, .approximate:
            break
        }
        return Nutrient.allCases.compactMap { nutrient in
            let value = nutrient.value(in: totals)
            guard value > 0 else { return nil }
            return DietarySample(nutrient: nutrient, value: value, date: eventTime.representativeTimestamp, metadata: metadata)
        }
    }

    // MARK: - 执行

    struct RunResult: Equatable {
        var synced = 0
        var failed = 0
        var waitingForPermission = 0
    }

    /// 启动、回到前台、确认记录后与用户点“重试”时调用。同一时间只跑一次。
    @discardableResult
    func run() async -> RunResult {
        guard !isRunning else { return RunResult() }
        isRunning = true
        defer { isRunning = false }
        var result = RunResult()

        let operations = (try? latestOperations()) ?? []
        guard !operations.isEmpty else { return result }

        let authorization = store.isAvailable ? store.writeAuthorization() : .denied
        guard authorization == .authorized else {
            // 从未授权时保持待同步，不打扰；被拒绝时标为需要用户处理（TDD §6.3）。
            for operation in operations where authorization == .denied {
                mark(operation, .requiresUserResolution, code: "notAuthorized")
            }
            result.waitingForPermission = operations.count
            try? context.save()
            return result
        }

        for operation in operations {
            do {
                try await execute(operation)
                result.synced += 1
            } catch HealthStoreError.notAuthorized {
                mark(operation, .requiresUserResolution, code: "notAuthorized")
                result.waitingForPermission += 1
            } catch {
                mark(operation, .failedRetryable, code: "healthKit.failed")
                result.failed += 1
            }
            try? context.save()
        }
        return result
    }

    /// 每条记录只保留最新一项操作；更早的已被它覆盖，直接移除。
    private func latestOperations() throws -> [HealthSyncOperation] {
        let all = try context.fetch(FetchDescriptor<HealthSyncOperation>(sortBy: [SortDescriptor(\.sequence)]))
        var latest: [UUID: HealthSyncOperation] = [:]
        for operation in all {
            if let previous = latest[operation.recordID] { context.delete(previous) }
            latest[operation.recordID] = operation
        }
        try context.save()
        return latest.values.sorted { $0.sequence < $1.sequence }
    }

    private func execute(_ operation: HealthSyncOperation) async throws {
        operation.attempts += 1
        let recordID = operation.recordID
        let mapped = try context.fetch(FetchDescriptor<HealthSyncMapping>(predicate: #Predicate { $0.recordID == recordID }))
        // 先删旧 Sample；成功后才清映射，失败时映射保留以便重试（TDD §6.3）。
        try await store.delete(mapped.map(\.sampleUUID))
        mapped.forEach(context.delete)
        try context.save()

        if operation.kind == .write {
            let samples = try operation.samples()
            let ids = try await store.save(samples)
            for (sample, id) in zip(samples, ids) {
                context.insert(HealthSyncMapping(recordID: recordID, nutrient: sample.nutrient, sampleUUID: id, now: now()))
            }
        }
        context.insert(AuditEvent(operation: "health.\(operation.kind.rawValue)", targetID: recordID.uuidString, result: .success, createdAt: now()))
        context.delete(operation)
        try context.save()
    }

    private func mark(_ operation: HealthSyncOperation, _ state: SyncState, code: String) {
        operation.state = state
        operation.lastErrorCode = code
        operation.updatedAt = now()
        context.insert(AuditEvent(operation: "health.\(operation.kind.rawValue)", targetID: operation.recordID.uuidString, result: .failure, errorCode: code, createdAt: now()))
    }

    // MARK: - 状态

    /// 记录在“健康”里的同步状态；没有任何需要同步的内容时为空。
    func state(for recordID: UUID) -> SyncState? {
        let pending = try? context.fetch(FetchDescriptor<HealthSyncOperation>(predicate: #Predicate { $0.recordID == recordID }))
        if let operation = pending?.max(by: { $0.sequence < $1.sequence }) { return operation.state }
        let mapped = (try? context.fetchCount(FetchDescriptor<HealthSyncMapping>(predicate: #Predicate { $0.recordID == recordID }))) ?? 0
        return mapped > 0 ? .synced : nil
    }

    var writeAuthorization: HealthWriteAuthorization {
        store.isAvailable ? store.writeAuthorization() : .denied
    }
}
