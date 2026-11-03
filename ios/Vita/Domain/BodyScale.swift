import Foundation

/// 阿福体脂秤（AFU-WL-TZ-A1）的一帧称重数据。
struct ScaleMeasurement: Equatable, Sendable {
    struct Impedance: Equatable, Sendable {
        let a: Int
        let b: Int
    }

    let weightKg: Decimal
    let isStable: Bool
    /// 一次称重的锁定结果；只有这一帧才保存。
    let isFinal: Bool
    /// 光脚站上去才测得到；没有时不估算体脂率。
    let impedance: Impedance?
}

/// 秤在没连手机时存下的一条称重。
struct ScaleOfflineRecord: Equatable, Sendable {
    let measurement: ScaleMeasurement
    /// 称重时间；秤的时钟是 Vita 按大端写进去之前存的记录没有可靠时间，为 nil。
    let recordedAt: Date?
}

/// FFB2 通知帧的解析。帧格式与样例来自 AFUScale（已用真机数据核对）。
enum ScalePacketParser {
    static func parse(_ data: Data) -> ScaleMeasurement? {
        let b = [UInt8](data)
        guard b.count >= 20, b[0] == 0xAC, b[1] == 0x29 else { return nil }
        // 字节 18 是帧类别：只有 D5（实时）、D6（锁定）是当前称重；握手应答、离线记录等另行处理。
        guard b[18] == 0xD5 || b[18] == 0xD6 else { return nil }
        let kind = b[2]
        // 锁定结果帧：阻抗在 4–7，体重在 10–12。
        if kind == 0x02 {
            let a = Int(b[4]) << 8 | Int(b[5])
            let c = Int(b[6]) << 8 | Int(b[7])
            return ScaleMeasurement(
                weightKg: weight(b[10], b[11], b[12]),
                isStable: true,
                isFinal: true,
                impedance: (a == 0 && c == 0) ? nil : .init(a: a, b: c)
            )
        }
        // 实时帧：最高位是稳定标记。
        return ScaleMeasurement(weightKg: weight(b[3], b[4], b[5]), isStable: kind & 0x80 != 0, isFinal: false, impedance: nil)
    }

    /// 离线记录（D8 帧），格式已用真机核对：体重在 8–10（编码同实时帧），阻抗在 11–14，
    /// 字节 3–6 是秤的时钟（大端秒数）。只有 Vita 对过时的时钟才等于 Unix 时间；早于 2024 年的当作没有时间，晚于现在的由保存时剔除。
    static func parseOfflineRecord(_ data: Data) -> ScaleOfflineRecord? {
        let b = [UInt8](data)
        guard b.count >= 20, b[0] == 0xAC, b[1] == 0x29, b[18] == 0xD8 else { return nil }
        let a = Int(b[11]) << 8 | Int(b[12])
        let c = Int(b[13]) << 8 | Int(b[14])
        let seconds = b[3...6].reduce(0) { $0 << 8 | Int($1) }
        return ScaleOfflineRecord(
            measurement: ScaleMeasurement(
                weightKg: weight(b[8], b[9], b[10]),
                isStable: true,
                isFinal: true,
                impedance: (a == 0 && c == 0) ? nil : .init(a: a, b: c)
            ),
            recordedAt: seconds >= 1_704_067_200 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil
        )
    }

    /// 高字节每 +1 进 65.536 kg（从 0x68 起），低 16 位是克；保留两位小数。
    private static func weight(_ high: UInt8, _ mid: UInt8, _ low: UInt8) -> Decimal {
        let grams = (Int(high) - 0x68) * 65_536 + (Int(mid) << 8 | Int(low))
        return Decimal(grams / 10) / 100
    }
}

/// 体脂率估算：Deurenberg 公式（由 BMI、年龄、性别推算）加秤的校正值，与 AFUScale 一致。
/// 秤只回传阻抗、不回传体脂率；没测到阻抗（穿鞋或没站稳）就不给体脂率，宁缺勿猜。
enum BodyFatEstimate {
    static let calibration = Decimal(string: "1.5")!

    /// 0–1。缺身高、年龄或性别（含“其他”）时为 nil。
    static func fraction(weightKg: Decimal, heightCm: Decimal?, ageYears: Int?, sex: BiologicalSex?) -> Decimal? {
        guard let heightCm, heightCm > 0, let ageYears, let sex, sex != .other else { return nil }
        let meters = heightCm / 100
        let bmi = weightKg / (meters * meters)
        let percent = Decimal(string: "1.2")! * bmi + Decimal(string: "0.23")! * Decimal(ageYears)
            - (sex == .male ? Decimal(string: "10.8")! : 0) - Decimal(string: "5.4")! + calibration
        var fraction = percent / 100
        var result = Decimal()
        NSDecimalRound(&result, &fraction, 3, .plain)
        // 超出合理范围多半是身高等资料有误，不写入。
        return (Decimal(string: "0.02")!...Decimal(string: "0.7")!).contains(result) ? result : nil
    }
}

