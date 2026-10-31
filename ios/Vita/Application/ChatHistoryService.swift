import Foundation
import SwiftData

/// 界面与上下文组装用的消息快照。
struct ChatEntry: Equatable, Sendable, Identifiable {
    var id: UUID
    var role: ChatRole
    var text: String
    var cardRef: ChatCardRef?
    var createdAt: Date
}

/// 按日期保存对话（PRD §3.1：一个 Session 对应一天）。只存文字与卡片引用，不存工具 payload、令牌或图片（TDD §3.4）。
@MainActor
final class ChatHistoryService {
    private let context: ModelContext
    private let now: () -> Date
    private let timeZone: () -> TimeZone

    init(context: ModelContext, now: @escaping () -> Date, timeZone: @escaping () -> TimeZone) {
        self.context = context
        self.now = now
        self.timeZone = timeZone
    }

    func messages(on date: LocalDate) throws -> [ChatEntry] {
        guard let session = try context.session(on: date) else { return [] }
        return session.messages
            .sorted { $0.createdAt < $1.createdAt }
            .map { ChatEntry(id: $0.id, role: $0.role, text: $0.text, cardRef: $0.cardRef, createdAt: $0.createdAt) }
    }

    @discardableResult
    func append(_ role: ChatRole, text: String, cardRef: ChatCardRef? = nil, on date: LocalDate) throws -> ChatEntry {
        var timestamp = now()
        let session = try context.session(on: date) ?? {
            // 只是开始聊天，不改变当天 revision。
            let created = DaySession(localDate: date, timeZoneIdentifier: timeZone().identifier, now: timestamp)
            context.insert(created)
            return created
        }()
        // 消息按时间排序；同一时刻连写两条时往后挪 1 毫秒，保证顺序稳定。
        if let last = session.messages.map(\.createdAt).max(), timestamp <= last {
            timestamp = last.addingTimeInterval(0.001)
        }
        let message = ChatMessage(role: role, text: text, cardRef: cardRef, createdAt: timestamp)
        context.insert(message)
        message.session = session
        try context.save()
        return ChatEntry(id: message.id, role: role, text: text, cardRef: cardRef, createdAt: timestamp)
    }
}
