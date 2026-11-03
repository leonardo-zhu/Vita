import Foundation

/// 一项指标落在哪个区间。
enum BodyRating: String, Equatable, Sendable {
    case low, standard, high, veryHigh, excellent

    var label: String {
        switch self {
        case .low: "偏低"
        case .standard: "标准"
        case .high: "偏高"
        case .veryHigh: "过高"
        case .excellent: "优秀"
        }
    }
}

/// 判定区间：`bounds` 从小到大，`ratings` 比它多一项（第一段在最小边界以下）。值等于边界时归入较高的一段。
struct BodyRange: Equatable, Sendable {
    let bounds: [Decimal]
    let ratings: [BodyRating]

    func rating(of value: Decimal) -> BodyRating {
        ratings[bounds.firstIndex { value < $0 } ?? bounds.count]
    }

    /// 比例区间换算成质量区间（例如体脂率区间 × 体重 = 脂肪量区间）。
    func scaled(by factor: Decimal) -> BodyRange {
        BodyRange(bounds: bounds.map { $0 * factor }, ratings: ratings)
    }
}

enum BodyMetricGroup: String, CaseIterable, Sendable {
    case core = "核心"
    case fat = "脂肪"
    case muscle = "肌肉与水分"
}

enum BodyMetricKind: String, CaseIterable, Sendable {
    case weight, bmi, bodyFat, leanMass, basalMetabolism
    case fatMass, subcutaneousFatRate, subcutaneousFatMass
    case muscleMass, muscleRate, skeletalMuscleMass, skeletalMuscleRate, waterRate, waterMass, proteinMass, proteinRate, boneMass

    var title: String {
        switch self {
        case .weight: "体重"
        case .bmi: "BMI"
        case .bodyFat: "体脂率"
        case .leanMass: "去脂体重"
        case .basalMetabolism: "基础代谢"
        case .fatMass: "脂肪量"
        case .subcutaneousFatRate: "皮下脂肪率"
        case .subcutaneousFatMass: "皮下脂肪量"
        case .muscleMass: "肌肉量"
        case .muscleRate: "肌肉率"
        case .skeletalMuscleMass: "骨骼肌量"
        case .skeletalMuscleRate: "骨骼肌率"
        case .waterRate: "体水分率"
        case .waterMass: "体水分量"
        case .proteinMass: "蛋白质"
        case .proteinRate: "蛋白质占比"
        case .boneMass: "骨量"
        }
    }

    var group: BodyMetricGroup {
        switch self {
        case .weight, .bmi, .bodyFat, .leanMass, .basalMetabolism: .core
        case .fatMass, .subcutaneousFatRate, .subcutaneousFatMass: .fat
        default: .muscle
        }
    }

    /// 百分比指标的值是 0–1，显示时乘 100。
    var unit: String {
        switch self {
        case .bmi: ""
        case .basalMetabolism: "千卡"
        case .bodyFat, .subcutaneousFatRate, .muscleRate, .skeletalMuscleRate, .waterRate, .proteinRate: "%"
        default: "kg"
        }
    }

    var isPercent: Bool { unit == "%" }

    var digits: Int {
        switch self {
        case .weight: 2
        case .basalMetabolism: 0
        default: 1
        }
    }

    /// 体重是秤测的，BMI 由体重和身高直接算出；其余都是估算或由估算换算。
    var isEstimate: Bool { self != .weight && self != .bmi }

    var explanation: String {
        switch self {
        case .weight: "秤测得的体重。"
        case .bmi: "体重 ÷ 身高²。不区分脂肪和肌肉，肌肉多的人会偏高。"
        case .bodyFat: "脂肪占体重的比例。由体重、阻抗、身高、年龄、性别估算，是其余大部分指标的基础。"
        case .leanMass: "体重减去脂肪，包括肌肉、骨骼、水分和器官。蛋白质目标按它给更合理。"
        case .basalMetabolism: "静息时一天消耗的能量，按去脂体重计算（370 + 21.6 × 去脂体重）。"
        case .fatMass: "体重 × 体脂率。"
        case .subcutaneousFatRate: "皮肤下面的脂肪占体重的比例。"
        case .subcutaneousFatMass: "皮肤下面的脂肪重量，约占全部脂肪的七成。"
        case .muscleMass: "去脂体重减去骨量，包含骨骼肌、平滑肌和其中的水分。"
        case .muscleRate: "肌肉量占体重的比例。"
        case .skeletalMuscleMass: "附着在骨骼上、能主动收缩的肌肉，力量训练主要增加的是它。"
        case .skeletalMuscleRate: "骨骼肌占体重的比例。"
        case .waterRate: "身体水分占体重的比例。脂肪越少、肌肉越多，水分率越高。"
        case .waterMass: "身体里细胞内液和细胞外液的总量。"
        case .proteinMass: "身体里蛋白质的总量，主要在肌肉里。"
        case .proteinRate: "蛋白质占体重的比例。"
        case .boneMass: "骨骼中矿物质的重量。秤的电流穿不过骨骼，只能按去脂体重推算。"
        }
    }
}

