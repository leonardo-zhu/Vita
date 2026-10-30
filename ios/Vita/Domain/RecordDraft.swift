import Foundation

/// 一个 Item 的营养从哪里来（agent-tools.md `proposeRecordChange`）。
/// 命中数据源时只给引用，数值由客户端计算；只有 AI 估算才携带数值与估算依据。
enum NutritionInput: Equatable, Codable, Sendable {
    case personalFoodVersion(UUID)
    case referenceFood(String)
    case aiEstimated(NutrientValues, estimateBasis: String)
}

struct ItemDraft: Equatable, Codable, Sendable {
    var displayName: String
    var groupName: String?
    /// 用户原话里的用量，如“2 个鸡蛋，共 108g”，原样保留。
    var originalAmountText: String
    /// 标准化用量；为空时必须是 AI 估算（TDD §3.3）。
    var quantity: Quantity?
    var amountSource: AmountSource
    var nutrition: NutritionInput
    var includeInSummary: Bool
}

struct RecordDraft: Equatable, Codable, Sendable {
    var eventTime: EventTime
    var mealLabel: String?
    var note: String?
    var items: [ItemDraft]
}
