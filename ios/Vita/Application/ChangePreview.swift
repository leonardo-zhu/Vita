import Foundation

/// 确认卡展示的内容：创建 Pending 时由服务端计算并随之保存。确认时只执行已保存的变更，
/// 不采用预览或模型随后的描述（TDD §5.1）。
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
    /// 追加时顺带改了分组的已有 Item（groupName 是改后的）。不是新吃的，不计入合计。
    /// 可选：2026-11-11 之前的服务端和本地缓存里没有这一项。
    var regroupedItems: [DayData.Item]? = nil

    var totals: NutrientValues {
        items.filter(\.includeInSummary).reduce(.zero) { $0 + $1.snapshot.values }
    }
}