struct BodyMetric: Equatable, Identifiable, Sendable {
    let kind: BodyMetricKind
    let value: Decimal
    /// 没有对应人群区间（目前只内置成年男性）时为 nil。
    let range: BodyRange?

    var id: BodyMetricKind { kind }
    var rating: BodyRating? { range?.rating(of: value) }
}

/// 一次称重的全部身体成分指标（身体成分模块 §4）。体脂率是核心估算，其余由体重、体脂率换算；
/// 换算关系与比例系数用蚂蚁阿福「身材管理」的两组样本核对过（误差约 ±0.3 kg）。
enum BodyComposition {
    /// 没有体脂率（没测到阻抗或缺资料）时只有体重和 BMI。
    static func metrics(for weighing: BodyWeighing) -> [BodyMetric] {
        metrics(weightKg: weighing.weightKg, bmi: weighing.bmi, bodyFatFraction: weighing.bodyFatFraction, sex: weighing.profile.sex)
    }

    static func metrics(weightKg weight: Decimal, bmi: Decimal?, bodyFatFraction: Decimal?, sex: BiologicalSex?) -> [BodyMetric] {
        let ranges = sex == .male ? Ranges.male(weight: weight) : [:]
        var values: [BodyMetricKind: Decimal] = [.weight: weight]
        if let bmi { values[.bmi] = bmi }
        if let fat = bodyFatFraction {
            let fatMass = weight * fat
            let lean = weight - fatMass
            let bone = lean * Ratios.boneOfLean
            let muscle = lean - bone
            let water = lean * Ratios.waterOfLean
            let protein = lean * Ratios.proteinOfLean
            let skeletal = muscle * Ratios.skeletalOfMuscle
            let subcutaneous = fatMass * Ratios.subcutaneousOfFat
            values[.bodyFat] = fat
            values[.leanMass] = lean
            values[.basalMetabolism] = 370 + Decimal(string: "21.6")! * lean
            values[.fatMass] = fatMass
            values[.subcutaneousFatMass] = subcutaneous
            values[.subcutaneousFatRate] = subcutaneous / weight
            values[.muscleMass] = muscle
            values[.muscleRate] = muscle / weight
            values[.skeletalMuscleMass] = skeletal
            values[.skeletalMuscleRate] = skeletal / weight
            values[.waterMass] = water
            values[.waterRate] = water / weight
            values[.proteinMass] = protein
            values[.proteinRate] = protein / weight
            values[.boneMass] = bone
        }
        return BodyMetricKind.allCases.compactMap { kind in
            values[kind].map { BodyMetric(kind: kind, value: $0, range: ranges[kind]) }
        }
    }

    /// 去脂体重中各成分的比例，取官方两组样本的平均。官方的具体公式拿不到，这些是近似。
    enum Ratios {
        static let boneOfLean = Decimal(string: "0.0546")!
        static let waterOfLean = Decimal(string: "0.737")!
        static let proteinOfLean = Decimal(string: "0.1975")!
        static let skeletalOfMuscle = Decimal(string: "0.573")!
        static let subcutaneousOfFat = Decimal(string: "0.718")!
    }

    /// 成年男性的判定区间，取自官方「身材管理」；BMI 用中国成人标准。
    enum Ranges {
        static func male(weight: Decimal) -> [BodyMetricKind: BodyRange] {
            let bodyFat = BodyRange(bounds: [d("0.10"), d("0.20"), d("0.25")], ratings: [.low, .standard, .high, .veryHigh])
            let muscleRate = BodyRange(bounds: [d("0.604"), d("0.754")], ratings: [.low, .standard, .excellent])
            let waterRate = BodyRange(bounds: [d("0.475"), d("0.592")], ratings: [.low, .standard, .high])
            return [
                .bmi: BodyRange(bounds: [d("18.5"), 24, 28], ratings: [.low, .standard, .high, .veryHigh]),
                .bodyFat: bodyFat,
                .fatMass: bodyFat.scaled(by: weight),
                .muscleRate: muscleRate,
                .muscleMass: muscleRate.scaled(by: weight),
                .waterRate: waterRate,
                .waterMass: waterRate.scaled(by: weight),
                .boneMass: BodyRange(bounds: [d("3.3"), d("4.2")], ratings: [.low, .standard, .high]),
            ]
        }

        private static func d(_ string: String) -> Decimal { Decimal(string: string)! }
    }
}
