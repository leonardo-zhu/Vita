import Foundation

/// 一次对 Record 的正式变更。Pending 保存的就是它，确认时原样执行（TDD §5.1）。
enum RecordChange: Equatable, Codable, Sendable {
    case create(RecordDraft)
    case appendItems(recordID: UUID, items: [ItemDraft])
    case replaceItem(recordID: UUID, itemID: UUID, item: ItemDraft)
    case removeItem(recordID: UUID, itemID: UUID)
    case deleteRecord(recordID: UUID)

    var targetRecordID: UUID? {
        switch self {
        case .create: nil
        case .appendItems(let id, _), .replaceItem(let id, _, _), .removeItem(let id, _), .deleteRecord(let id): id
        }
    }

    var auditOperation: String {
        switch self {
        case .create: "record.create"
        case .appendItems: "record.appendItems"
        case .replaceItem: "record.replaceItem"
        case .removeItem: "record.removeItem"
        case .deleteRecord: "record.delete"
        }
    }
}
