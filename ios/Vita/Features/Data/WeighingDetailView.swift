import SwiftUI

/// 一次称重的全部身体成分指标（身体成分模块 §6）：按核心、脂肪、肌肉与水分分组，
/// 每项带判定标签；点开看区间刻度与解释。除体重外都是估算，页面上明确标出。
/// 可以记下这次秤屏幕上显示的体脂率，用来校准（§4.2）。
struct WeighingDetailView: View {
    let services: AppServices
    @State var weighing: BodyWeighing

    @State private var expanded: BodyMetricKind?
    @State private var readingText = ""
    @State private var readingError: String?
    @FocusState private var readingFocused: Bool

    private var metrics: [BodyMetric] { BodyComposition.metrics(for: weighing) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                if weighing.bodyFatFraction == nil { missingFatNotice }
                if weighing.impedance != nil { scaleReadingCard }
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
        .scrollDismissesKeyboard(.interactively)
        .onAppear { readingText = weighing.scaleBodyFatFraction.map { DisplayFormat.number($0 * 100, digits: 1) } ?? "" }
    }

    // MARK: - 秤读数

    private var scaleReadingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("秤上显示的体脂率").font(VitaType.body.weight(.medium))
            Text("称完时秤屏幕上会显示体脂率。记下它，攒够 \(BodyFatCalibration.minimumSamples) 组后 Vita 就能算出和秤一样的数。")
                .font(VitaType.secondary)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    TextField("例如 21.4", text: $readingText)
                        .keyboardType(.decimalPad)
                        .focused($readingFocused)
                        .monospacedDigit()
                    Text("%").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 12))
                Button(weighing.scaleBodyFatFraction == nil ? "保存" : "更新") { Task { await saveReading() } }
                    .glassButton(prominent: true)
                    .disabled(readingText.trimmingCharacters(in: .whitespaces).isEmpty)
                if weighing.scaleBodyFatFraction != nil {
                    Button("清除") { readingText = ""; Task { await saveReading() } }.glassButton()
                }
            }
            if let readingError {
                Text(readingError).font(VitaType.secondary).foregroundStyle(VitaTheme.caution)
            }
        }
        .vitaCard()
    }

    private func saveReading() async {
        readingError = nil
        let trimmed = readingText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let fraction: Decimal?
        if trimmed.isEmpty {
            fraction = nil
        } else if trimmed.wholeMatch(of: /\d{1,2}(\.\d{1,2})?/) != nil, let percent = Decimal(string: trimmed) {
            // 先整串校验：Decimal(string:) 遇到 "21.421.4" 会只读前半截而不报错。
            fraction = percent / 100
        } else {
            readingError = "请填数字，例如 21.4。"
            return
        }
        do {
            try await services.bodyComposition.setScaleBodyFat(fraction, for: weighing.id)
            readingFocused = false
            if let updated = try services.bodyComposition.weighings().first(where: { $0.id == weighing.id }) { weighing = updated }
            readingText = weighing.scaleBodyFatFraction.map { DisplayFormat.number($0 * 100, digits: 1) } ?? ""
        } catch HealthServiceError.invalidMetrics {
            readingError = "体脂率应在 2% 到 70% 之间。"
        } catch {
            readingError = "保存失败，请再试一次。"
        }
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
            if let type = BodyComposition.bodyType(bmi: weighing.bmi, bodyFatFraction: weighing.bodyFatFraction, sex: weighing.profile.sex) {
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("体型").font(VitaType.secondary).foregroundStyle(.secondary)
                    Text(type.name).font(VitaType.body.weight(.semibold))
                    Text(type.explanation).font(VitaType.secondary).foregroundStyle(.secondary)
                }
            }
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
                    if let tag = tag(for: metric.kind) {
                        Text(tag).font(VitaType.meta).foregroundStyle(.secondary)
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

    /// 体脂率标出来源；由它换算的指标仍标“估算”（比例系数是近似）。
    private func tag(for kind: BodyMetricKind) -> String? {
        guard kind.isEstimate else { return nil }
        guard kind == .bodyFat, let source = weighing.bodyFat?.source else { return "估算" }
        return switch source {
        case .scaleReading: "秤读数"
        case .calibrated: "已校准"
        case .estimated: "估算"
        }
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
