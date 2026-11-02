import Foundation
import SwiftData

/// 日期上下文（TDD §3.1）。日期与时区在创建时固定，之后切换时区不重写。
@Model
final class DaySession {
    @Attribute(.unique) var id: UUID
    /// `LocalDate.isoString`，每个日期唯一。
    @Attribute(.unique) var localDateKey: String
    var timeZoneIdentifier: String
    /// 该日数据的快照版本，每次正式写入递增；提案带上它，确认时不一致即拒绝（TDD §5.2）。
    var revision: Int
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ConsumptionRecord.session)
    var records: [ConsumptionRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.session)
    var messages: [ChatMessage] = []

    var localDate: LocalDate {
        // 只由 `init` 写入合法值。
        LocalDate(isoString: localDateKey)!
    }

    init(id: UUID = UUID(), localDate: LocalDate, timeZoneIdentifier: String, now: Date) {
        self.id = id
        self.localDateKey = localDate.isoString
        self.timeZoneIdentifier = timeZoneIdentifier
        self.revision = 0
        self.createdAt = now
        self.updatedAt = now
    }
}

enum ChatRole: String, Codable, Sendable {
    case user, assistant, toolSummary
}

/// 消息附带的卡片：指向 Pending 或已确认 Record 的结果卡（TDD §3.4），或用户发的营养标签照片（指向附件记录）。
enum ChatCardRef: Equatable, Sendable {
    case pending(UUID)
    case record(UUID)
    case label(UUID)

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { return nil }
        switch parts[0] {
        case "pending": self = .pending(id)
        case "record": self = .record(id)
        case "label": self = .label(id)
        default: return nil
        }
    }

    var rawValue: String {
        switch self {
        case .pending(let id): "pending:\(id.uuidString)"
        case .record(let id): "record:\(id.uuidString)"
        case .label(let id): "label:\(id.uuidString)"
        }
    }
}

/// 属于 DaySession 的对话消息。不保存密钥、图片原文或完整工具 payload（TDD §3.4）。
@Model
final class ChatMessage {
    @Attribute(.unique) var id: UUID
    var session: DaySession?
    var roleRaw: String
    var text: String
    var cardRefRaw: String?
    var createdAt: Date

    var role: ChatRole {
        ChatRole(rawValue: roleRaw) ?? .assistant
    }

    var cardRef: ChatCardRef? {
        cardRefRaw.flatMap(ChatCardRef.init(rawValue:))
    }

    init(id: UUID = UUID(), role: ChatRole, text: String, cardRef: ChatCardRef? = nil, createdAt: Date) {
        self.id = id
        self.roleRaw = role.rawValue
        self.text = text
        self.cardRefRaw = cardRef?.rawValue
        self.createdAt = createdAt
    }
}
