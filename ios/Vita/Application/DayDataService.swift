import Foundation
import SwiftData

/// Data 页与 Agent 读工具使用的只读视图，Presentation 不直接接触 SwiftData（TDD §1.1）。
struct DayData: Equatable, Sendable {
    struct Item: Equatable, Sendable, Identifiable {
        var id: UUID
        var displayName: String
        var groupName: String?
        var originalAmountText: String
        var quantity: Quantity?
        var amountSource: AmountSource
        var includeInSummary: Bool
        var snapshot: NutritionSnapshot
        /// 来源的可读说明：参考库条目名与数据源、个人食品名；AI 估算为空。
        var sourceLabel: String?
    }

    struct Record: Equatable, Sendable, Identifiable {
        var id: UUID
        var eventTime: EventTime
        var mealLabel: String?
        var note: String?
        var revision: Int
        var items: [Item]

        var totals: NutrientValues {
            items.filter(\.includeInSummary).reduce(.zero) { $0 + $1.snapshot.values }
        }
    }

    var date: LocalDate
    /// Session 不存在时为 0，与 `RecordService` 创建首条记录时的期望值一致。
    var revision: Int
    var records: [Record]
    var summary: DaySummary
}

@MainActor
final class DayDataService {
    private let context: ModelContext
    private let referenceFoods: ReferenceFoodCatalog
    private let goals: GoalService

    init(context: ModelContext, referenceFoods: ReferenceFoodCatalog, goals: GoalService) {
        self.context = context
        self.referenceFoods = referenceFoods
        self.goals = goals
    }

    /// 读取某日数据；没有 Session 时返回空日，不因读取而创建 Session。
    func day(_ date: LocalDate) throws -> DayData {
        let session = try context.session(on: date)
        let records = try (session?.records ?? [])
            .sorted { ($0.sortTime, $0.createdAt) < ($1.sortTime, $1.createdAt) }
            .map(makeRecord)
        let items = records.flatMap(\.items).map { (snapshot: $0.snapshot, includeInSummary: $0.includeInSummary) }
        return DayData(
            date: date,
            revision: session?.revision ?? 0,
            records: records,
            summary: DaySummary(items: items, goal: try goals.activeGoal(on: date))
        )
    }

    private func makeRecord(_ record: ConsumptionRecord) throws -> DayData.Record {
        DayData.Record(
            id: record.id,
            eventTime: try record.eventTime(),
            mealLabel: record.mealLabel,
            note: record.note,
            revision: record.revision,
            items: try record.orderedItems.map(makeItem)
        )
    }

    private func makeItem(_ item: ConsumptionItem) throws -> DayData.Item {
        DayData.Item(
            id: item.id,
            displayName: item.displayName,
            groupName: item.groupName,
            originalAmountText: item.originalAmountText,
            quantity: try item.quantity(),
            amountSource: item.amountSource,
            includeInSummary: item.includeInSummary,
            snapshot: try item.snapshot(),
            sourceLabel: try sourceLabel(for: item)
        )
    }

    private func sourceLabel(for item: ConsumptionItem) throws -> String? {
        if let referenceID = item.referenceFoodID {
            // 参考库后来移除了该条目时，仍可凭快照解释数值，只是没有名称。
            guard let food = referenceFoods.food(id: referenceID) else { return referenceID }
            return "\(food.canonicalName) · \(food.source.provider)"
        }
        if let versionID = item.foodVersionID, let version = try context.foodVersion(id: versionID) {
            return version.product.map { [$0.name, $0.brandOrSupplier].compactMap { $0 }.joined(separator: " · ") }
        }
        return nil
    }
}
