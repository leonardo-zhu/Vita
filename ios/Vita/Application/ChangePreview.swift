import Foundation
import SwiftData

/// 确认卡展示的内容：在创建 Pending 时由客户端计算并随之保存。确认时只执行已保存的
/// `RecordChange`，不采用预览或模型随后的描述（TDD §5.1）。
struct ChangePreview: Equatable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case create, appendItems, replaceItem, removeItem, deleteRecord
    }

    var kind: Kind
    /// 目标 Record 的餐次名（新建时为草稿中的）。
    var recordLabel: String?
    var eventTime: EventTime
    /// 新增或替换后的 Item。
    var items: [DayData.Item]
    /// 被替换、移除或随删除消失的 Item 名称。
    var removedItemNames: [String]

    var totals: NutrientValues {
        items.filter(\.includeInSummary).reduce(.zero) { $0 + $1.snapshot.values }
    }
}

/// Item 营养来源的可读说明，Data 页与确认卡共用（reference-food-library.md §6）。
@MainActor
struct SourceLabeler {
    let context: ModelContext
    let referenceFoods: ReferenceFoodCatalog

    func label(referenceFoodID: String?, foodVersionID: UUID?) throws -> String? {
        if let referenceFoodID {
            // 参考库后来移除了该条目时，仍可凭快照解释数值，只是没有名称。
            guard let food = referenceFoods.food(id: referenceFoodID) else { return referenceFoodID }
            return "\(food.canonicalName) · \(food.source.provider)"
        }
        if let foodVersionID, let version = try context.foodVersion(id: foodVersionID) {
            return version.product.map { [$0.name, $0.brandOrSupplier].compactMap { $0 }.joined(separator: " · ") }
        }
        return nil
    }
}
