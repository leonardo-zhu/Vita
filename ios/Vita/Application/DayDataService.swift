import Foundation
import SwiftData

/// Data 页与 Agent 读工具使用的只读视图，Presentation 不直接接触 SwiftData（TDD §1.1）。
struct DayData: Equatable, Sendable, Identifiable {
    struct Item: Equatable, Codable, Sendable, Identifiable {
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

    var id: LocalDate { date }
}

@MainActor
final class DayDataService {
    private let context: ModelContext
    private let referenceFoods: ReferenceFoodCatalog
    private let goals: GoalService
    private let sourceLabels: SourceLabeler

    init(context: ModelContext, referenceFoods: ReferenceFoodCatalog, goals: GoalService) {
        self.context = context
        self.referenceFoods = referenceFoods
        self.goals = goals
        self.sourceLabels = SourceLabeler(context: context, referenceFoods: referenceFoods)
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
            sourceLabel: try sourceLabels.label(referenceFoodID: item.referenceFoodID, foodVersionID: item.foodVersionID)
        )
    }
}

/// 一周（周一到周日）的数据，用于周视图的趋势。
struct WeekData: Equatable, Sendable {
    var days: [DayData]

    var start: LocalDate { days[0].date }
    var end: LocalDate { days[days.count - 1].date }

    /// 有记录的天数；平均值只按这些天算，没记录的日子不拉低平均。
    var recordedDays: [DayData] { days.filter { !$0.records.isEmpty } }

    func average(_ nutrient: Nutrient) -> Decimal? {
        let recorded = recordedDays
        guard !recorded.isEmpty else { return nil }
        let total = recorded.reduce(Decimal(0)) { $0 + nutrient.value(in: $1.summary.totals) }
        return total / Decimal(recorded.count)
    }
}

extension DayDataService {
    func week(containing date: LocalDate) throws -> WeekData {
        let monday = date.startOfWeek
        return WeekData(days: try (0..<7).map { try day(monday.adding(days: $0)) })
    }
}
