import Foundation

/// 展示规则（TDD §4.2）：能量取整数 kcal，宏量营养素一位小数；存储值不受影响。
enum DisplayFormat {
    /// 界面只有中文，日期与时刻按中文格式展示，不跟随系统语言。
    static let locale = Locale(identifier: "zh_Hans_CN")

    static func energy(_ value: Decimal) -> String {
        value.formatted(.number.precision(.fractionLength(0)).rounded(rule: .toNearestOrAwayFromZero)) + " kcal"
    }

    static func grams(_ value: Decimal) -> String {
        value.formatted(.number.precision(.fractionLength(1)).rounded(rule: .toNearestOrAwayFromZero)) + " g"
    }

    static func nutrient(_ nutrient: Nutrient, _ value: Decimal) -> String {
        nutrient == .energyKcal ? energy(value) : grams(value)
    }

    static func quantity(_ quantity: Quantity) -> String {
        quantity.amount.formatted(.number.precision(.fractionLength(0...1)).rounded(rule: .toNearestOrAwayFromZero))
            + " " + quantity.unit.rawValue
    }

    static func percent(_ fraction: Decimal) -> String {
        (fraction * 100).formatted(.number.precision(.fractionLength(0)).rounded(rule: .toNearestOrAwayFromZero)) + "%"
    }

    static func date(_ date: LocalDate) -> String {
        guard let day = Calendar(identifier: .gregorian).date(from: DateComponents(year: date.year, month: date.month, day: date.day)) else {
            return date.isoString
        }
        return day.formatted(.dateTime.month().day().weekday(.abbreviated).locale(locale))
    }

    /// 如“10月26日”。
    static func shortDate(_ date: LocalDate) -> String {
        "\(date.month)月\(date.day)日"
    }

    /// 按原始精度展示，不把餐段或“仅日期”显示成具体时刻（ADR-011）。
    static func eventTime(_ time: EventTime) -> String {
        func clock(_ date: Date) -> String {
            var style = Date.FormatStyle(date: .omitted, time: .shortened)
            style.timeZone = TimeZone(identifier: time.timeZoneIdentifier) ?? .current
            style.locale = locale
            return date.formatted(style)
        }
        switch time.precision {
        case .exact: return time.timestamp.map(clock) ?? ""
        case .approximate: return time.timestamp.map { "约 " + clock($0) } ?? ""
        case .defaultedEntryTime: return time.timestamp.map { clock($0) + "（按记录时间）" } ?? ""
        case .mealPeriod: return time.mealPeriod?.label ?? ""
        case .dateOnly: return "时间未说明"
        }
    }
}

extension Nutrient {
    var label: String {
        switch self {
        case .energyKcal: "能量"
        case .proteinG: "蛋白质"
        case .fatG: "脂肪"
        case .carbohydrateG: "碳水"
        }
    }
}

extension MealPeriod {
    var label: String {
        switch self {
        case .breakfast: "早餐"
        case .lunch: "午餐"
        case .dinner: "晚餐"
        case .snack: "加餐"
        case .other: "其他"
        }
    }
}

extension AmountSource {
    var label: String {
        switch self {
        case .userMeasured: "实测"
        case .userStated: "用户告知"
        case .packageConversion: "按包装换算"
        case .aiEstimated: "AI 估算"
        }
    }
}

extension FoodVersionSource {
    var label: String {
        switch self {
        case .nutritionLabel: "来自营养标签"
        case .manualEntry: "用户手动提供"
        case .referenceDerived: "以公共参考库为起点"
        }
    }

    var symbol: String {
        switch self {
        case .nutritionLabel: "doc.text.viewfinder"
        case .manualEntry: "hand.raised"
        case .referenceDerived: "books.vertical"
        }
    }
}

extension NutritionSource {
    var label: String {
        switch self {
        case .personalFoodVersion: "个人食品库"
        case .referenceFood: "公共参考库"
        case .aiEstimated: "AI 估算"
        }
    }
}