/// 写给秤 FFB1 的 20 字节指令（ICOMON 27 协议，取自 AFUScale 网页版的反编译结果）。
/// 字节 18 是指令类别，字节 19 是 2–18 的累加和。
/// 时间按大端写：秤按大端读时钟（按小端写进去后，离线记录的时间就是字节颠倒的值加上流逝的秒数，真机核对过）。
enum ScaleCommand {
    /// 秤里存的用户资料：用来让秤识别是谁在称、并存下离线记录。
    struct User: Equatable, Sendable {
        let heightCm: Int
        let weightKg: Decimal
        let ageYears: Int
        let isMale: Bool
    }

    /// 对时（DF 08）。
    static func setTime(_ date: Date, timeZone: TimeZone) -> Data {
        var b = [UInt8](repeating: 0, count: 20)
        b[2] = 0x08
        put32BE(UInt32(date.timeIntervalSince1970), into: &b, at: 3)
        b[7] = UInt8(truncatingIfNeeded: timeZone.secondsFromGMT(for: date) / 900)
        return frame(b, opcode: 0xDF)
    }

    /// 离线用户列表（D4），只放一个用户。
    static func userList(_ user: User) -> Data {
        var b = [UInt8](repeating: 0, count: 20)
        b[2] = 1
        b[5] = UInt8(clamping: user.heightCm)
        put16LE(centikilograms(user.weightKg), into: &b, at: 6)
        b[8] = ageAndSex(user)
        put16LE(centikilograms(user.weightKg), into: &b, at: 9)
        return frame(b, opcode: 0xD4)
    }

    /// 当前用户与时间（D7），开启阻抗测量。
    static func timeAndUser(_ user: User, date: Date, timeZone: TimeZone) -> Data {
        var b = [UInt8](repeating: 0, count: 20)
        put32BE(UInt32(date.timeIntervalSince1970), into: &b, at: 2)
        b[6] = UInt8(truncatingIfNeeded: timeZone.secondsFromGMT(for: date) / 900)
        b[8] = 1
        b[9] = UInt8(clamping: user.heightCm)
        put16LE(centikilograms(user.weightKg), into: &b, at: 10)
        b[12] = ageAndSex(user)
        put16LE(centikilograms(user.weightKg), into: &b, at: 13)
        b[15] = 0x01
        return frame(b, opcode: 0xD7)
    }

    /// 签名挑战（DF 06）：AFU-WL-TZ-A1 要先握手才吐离线记录。
    static let readSign = control(0x06)
    /// 回应秤的签名（DF 07）。
    static let replySign = control(0x07)
    static let wakeUp = control(0x03)
    /// 确认收到一条离线记录（DF 04 D8）：秤随即删掉这条、发下一条。
    static let historyAck: Data = {
        var b = [UInt8](repeating: 0, count: 20)
        b[2] = 0x04
        b[3] = 0xD8
        return frame(b, opcode: 0xDF)
    }()

    private static func control(_ operation: UInt8) -> Data {
        var b = [UInt8](repeating: 0, count: 20)
        b[2] = operation
        return frame(b, opcode: 0xDF)
    }

    private static func frame(_ bytes: [UInt8], opcode: UInt8) -> Data {
        var b = bytes
        b[0] = 0xAC
        b[1] = 0x29
        b[18] = opcode
        b[19] = b[2...18].reduce(0, &+)
        return Data(b)
    }

    private static func ageAndSex(_ user: User) -> UInt8 {
        UInt8(clamping: user.ageYears) & 0x7F | (user.isMale ? 0x80 : 0)
    }

    private static func centikilograms(_ kg: Decimal) -> UInt16 {
        UInt16(clamping: NSDecimalNumber(decimal: kg * 100).intValue)
    }

    private static func put16LE(_ value: UInt16, into b: inout [UInt8], at i: Int) {
        b[i] = UInt8(value & 0xFF)
        b[i + 1] = UInt8(value >> 8)
    }

    private static func put32BE(_ value: UInt32, into b: inout [UInt8], at i: Int) {
        for k in 0..<4 { b[i + k] = UInt8(truncatingIfNeeded: value >> (8 * (3 - k))) }
    }
}

/// 称重从哪来：打开称重页时站上去的，或秤里存着、同步过来的离线记录。
enum WeighingSource: String, Codable, Sendable {
    case live, offline
}

/// 称重当时的身高、年龄、性别；体脂率等指标按它算。
struct WeighingProfile: Equatable, Codable, Sendable {
    var heightCm: Decimal?
    var ageYears: Int?
    var sex: BiologicalSex?

    static let empty = WeighingProfile()
}

/// 一次称重：秤测到的原始数据，加上读取时算出的指标（身体成分模块 §5）。
struct BodyWeighing: Equatable, Identifiable, Sendable {
    let id: UUID
    let measuredAt: Date
    let weightKg: Decimal
    let impedance: ScaleMeasurement.Impedance?
    let source: WeighingSource
    /// false：离线记录没有可靠时间，`measuredAt` 是同步时间。
    let timeReliable: Bool
    let profile: WeighingProfile
    let inAppleHealth: Bool

    /// 没测到阻抗（穿鞋、没站稳）或缺资料时为 nil。
    var bodyFatFraction: Decimal? {
        guard impedance != nil else { return nil }
        return BodyFatEstimate.fraction(weightKg: weightKg, heightCm: profile.heightCm, ageYears: profile.ageYears, sex: profile.sex)
    }

    var bmi: Decimal? {
        guard let height = profile.heightCm, height > 0 else { return nil }
        let meters = height / 100
        return weightKg / (meters * meters)
    }
}
