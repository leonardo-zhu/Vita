import Foundation

enum PendingStatus: String, Codable, Sendable {
    case readyForConfirmation, confirmed, cancelled, expired
}

/// Pending 的过期规则（agent-tools.md、TDD §5.3）：
/// `min(createdAt + 30 分钟, createdAt 所在本地自然日的次日 00:00)`。截止点取决于创建 Pending 的
/// 真实时间而非 Session 日期，否则向历史日期写入会创建即过期。
enum PendingPolicy {
    static let lifetime: TimeInterval = 30 * 60

    static func expiresAt(createdAt: Date, timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startOfDay = calendar.startOfDay(for: createdAt)
        let nextMidnight = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        return min(createdAt.addingTimeInterval(lifetime), nextMidnight)
    }
}
