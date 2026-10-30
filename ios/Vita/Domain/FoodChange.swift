import Foundation

struct FoodProductDraft: Equatable, Codable, Sendable {
    var name: String
    var brandOrSupplier: String?
    /// 包装规格，如 250 ml，用于把“一盒、半瓶”换算为用量。
    var package: Quantity?
    var note: String?
}

/// 一个不可变 Food Version 的草稿。没有 AI 估算这一来源：估算值不能沉淀为个人食品（PRD §3.2.1）。
struct FoodVersionDraft: Equatable, Codable, Sendable {
    var basis: FoodVersionBasis
    var sourceKind: FoodVersionSource
    /// nutritionLabel 必填：已在本地识别过的标签图片引用。
    var labelImageReference: String?
    /// referenceDerived 必填：作为起点的公共参考库条目。
    var derivedFromReferenceID: String?
    var sourceNote: String?
}

/// 对个人 Nutrition DB 的变更，同样经 Pending 确认（agent-tools.md `proposeFoodChange`）。
enum FoodChange: Equatable, Codable, Sendable {
    case createProduct(FoodProductDraft, version: FoodVersionDraft)
    /// 标签、配方或包装变化：同一产品下新建版本并切换生效版本（TDD §4.3）。
    /// `expectedActiveVersionID` 用于发现提案之后产品已被别的变更更新。
    case addVersion(productID: UUID, expectedActiveVersionID: UUID?, version: FoodVersionDraft)

    var auditOperation: String {
        switch self {
        case .createProduct: "food.createProduct"
        case .addVersion: "food.addVersion"
        }
    }
}

/// Pending 可以承载的变更。
enum PendingChange: Equatable, Codable, Sendable {
    case record(RecordChange)
    case food(FoodChange)
}
