import Foundation
import SwiftData

/// 每次目标变化新增一行，旧行保留（TDD §3.2）。某日生效的是 `effectiveFrom` 不晚于该日、
/// 其中最新的一行。
@Model
final class DailyGoal {
    @Attribute(.unique) var id: UUID
    var effectiveFromKey: String
    var targetsData: Data
    var originRaw: String
    /// 目标生成依据（HealthKit 读数、公式、是否估算），格式随 Phase 4 定义。
    var evidenceData: Data?
    var revision: Int
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), effectiveFrom: LocalDate, targets: GoalTargets, origin: GoalOrigin, evidenceData: Data?, revision: Int, now: Date) {
        self.id = id
        self.effectiveFromKey = effectiveFrom.isoString
        self.targetsData = JSONColumn.encode(targets)
        self.originRaw = origin.rawValue
        self.evidenceData = evidenceData
        self.revision = revision
        self.createdAt = now
        self.updatedAt = now
    }

    func snapshot() throws -> GoalSnapshot {
        GoalSnapshot(
            id: id,
            effectiveFrom: LocalDate(isoString: effectiveFromKey)!,
            targets: try JSONColumn.decode(GoalTargets.self, from: targetsData),
            origin: GoalOrigin(rawValue: originRaw) ?? .explicitUserCommand,
            revision: revision
        )
    }
}
