import Foundation
import SwiftData

/// 每次目标变化新增一行，旧行保留（TDD §3.2）。某日生效的是 `effectiveFrom` 不晚于该日、
/// 其中最新的一行。
@Model
final class DailyGoal {
    @Attribute(.unique) var id: UUID
    var effectiveFromKey: String
    /// 目标值，加上可选的 `energyPlan`（同一个 JSON 对象，旧数据没有这个键）。
    var targetsData: Data
    var originRaw: String
    /// 目标生成依据（HealthKit 读数、公式、是否估算），格式随 Phase 4 定义。
    var evidenceData: Data?
    var revision: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(), effectiveFrom: LocalDate, targets: GoalTargets, energyPlan: EnergyPlan? = nil,
        origin: GoalOrigin, evidenceData: Data?, revision: Int, now: Date
    ) {
        self.id = id
        self.effectiveFromKey = effectiveFrom.isoString
        self.targetsData = JSONColumn.encode(StoredTargets(targets: targets, energyPlan: energyPlan))
        self.originRaw = origin.rawValue
        self.evidenceData = evidenceData
        self.revision = revision
        self.createdAt = now
        self.updatedAt = now
    }

    func snapshot() throws -> GoalSnapshot {
        let stored = try JSONColumn.decode(StoredTargets.self, from: targetsData)
        return GoalSnapshot(
            id: id,
            effectiveFrom: LocalDate(isoString: effectiveFromKey)!,
            targets: stored.targets,
            origin: GoalOrigin(rawValue: originRaw) ?? .explicitUserCommand,
            revision: revision,
            energyPlan: stored.energyPlan
        )
    }
}

/// 目标列的形状：营养素目标平铺，`energyPlan` 是可选的同级键，所以早先只存了 `GoalTargets` 的行照样能读。
private struct StoredTargets: Codable {
    var targets: GoalTargets
    var energyPlan: EnergyPlan?

    init(targets: GoalTargets, energyPlan: EnergyPlan?) {
        self.targets = targets
        self.energyPlan = energyPlan
    }

    enum CodingKeys: String, CodingKey {
        case energyPlan
    }

    init(from decoder: Decoder) throws {
        targets = try GoalTargets(from: decoder)
        energyPlan = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(EnergyPlan.self, forKey: .energyPlan)
    }

    func encode(to encoder: Encoder) throws {
        try targets.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(energyPlan, forKey: .energyPlan)
    }
}
