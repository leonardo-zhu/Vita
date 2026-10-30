import Foundation
import SwiftData

@Model
final class ConsumptionRecord {
    @Attribute(.unique) var id: UUID
    var session: DaySession?
    var eventTimeData: Data
    /// 排序用，取 `EventTime.representativeTimestamp`；不作为业务事实展示。
    var sortTime: Date
    var mealLabel: String?
    var note: String?
    var revision: Int
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ConsumptionItem.record)
    var items: [ConsumptionItem] = []

    init(id: UUID = UUID(), eventTime: EventTime, mealLabel: String?, note: String?, now: Date) {
        self.id = id
        self.eventTimeData = JSONColumn.encode(eventTime)
        self.sortTime = eventTime.representativeTimestamp
        self.mealLabel = mealLabel
        self.note = note
        self.revision = 0
        self.createdAt = now
        self.updatedAt = now
    }

    func eventTime() throws -> EventTime {
        try JSONColumn.decode(EventTime.self, from: eventTimeData)
    }

    var orderedItems: [ConsumptionItem] {
        items.sorted { $0.position < $1.position }
    }
}

/// 一项摄入。营养快照在创建/修改时写定，此后不随 Food Version 或参考库变化（TDD §3.2）。
@Model
final class ConsumptionItem {
    @Attribute(.unique) var id: UUID
    var record: ConsumptionRecord?
    var position: Int
    var groupName: String?
    var displayName: String
    var originalAmountText: String
    var quantityData: Data?
    var amountSourceRaw: String
    var snapshotData: Data
    var includeInSummary: Bool
    var foodProductID: UUID?
    var foodVersionID: UUID?
    var referenceFoodID: String?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), position: Int, now: Date) {
        self.id = id
        self.position = position
        self.displayName = ""
        self.originalAmountText = ""
        self.amountSourceRaw = AmountSource.aiEstimated.rawValue
        self.snapshotData = Data()
        self.includeInSummary = true
        self.createdAt = now
        self.updatedAt = now
    }

    var amountSource: AmountSource {
        AmountSource(rawValue: amountSourceRaw) ?? .aiEstimated
    }

    func quantity() throws -> Quantity? {
        try quantityData.map { try JSONColumn.decode(Quantity.self, from: $0) }
    }

    func snapshot() throws -> NutritionSnapshot {
        try JSONColumn.decode(NutritionSnapshot.self, from: snapshotData)
    }

    /// 用已校验的草稿与客户端算好的快照整体写入，修改与新建走同一条路径。
    func apply(_ draft: ItemDraft, snapshot: NutritionSnapshot, foodProductID: UUID?, now: Date) {
        groupName = draft.groupName
        displayName = draft.displayName
        originalAmountText = draft.originalAmountText
        quantityData = draft.quantity.map(JSONColumn.encode)
        amountSourceRaw = draft.amountSource.rawValue
        snapshotData = JSONColumn.encode(snapshot)
        includeInSummary = draft.includeInSummary
        switch draft.nutrition {
        case .personalFoodVersion(let versionID):
            self.foodProductID = foodProductID
            foodVersionID = versionID
            referenceFoodID = nil
        case .referenceFood(let referenceID):
            self.foodProductID = nil
            foodVersionID = nil
            referenceFoodID = referenceID
        case .aiEstimated:
            self.foodProductID = nil
            foodVersionID = nil
            referenceFoodID = nil
        }
        updatedAt = now
    }
}
