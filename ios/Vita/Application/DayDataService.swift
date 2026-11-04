import Foundation

/// Data 页显示的一天。
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
        /// 在 Apple 健康里的同步状态；没有需要同步的内容时为空。
        var healthSync: SyncState?

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

/// Data 页读的一天、一周：服务端算好的记录、汇总、能量目标与收支（`GET /v1/days/:date`）。
/// 健康里的同步状态是本机的，读的时候补上。
@MainActor
final class DayDataService {
    private let api: VitaAPIClient
    private let syncState: (UUID) -> SyncState?

    init(api: VitaAPIClient, syncState: @escaping (UUID) -> SyncState? = { _ in nil }) {
        self.api = api
        self.syncState = syncState
    }

    /// 读取某日数据；没有记录的日子是空日，revision 为 0。
    func day(_ date: LocalDate) async throws -> DayData {
        let response: DayResponseDTO = try await api.get("/v1/days/\(date.isoString)")
        return try response.domain(healthSync: syncState)
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
    func week(containing date: LocalDate) async throws -> WeekData {
        let monday = date.startOfWeek
        let api = self.api
        // 七天并发读，省掉六次往返。
        let responses = try await withThrowingTaskGroup(of: (Int, DayResponseDTO).self) { group in
            for offset in 0..<7 {
                group.addTask { (offset, try await api.get("/v1/days/\(monday.adding(days: offset).isoString)")) }
            }
            var collected: [(Int, DayResponseDTO)] = []
            for try await response in group { collected.append(response) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return WeekData(days: try responses.map { try $0.domain(healthSync: syncState) })
    }
}
