import Foundation

enum BiologicalSex: String, Codable, Sendable, CaseIterable {
    case female, male, other
}

/// 一个身体或活动数据从哪里来（agent-tools.md `getHealthSnapshot`：返回时标注来源）。
enum MetricSource: String, Codable, Sendable {
    case healthKit, manual
}

/// 读取结果必须区分“有数据 / 无数据 / 查询失败”，不能把授权当成数据存在（TDD §6.1）。
enum HealthReading<Value: Equatable & Codable & Sendable>: Equatable, Codable, Sendable {
    case value(Value, source: MetricSource, measuredAt: Date?)
    case noData
    case failed(String)

    var value: Value? {
        if case .value(let value, _, _) = self { value } else { nil }
    }

    var source: MetricSource? {
        if case .value(_, let source, _) = self { source } else { nil }
    }

    /// HealthKit 没有时用手动值补上；手动值只用于目标生成，不写回 HealthKit（PRD §3.4）。
    func fallback(to manual: Value?, at date: Date?) -> HealthReading<Value> {
        guard value == nil, let manual else { return self }
        return .value(manual, source: .manual, measuredAt: date)
    }
}

/// 生成目标与展示所需的健康数据。只保存在内存与目标的 evidence 里，不复制成长期业务主数据（TDD §6.1）。
struct HealthSnapshot: Equatable, Codable, Sendable {
    var bodyMassKg: HealthReading<Decimal>
    var heightCm: HealthReading<Decimal>
    /// 0–1。
    var bodyFatFraction: HealthReading<Decimal>
    var dateOfBirth: HealthReading<LocalDate>
    var sex: HealthReading<BiologicalSex>
    /// 当日活动能量（千卡）。
    var activeEnergyKcal: HealthReading<Decimal>
    /// 前一晚睡眠时长（小时）。
    var sleepHours: HealthReading<Decimal>
    /// 是否已向用户请求过 HealthKit 授权；未请求时各项都是 noData。
    var authorizationRequested: Bool
    /// 用户拒绝了写入。iOS 不告诉 App 读取是否被拒，写入被拒是唯一能确定的“没有授权”信号。
    var writeDenied: Bool = false

    /// 请求过授权但什么都读不到，且写入被拒：基本可以判定用户没有允许，应引导去设置而不是显示一排空数据。
    var accessLikelyDenied: Bool {
        authorizationRequested && writeDenied
            && bodyMassKg.source != .healthKit && heightCm.source != .healthKit && bodyFatFraction.value == nil
            && activeEnergyKcal.value == nil && sleepHours.value == nil
    }

    static let empty = HealthSnapshot(
        bodyMassKg: .noData, heightCm: .noData, bodyFatFraction: .noData, dateOfBirth: .noData,
        sex: .noData, activeEnergyKcal: .noData, sleepHours: .noData, authorizationRequested: false, writeDenied: false
    )

    /// 体重指数；需要体重与身高。
    var bmi: Decimal? {
        guard let weight = bodyMassKg.value, let height = heightCm.value, height > 0 else { return nil }
        let meters = height / 100
        return weight / (meters * meters)
    }
}

/// 用户在表单里补录的身体数据（`submitManualBodyMetrics`）。
struct ManualBodyMetrics: Equatable, Codable, Sendable {
    var bodyMassKg: Decimal?
    var heightCm: Decimal?
    var bodyFatFraction: Decimal?
    var dateOfBirth: LocalDate?
    var sex: BiologicalSex?
    var enteredAt: Date

    var isValid: Bool {
        if let weight = bodyMassKg, !(20...400).contains(weight) { return false }
        if let height = heightCm, !(80...250).contains(height) { return false }
        if let fat = bodyFatFraction, !(Decimal(string: "0.02")!...Decimal(string: "0.7")!).contains(fat) { return false }
        return true
    }
}
