import Foundation
import SwiftData

/// HealthKit outbox 中的一项（ADR-009、TDD §3.4）。在 Record 的同一个本地事务里写入，提交后异步执行。
@Model
final class HealthSyncOperation {
    enum Kind: String { case write, delete }

    @Attribute(.unique) var id: UUID
    var recordID: UUID
    var kindRaw: String
    /// 全局递增，同一 Record 的操作按它串行。
    var sequence: Int
    /// write：提交当时这条记录应当在“健康”里的全部 Sample。
    var samplesData: Data?
    var stateRaw: String
    var attempts: Int
    var lastErrorCode: String?
    var createdAt: Date
    var updatedAt: Date

    init(recordID: UUID, kind: Kind, sequence: Int, samples: [DietarySample]?, now: Date) {
        self.id = UUID()
        self.recordID = recordID
        self.kindRaw = kind.rawValue
        self.sequence = sequence
        self.samplesData = samples.map(JSONColumn.encode)
        self.stateRaw = SyncState.pending.rawValue
        self.attempts = 0
        self.createdAt = now
        self.updatedAt = now
    }

    var kind: Kind { Kind(rawValue: kindRaw) ?? .write }

    var state: SyncState {
        get { SyncState(rawValue: stateRaw) ?? .pending }
        set { stateRaw = newValue.rawValue }
    }

    func samples() throws -> [DietarySample] {
        try samplesData.map { try JSONColumn.decode([DietarySample].self, from: $0) } ?? []
    }
}

/// Record 与已写入“健康”的 Sample 的对应（TDD §3.4）。删除成功后才移除，权限撤销时保留。
@Model
final class HealthSyncMapping {
    @Attribute(.unique) var id: UUID
    var recordID: UUID
    var nutrientRaw: String
    var sampleUUID: UUID
    var createdAt: Date

    init(recordID: UUID, nutrient: Nutrient, sampleUUID: UUID, now: Date) {
        self.id = UUID()
        self.recordID = recordID
        self.nutrientRaw = nutrient.rawValue
        self.sampleUUID = sampleUUID
        self.createdAt = now
    }
}

/// 用户补录的身体数据，只用于目标生成，不写回 HealthKit（PRD §3.4）。只保留最新一份。
@Model
final class ManualBodyMetricsEntry {
    @Attribute(.unique) var id: UUID
    var metricsData: Data
    var updatedAt: Date

    init(metrics: ManualBodyMetrics) {
        self.id = UUID()
        self.metricsData = JSONColumn.encode(metrics)
        self.updatedAt = metrics.enteredAt
    }

    func metrics() throws -> ManualBodyMetrics {
        try JSONColumn.decode(ManualBodyMetrics.self, from: metricsData)
    }
}
