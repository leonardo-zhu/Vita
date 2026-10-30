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
