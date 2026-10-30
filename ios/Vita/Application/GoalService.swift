import Foundation
import SwiftData

enum GoalServiceError: Error, Equatable {
    case invalidTargets
}

/// 每日目标。更新不覆盖旧行，而是追加一行更高 revision 的记录（TDD §3.2）；
/// `updateGoal` / `commitInitialGoals` 的指令解析与确认在 Phase 4 接入。
@MainActor
final class GoalService {
    private let context: ModelContext
    private let now: () -> Date

    init(context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.now = now
    }

    /// 首次（或用户主动要求重新）生成目标：用户在预览卡上确认后由客户端调用，不走 Pending（agent-tools.md）。
    /// 建议的输入、公式与结果作为 evidence 一并保存，解释目标从何而来。
    @discardableResult
    func commitInitialGoals(_ recommendation: GoalRecommendation, effectiveFrom: LocalDate) throws -> GoalSnapshot {
        try appendGoal(
            recommendation.targets, origin: .initialRecommendation, effectiveFrom: effectiveFrom,
            evidenceData: JSONColumn.encode(recommendation)
        ).current
    }

    /// 用户明确指令修改目标（`updateGoal`）：只改给出的项，其余沿用当前目标；返回旧值与新值供复述。
    @discardableResult
    func updateGoal(_ changes: GoalTargets, effectiveFrom: LocalDate, requestID: UUID? = nil) throws -> (previous: GoalSnapshot?, current: GoalSnapshot) {
        let current = try activeGoal(on: effectiveFrom)?.targets ?? GoalTargets()
        let merged = GoalTargets(
            energyKcal: changes.energyKcal ?? current.energyKcal,
            proteinG: changes.proteinG ?? current.proteinG,
            fatG: changes.fatG ?? current.fatG,
            carbohydrateG: changes.carbohydrateG ?? current.carbohydrateG
        )
        guard Nutrient.allCases.allSatisfy({ changes.target(for: $0).map { $0 > 0 } ?? true }) else {
            throw GoalServiceError.invalidTargets
        }
        return try appendGoal(merged, origin: .explicitUserCommand, effectiveFrom: effectiveFrom, requestID: requestID)
    }

    /// 某日生效的目标：`effectiveFrom` 不晚于该日的行中，日期最晚、revision 最高的一行。
    func activeGoal(on date: LocalDate) throws -> GoalSnapshot? {
        // 目标行很少，取全部在内存中比较，避免依赖字符串比较谓词。
        try context.fetch(FetchDescriptor<DailyGoal>())
            .map { try $0.snapshot() }
            .filter { $0.effectiveFrom <= date }
            .max { ($0.effectiveFrom, $0.revision) < ($1.effectiveFrom, $1.revision) }
    }

    /// 追加一条目标，返回该日期原先生效的目标与新目标，供复述旧值与新值（agent-tools.md `updateGoal`）。
    @discardableResult
    func appendGoal(
        _ targets: GoalTargets,
        origin: GoalOrigin,
        effectiveFrom: LocalDate,
        evidenceData: Data? = nil,
        requestID: UUID? = nil
    ) throws -> (previous: GoalSnapshot?, current: GoalSnapshot) {
        guard targets.isValid else {
            context.insert(AuditEvent(operation: "goal.append", result: .failure, errorCode: "goal.invalidTargets", requestID: requestID, createdAt: now()))
            try? context.save()
            throw GoalServiceError.invalidTargets
        }
        let previous = try activeGoal(on: effectiveFrom)
        let nextRevision = (try context.fetch(FetchDescriptor<DailyGoal>()).map(\.revision).max() ?? 0) + 1
        let goal = DailyGoal(
            effectiveFrom: effectiveFrom, targets: targets, origin: origin,
            evidenceData: evidenceData, revision: nextRevision, now: now()
        )
        context.insert(goal)
        context.insert(AuditEvent(operation: "goal.append", targetID: goal.id.uuidString, result: .success, requestID: requestID, createdAt: now()))
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return (previous, try goal.snapshot())
    }
}
