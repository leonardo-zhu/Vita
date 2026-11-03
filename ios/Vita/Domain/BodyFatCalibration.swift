import Foundation

/// 用用户自己记下的“秤屏幕上的体脂率”反推秤的公式（身体成分模块 §4.2）。目的不是更准，而是和秤显示同一个数：
/// 秤的芯片按体重、阻抗、身高等用固定公式算，同样的输入一定得出同样的结果，几组读数就能把系数拟合出来。
///
/// 形式取 BIA 秤的通用式：体脂率 = a · 身高² / 阻抗 + b · 体重 + c。年龄、性别对单一用户短期不变，并进常数。
struct BodyFatModel: Equatable, Codable, Sendable {
    enum Channel: String, Codable, Sendable { case a, b }

    /// 用秤回传的哪一路阻抗。
    let channel: Channel
    let heightSquaredOverImpedance: Double
    let weight: Double
    let constant: Double
    let sampleCount: Int
    /// 留一法交叉验证的平均绝对误差（0–1），比训练残差更接近换一次称重时的真实偏差。
    let meanAbsoluteError: Double

    /// 缺身高或阻抗时为 nil；结果超出合理范围（资料有误、外推太远）时也为 nil。
    func predict(weightKg: Decimal, heightCm: Decimal?, impedance: ScaleMeasurement.Impedance?) -> Decimal? {
        guard let heightCm, let feature = BodyFatCalibration.feature(heightCm: heightCm, impedance: impedance, channel: channel) else { return nil }
        let value = heightSquaredOverImpedance * feature + weight * NSDecimalNumber(decimal: weightKg).doubleValue + constant
        guard (0.02...0.7).contains(value) else { return nil }
        var result = Decimal()
        var raw = Decimal(value)
        NSDecimalRound(&result, &raw, 3, .plain)
        return result
    }
}

/// 校准的进度：记了几组读数、拟合结果、是否已采用。
struct BodyFatCalibrationStatus: Equatable, Sendable {
    let readingCount: Int
    let model: BodyFatModel?

    /// 已采用：之后的体脂率按校准公式算，和秤显示一致。
    var applied: BodyFatModel? { model.flatMap { BodyFatCalibration.isUsable($0) ? $0 : nil } }

    static let none = BodyFatCalibrationStatus(readingCount: 0, model: nil)
}

enum BodyFatCalibration {
    /// 拟合 3 个系数，至少要这么多组；少于它照常用 BMI 估算。
    static let minimumSamples = 6
    /// 秤若真按这个形式计算，误差只剩显示取整（约 0.05%）。交叉验证误差超过 1% 说明形式不对或读数记错了，不采用。
    static let maximumError = 0.01

    struct Sample: Equatable, Sendable {
        let weightKg: Decimal
        let heightCm: Decimal
        let impedance: ScaleMeasurement.Impedance
        /// 秤屏幕上显示的体脂率，0–1。
        let observed: Decimal
    }

    /// 两路阻抗各拟合一次，取交叉验证误差小的那一路。样本不够、体重几乎没变化（系数分不开）时为 nil。
    static func fit(_ samples: [Sample]) -> BodyFatModel? {
        guard samples.count >= minimumSamples else { return nil }
        return [BodyFatModel.Channel.a, .b]
            .compactMap { fit(samples, channel: $0) }
            .min { $0.meanAbsoluteError < $1.meanAbsoluteError }
    }

    /// 拟合结果能否用来替代 BMI 估算。
    static func isUsable(_ model: BodyFatModel) -> Bool { model.meanAbsoluteError <= maximumError }

    static func feature(heightCm: Decimal, impedance: ScaleMeasurement.Impedance?, channel: BodyFatModel.Channel) -> Double? {
        guard let impedance else { return nil }
        let ohms = channel == .a ? impedance.a : impedance.b
        guard ohms > 0 else { return nil }
        let meters = NSDecimalNumber(decimal: heightCm).doubleValue / 100
        return meters * meters / Double(ohms)
    }

    private static func fit(_ samples: [Sample], channel: BodyFatModel.Channel) -> BodyFatModel? {
        let rows = samples.compactMap { sample -> (x: [Double], y: Double)? in
            guard let feature = feature(heightCm: sample.heightCm, impedance: sample.impedance, channel: channel) else { return nil }
            return ([feature, NSDecimalNumber(decimal: sample.weightKg).doubleValue, 1], NSDecimalNumber(decimal: sample.observed).doubleValue)
        }
        guard rows.count >= minimumSamples, let coefficients = leastSquares(rows) else { return nil }
        // 留一法：每次拿掉一组拟合，再预测拿掉的那组。
        var errors: [Double] = []
        for index in rows.indices {
            var rest = rows
            let held = rest.remove(at: index)
            guard let partial = leastSquares(rest) else { return nil }
            errors.append(abs(zip(partial, held.x).map(*).reduce(0, +) - held.y))
        }
        return BodyFatModel(
            channel: channel,
            heightSquaredOverImpedance: coefficients[0], weight: coefficients[1], constant: coefficients[2],
            sampleCount: rows.count,
            meanAbsoluteError: errors.reduce(0, +) / Double(errors.count)
        )
    }

    /// 解正规方程 (XᵀX)β = Xᵀy（3×3，高斯消元）。矩阵接近奇异（某个特征几乎不变）时为 nil。
    private static func leastSquares(_ rows: [(x: [Double], y: Double)]) -> [Double]? {
        let n = 3
        var m = Array(repeating: Array(repeating: 0.0, count: n + 1), count: n)
        for row in rows {
            for i in 0..<n {
                for j in 0..<n { m[i][j] += row.x[i] * row.x[j] }
                m[i][n] += row.x[i] * row.y
            }
        }
        let scale = m.map { $0[..<n].map(abs).max() ?? 0 }.max() ?? 0
        for column in 0..<n {
            guard let pivot = (column..<n).max(by: { abs(m[$0][column]) < abs(m[$1][column]) }),
                  abs(m[pivot][column]) > scale * 1e-12 else { return nil }
            m.swapAt(column, pivot)
            for row in 0..<n where row != column {
                let factor = m[row][column] / m[column][column]
                for k in column...n { m[row][k] -= factor * m[column][k] }
            }
        }
        return (0..<n).map { m[$0][n] / m[$0][$0] }
    }
}
