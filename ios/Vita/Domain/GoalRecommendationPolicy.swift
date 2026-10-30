import Foundation

/// 目标建议的输入与结果，同时作为目标的 evidence snapshot 保存（TDD §6.2）。
struct GoalRecommendation: Equatable, Codable, Sendable {
    struct Input: Equatable, Codable, Sendable {
        var bodyMassKg: Decimal
        var weightSource: MetricSource
        var heightCm: Decimal
        var heightSource: MetricSource
        var ageYears: Int
        var ageSource: MetricSource
        var sex: BiologicalSex
        var sexSource: MetricSource
        /// 当日活动能量；没有时按轻度活动系数估算。
        var activeEnergyKcal: Decimal?
    }

    var input: Input
    var bmrKcal: Decimal
    var tdeeKcal: Decimal
    /// TDEE 是否按 BMR × 1.375 估算（缺少活动能量）。
    var tdeeEstimated: Bool
    var targets: GoalTargets
    var generatedAt: Date
    var policyVersion: Int
}

enum GoalRecommendationResult: Equatable, Sendable {
    case ready(GoalRecommendation)
    /// 缺少的项目；体重是硬门槛（PRD §3.4）。
    case missing([MissingMetric])
}

enum MissingMetric: String, Codable, Sendable {
    case bodyMass, height, dateOfBirth, sex
}

/// 默认目标建议（TDD §6.2）。所有系数集中在这里，不散落在 prompt 中；这是可调的默认建议，不是医疗建议。
enum GoalRecommendationPolicy {
    static let version = 1
    static let lightActivityFactor = Decimal(string: "1.375")!
    static let proteinGramsPerKg = Decimal(string: "1.8")!
    static let energyFraction = Decimal(string: "0.9")!

    static func recommend(snapshot: HealthSnapshot, on date: LocalDate, now: Date) -> GoalRecommendationResult {
        var missing: [MissingMetric] = []
        if snapshot.bodyMassKg.value == nil { missing.append(.bodyMass) }
        if snapshot.heightCm.value == nil { missing.append(.height) }
        if snapshot.dateOfBirth.value == nil { missing.append(.dateOfBirth) }
        if snapshot.sex.value == nil { missing.append(.sex) }
        guard missing.isEmpty,
              let weight = snapshot.bodyMassKg.value, let weightSource = snapshot.bodyMassKg.source,
              let height = snapshot.heightCm.value, let heightSource = snapshot.heightCm.source,
              let birth = snapshot.dateOfBirth.value, let birthSource = snapshot.dateOfBirth.source,
              let sex = snapshot.sex.value, let sexSource = snapshot.sex.source
        else { return .missing(missing) }

        let age = age(of: birth, on: date)
        let bmr = mifflinStJeor(weightKg: weight, heightCm: height, ageYears: age, sex: sex)
        let active = snapshot.activeEnergyKcal.value
        let tdee = active.map { bmr + $0 } ?? bmr * lightActivityFactor
        let targets = GoalTargets(
            energyKcal: rounded(tdee * energyFraction, to: 10),
            proteinG: rounded(weight * proteinGramsPerKg, to: 1)
        )
        return .ready(GoalRecommendation(
            input: .init(
                bodyMassKg: weight, weightSource: weightSource, heightCm: height, heightSource: heightSource,
                ageYears: age, ageSource: birthSource, sex: sex, sexSource: sexSource, activeEnergyKcal: active
            ),
            bmrKcal: rounded(bmr, to: Decimal(string: "0.1")!),
            tdeeKcal: rounded(tdee, to: Decimal(string: "0.1")!),
            tdeeEstimated: active == nil,
            targets: targets,
            generatedAt: now,
            policyVersion: version
        ))
    }

    /// Mifflin–St Jeor：10w + 6.25h − 5a + s，男 +5、女 −161；其他取两者平均 −78。
    static func mifflinStJeor(weightKg: Decimal, heightCm: Decimal, ageYears: Int, sex: BiologicalSex) -> Decimal {
        let offset: Decimal = switch sex {
        case .male: 5
        case .female: -161
        case .other: -78
        }
        return 10 * weightKg + Decimal(string: "6.25")! * heightCm - 5 * Decimal(ageYears) + offset
    }

    static func age(of birth: LocalDate, on date: LocalDate) -> Int {
        var age = date.year - birth.year
        if (date.month, date.day) < (birth.month, birth.day) { age -= 1 }
        return max(age, 0)
    }

    private static func rounded(_ value: Decimal, to step: Decimal) -> Decimal {
        var scaled = value / step
        var result = Decimal()
        NSDecimalRound(&result, &scaled, 0, .plain)
        return result * step
    }
}
