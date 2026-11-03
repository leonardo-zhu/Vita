import SwiftUI

/// 一次称重的全部身体成分指标（身体成分模块 §6）：按核心、脂肪、肌肉与水分分组，
/// 每项带判定标签；点开看区间刻度与解释。除体重外都是估算，页面上明确标出。
struct WeighingDetailView: View {
    let weighing: BodyWeighing

    @State private var expanded: BodyMetricKind?

    private var metrics: [BodyMetric] { BodyComposition.metrics(for: weighing) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                if weighing.bodyFatFraction == nil { missingFatNotice }
                ForEach(BodyMetricGroup.allCases, id: \.self) { group in
                    let items = metrics.filter { $0.kind.group == group }
                    if !items.isEmpty { section(group, items) }
                }
                Text("体重是秤测得的，BMI 由体重和身高算出，其余指标由体重、阻抗和身高、年龄、性别估算，适合看趋势，不适合当作精确数值。判定区间取自蚂蚁阿福，目前只有成年男性一档。")
                    .font(VitaType.secondary)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding(16)
        }
        .background { VitaTheme.background }
        .navigationTitle(Text(weighing.measuredAt, format: .dateTime.month().day()))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(DisplayFormat.number(weighing.weightKg, digits: 2))
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("kg").font(.title3).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: weighing.inAppleHealth ? "heart.fill" : "heart.slash")
                    .foregroundStyle(weighing.inAppleHealth ? AnyShapeStyle(.pink) : AnyShapeStyle(.tertiary))
                    .accessibilityLabel(weighing.inAppleHealth ? "已写入 Apple 健康" : "未写入 Apple 健康")
            }
            subtitle.font(VitaType.secondary).foregroundStyle(.secondary)
        }
        .vitaCard()
    }

    /// 用 Text 的格式化，日期跟随 App 的语言（`Date.formatted` 跟随系统地区，会显示成英文）。
    private var subtitle: Text {
        let details = ([weighing.source == .offline ? "离线同步" : "实时称重"]
            + (weighing.impedance.map { ["阻抗 \($0.a) / \($0.b) Ω"] } ?? [])).joined(separator: " · ")
        let time = weighing.measuredAt
        return weighing.timeReliable
            ? Text("\(time, format: .dateTime.year().month().day().hour().minute()) · \(details)")
            : Text("称重时间未知，按同步时间 \(time, format: .dateTime.month().day().hour().minute()) 保存 · \(details)")
    }

    private var missingFatNotice: some View {
        Label(weighing.impedance == nil
              ? "这次没测到阻抗（可能穿着鞋或没站稳），只有体重和 BMI。"
              : "缺少身高、出生日期或性别，无法估算体脂率。可在“每日目标”里补录。",
              systemImage: "info.circle")
            .font(VitaType.secondary)
            .foregroundStyle(.secondary)
            .vitaCard(padding: 14)
    }

    private func section(_ group: BodyMetricGroup, _ items: [BodyMetric]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(group.rawValue).font(.title3.weight(.semibold)).padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, metric in
                    if index > 0 { Divider().padding(.leading, 16) }
                    row(metric)
                }
            }
            .vitaCard(padding: 0)
        }
    }

    private func row(_ metric: BodyMetric) -> some View {
        let isExpanded = expanded == metric.kind
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy) { expanded = isExpanded ? nil : metric.kind }
            } label: {
                HStack(spacing: 8) {
                    Text(metric.kind.title).foregroundStyle(.primary)
                    if metric.kind.isEstimate {
                        Text("估算").font(VitaType.meta).foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(Self.format(metric.value, metric.kind)).font(.body.weight(.semibold)).monospacedDigit()
                        Text(metric.kind.unit).font(VitaType.meta).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                    if let rating = metric.rating { RatingBadge(rating: rating) }
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if isExpanded {
                if let range = metric.range { RangeBar(metric: metric, range: range) }
                Text(metric.kind.explanation).font(VitaType.secondary).foregroundStyle(.secondary)
            }
        }
        .font(VitaType.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    static func format(_ value: Decimal, _ kind: BodyMetricKind) -> String {
        DisplayFormat.number(kind.isPercent ? value * 100 : value, digits: kind.digits)
    }
}

private struct RatingBadge: View {
    let rating: BodyRating

    var body: some View {
        Text(rating.label)
            .font(VitaType.meta.weight(.medium))
            .foregroundStyle(rating.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(rating.color.opacity(0.12), in: .capsule)
    }
}

/// 区间刻度：每段一种颜色，三角标出当前值，段下写边界与判定。
private struct RangeBar: View {
    let metric: BodyMetric
    let range: BodyRange

    /// 两端各留出一段的宽度，当前值落在区间外时也能标出来。
    private var span: (lower: Decimal, upper: Decimal) {
        let first = range.bounds.first ?? 0, last = range.bounds.last ?? 1
        let pad = range.bounds.count > 1 ? (last - first) / Decimal(range.bounds.count - 1) : max(first, 1) / 2
        return (min(first - pad, metric.value), max(last + pad, metric.value))
    }

    private func position(_ value: Decimal, width: CGFloat) -> CGFloat {
        let (lower, upper) = span
        guard upper > lower else { return 0 }
        return width * CGFloat(NSDecimalNumber(decimal: (value - lower) / (upper - lower)).doubleValue)
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let edges = [0] + range.bounds.map { position($0, width: width) } + [width]
                ZStack(alignment: .leading) {
                    ForEach(range.ratings.indices, id: \.self) { index in
                        Capsule()
                            .fill(range.ratings[index].color.opacity(range.ratings[index] == metric.rating ? 0.9 : 0.25))
                            .frame(width: max(edges[index + 1] - edges[index] - 2, 2), height: 6)
                            .offset(x: edges[index] + 1)
                    }
                    Image(systemName: "arrowtriangle.down.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(metric.rating?.color ?? .secondary)
                        .offset(x: position(metric.value, width: width) - 4.5, y: -10)
                }
                .frame(height: 6)
                .offset(y: 8)
            }
            .frame(height: 16)
            // 边界数字对准分段处，判定文字放在各段中间。
            GeometryReader { proxy in
                let width = proxy.size.width
                let edges = [0] + range.bounds.map { position($0, width: width) } + [width]
                ZStack(alignment: .topLeading) {
                    ForEach(range.bounds.indices, id: \.self) { index in
                        Text(WeighingDetailView.format(range.bounds[index], metric.kind))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 48)
                            .offset(x: edges[index + 1] - 24)
                    }
                    ForEach(range.ratings.indices, id: \.self) { index in
                        Text(range.ratings[index].label)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(width: 48)
                            .offset(x: (edges[index] + edges[index + 1]) / 2 - 24, y: 16)
                    }
                }
            }
            .frame(height: 30)
        }
    }
}

extension BodyRating {
    var color: Color {
        switch self {
        case .low: VitaTheme.protein
        case .standard: VitaTheme.intake
        case .excellent: VitaTheme.carbohydrate
        case .high: VitaTheme.caution
        case .veryHigh: .red
        }
    }
}
