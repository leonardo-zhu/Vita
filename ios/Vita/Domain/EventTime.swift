import Foundation

enum TimePrecision: String, Codable, Sendable, CaseIterable {
    case exact, approximate, mealPeriod, dateOnly, defaultedEntryTime
}

enum MealPeriod: String, Codable, Sendable, CaseIterable {
    case breakfast, lunch, dinner, snack, other
}

enum EventTimeError: Error, Equatable {
    case missingTimestamp(TimePrecision)
    case unexpectedTimestamp(TimePrecision)
    case missingMealPeriod
    case unexpectedMealPeriod(TimePrecision)
    case unknownTimeZone(String)
    case timestampOutsideLocalDate
}

/// 摄入发生的用户本地语义（TDD §3.1）。不会把“中午”伪装成 12:00：
/// 精度决定哪些字段存在，初始化时校验不变量。
struct EventTime: Equatable, Codable, Sendable {
    let localDate: LocalDate
    let precision: TimePrecision
    let timestamp: Date?
    let mealPeriod: MealPeriod?
    let timeZoneIdentifier: String

    init(
        localDate: LocalDate,
        precision: TimePrecision,
        timestamp: Date? = nil,
        mealPeriod: MealPeriod? = nil,
        timeZoneIdentifier: String
    ) throws {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw EventTimeError.unknownTimeZone(timeZoneIdentifier)
        }
        switch precision {
        case .exact, .approximate, .defaultedEntryTime:
            guard let timestamp else { throw EventTimeError.missingTimestamp(precision) }
            guard LocalDate(date: timestamp, timeZone: timeZone) == localDate else {
                throw EventTimeError.timestampOutsideLocalDate
            }
            guard mealPeriod == nil else { throw EventTimeError.unexpectedMealPeriod(precision) }
        case .mealPeriod:
            guard timestamp == nil else { throw EventTimeError.unexpectedTimestamp(precision) }
            guard mealPeriod != nil else { throw EventTimeError.missingMealPeriod }
        case .dateOnly:
            guard timestamp == nil else { throw EventTimeError.unexpectedTimestamp(precision) }
            guard mealPeriod == nil else { throw EventTimeError.unexpectedMealPeriod(precision) }
        }
        self.localDate = localDate
        self.precision = precision
        self.timestamp = timestamp
        self.mealPeriod = mealPeriod
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    /// 用户完全未表达时间时的默认值（ADR-011）：Session 日期 + 当前本地时分秒，
    /// 保证 Record 不跨出所在 Session；历史日期 Session 同样适用。
    static func defaultedEntryTime(
        sessionDate: LocalDate,
        now: Date,
        timeZone: TimeZone
    ) throws -> EventTime {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let time = calendar.dateComponents([.hour, .minute, .second], from: now)
        var components = DateComponents()
        components.year = sessionDate.year
        components.month = sessionDate.month
        components.day = sessionDate.day
        components.hour = time.hour
        components.minute = time.minute
        components.second = time.second
        guard let composed = calendar.date(from: components) else {
            throw EventTimeError.timestampOutsideLocalDate
        }
        return try EventTime(
            localDate: sessionDate,
            precision: .defaultedEntryTime,
            timestamp: composed,
            timeZoneIdentifier: timeZone.identifier
        )
    }
}
