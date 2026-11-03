import Foundation
import SwiftData

/// 体脂秤的一次称重原始记录（身体成分模块 §5）：只存秤测到的体重与阻抗，体脂率等指标读取时再算，
/// 算法更新后历史一起重算。秤确认离线记录后就删掉了，这里是唯一一份。
@Model
final class ScaleWeighing {
    @Attribute(.unique) var id: UUID
    var measuredAt: Date
    var weightGrams: Int
    var impedanceA: Int?
    var impedanceB: Int?
    var sourceRaw: String
    /// 离线记录在 Vita 校准秤的时钟之前存下的，没有可靠时间，`measuredAt` 是同步时间。
    var timeReliable: Bool
    /// 称重时的身高、年龄、性别，指标按当时的资料算。
    var profileData: Data
    /// 写进 Apple 健康的 Sample；删除这次称重时一起删。
    var healthSampleIDsData: Data
    /// 用户照着秤屏幕记下的体脂率（千分比），用来校准（身体成分模块 §4.2）。
    var scaleBodyFatPermille: Int?
    var createdAt: Date

    init(
        id: UUID = UUID(), measuredAt: Date, weightGrams: Int, impedance: ScaleMeasurement.Impedance?,
        source: WeighingSource, timeReliable: Bool, profile: WeighingProfile, healthSampleIDs: [UUID], now: Date
    ) {
        self.id = id
        self.measuredAt = measuredAt
        self.weightGrams = weightGrams
        self.impedanceA = impedance?.a
        self.impedanceB = impedance?.b
        self.sourceRaw = source.rawValue
        self.timeReliable = timeReliable
        self.profileData = JSONColumn.encode(profile)
        self.healthSampleIDsData = JSONColumn.encode(healthSampleIDs)
        self.createdAt = now
    }

    var healthSampleIDs: [UUID] {
        get { (try? JSONColumn.decode([UUID].self, from: healthSampleIDsData)) ?? [] }
        set { healthSampleIDsData = JSONColumn.encode(newValue) }
    }

    var scaleBodyFatFraction: Decimal? {
        get { scaleBodyFatPermille.map { Decimal($0) / 1000 } }
        set { scaleBodyFatPermille = newValue.map { NSDecimalNumber(decimal: $0 * 1000).rounding(accordingToBehavior: nil).intValue } }
    }

    func snapshot(calibration: BodyFatModel? = nil) throws -> BodyWeighing {
        BodyWeighing(
            id: id,
            measuredAt: measuredAt,
            weightKg: Decimal(weightGrams) / 1000,
            impedance: impedanceA.flatMap { a in impedanceB.map { .init(a: a, b: $0) } },
            source: WeighingSource(rawValue: sourceRaw) ?? .live,
            timeReliable: timeReliable,
            profile: try JSONColumn.decode(WeighingProfile.self, from: profileData),
            inAppleHealth: !healthSampleIDs.isEmpty,
            scaleBodyFatFraction: scaleBodyFatFraction,
            calibration: calibration
        )
    }
}
