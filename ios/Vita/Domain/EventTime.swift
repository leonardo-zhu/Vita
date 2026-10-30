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

    /// 需要具体时刻的场合（排序、HealthKit 写入）使用的时刻（TDD §6.4）：有 timestamp 用它，
    /// 餐段取代表性时间，仅日期取当日 12:00。只用于计算，不能当作用户陈述的事实展示。
    var representativeTimestamp: Date {
        if let timestamp { return timestamp }
        let (hour, minute): (Int, Int) = switch mealPeriod {
        case .breakfast: (8, 0)
        case .lunch: (12, 30)
        case .dinner: (18, 30)
        case .snack: (15, 30)
        case .other, nil: (12, 0)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        let components = DateComponents(
            year: localDate.year, month: localDate.month, day: localDate.day, hour: hour, minute: minute
        )
        return calendar.date(from: components)!
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
