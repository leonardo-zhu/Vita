import SwiftUI

/// 目标设定的弹窗：Data 页“生成每日目标 / 调整目标”打开它。内容与 Onboarding 共用 `GoalSetupForm`。
struct GoalSetupView: View {
    let services: AppServices
    let date: LocalDate
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            GoalSetupForm(services: services, date: date, onCommitted: onDone)
                .background { VitaTheme.background }
                .navigationTitle("每日目标")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消", action: onDone) }
                }
        }
        .tint(VitaTheme.intake)
    }
}

/// 目标设定（PRD §3.4）：展示身体数据及来源，缺项手动补录，预览建议的输入、公式与结果，一次确认后写入。
/// 手动补录只用于生成目标，不写回 Apple 健康。确认按钮固定在底部。
struct GoalSetupForm: View {
    let services: AppServices
    let date: LocalDate
    let onCommitted: () -> Void

    @State private var snapshot: HealthSnapshot?
    @State private var editing: MissingMetric?
    @State private var message: String?

    private var result: GoalRecommendationResult? {
        snapshot.map { GoalRecommendationPolicy.recommend(snapshot: $0, on: date, now: Date()) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metricsCard
                if case .ready(let recommendation) = result {
                    RecommendationCard(recommendation: recommendation)
                } else if case .missing(let missing) = result {
                    Text(missing.contains(.bodyMass) ? "体重是生成目标的必要数据，请补录后再生成。" : "还缺少 \(missing.map(\.label).joined(separator: "、"))，补录后即可生成。")
                        .font(VitaType.secondary)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                Text("这是按通用公式给出的默认建议，不是医疗建议。之后可以随时在对话里说“把蛋白质目标改成 150g”来调整。")
                    .font(VitaType.meta)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
            .padding(16)
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: commit) {
                Text("确认目标").font(.body.weight(.semibold)).frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .glassButton(prominent: true)
            .disabled(readyRecommendation == nil)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .sheet(item: $editing) { metric in
            ManualMetricForm(metric: metric) { metrics in
                do {
                    try services.health.submitManualBodyMetrics(metrics)
                    editing = nil
                    Task { await reload() }
                } catch {
                    message = "数值不在合理范围内。"
                }
            }
            .presentationDetents([.medium])
        }
        .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(message ?? "") }
        .task { await reload() }
    }

    private var readyRecommendation: GoalRecommendation? {
        if case .ready(let recommendation) = result { recommendation } else { nil }
    }

    private var metricsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "身体数据", systemImage: "person.text.rectangle") {
                if services.health.isAvailable, snapshot?.authorizationRequested == false {
                    Button("从健康读取") {
                        Task {
                            try? await services.health.requestAuthorization()
                            await reload()
                        }
                    }
                    .font(VitaType.body)
                }
            }
            if let snapshot {
                MetricRow(metric: .bodyMass, value: snapshot.bodyMassKg.value.map { DisplayFormat.number($0, digits: 1) + " kg" }, source: snapshot.bodyMassKg.source) { editing = .bodyMass }
                MetricRow(metric: .height, value: snapshot.heightCm.value.map { DisplayFormat.number($0, digits: 0) + " cm" }, source: snapshot.heightCm.source) { editing = .height }
                MetricRow(metric: .dateOfBirth, value: snapshot.dateOfBirth.value.map { "\($0.year) 年 \($0.month) 月 \($0.day) 日" }, source: snapshot.dateOfBirth.source) { editing = .dateOfBirth }
                MetricRow(metric: .sex, value: snapshot.sex.value.map(\.label), source: snapshot.sex.source) { editing = .sex }
                HStack {
                    Text("今日活动消耗").foregroundStyle(.secondary)
                    Spacer()
                    Text(snapshot.activeEnergyKcal.value.map { DisplayFormat.number($0, digits: 0) + " 千卡" } ?? "没有数据，按轻度活动估算")
                        .foregroundStyle(snapshot.activeEnergyKcal.value == nil ? .secondary : .primary)
                }
                .font(VitaType.body)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .vitaCard(padding: 20)
    }

    private func reload() async {
        snapshot = await services.health.snapshot(on: date)
    }

    private func commit() {
        guard let recommendation = readyRecommendation else { return }
        do {
            try services.goals.commitInitialGoals(recommendation, effectiveFrom: date)
            onCommitted()
        } catch {
            message = "保存目标失败：\(error)"
        }
    }
}

/// 整行可点：点一下补录或修改这一项，右侧箭头提示可以进入。
private struct MetricRow: View {
    let metric: MissingMetric
    let value: String?
    let source: MetricSource?
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            HStack(spacing: 8) {
                Text(metric.label).foregroundStyle(.secondary)
                Spacer()
                if let value {
                    Text(value).monospacedDigit().foregroundStyle(.primary)
                    Text(source == .manual ? "手动" : "健康")
                        .font(.caption2)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((source == .manual ? VitaTheme.fat : Color.pink).opacity(0.15), in: .capsule)
                } else {
                    let tint = metric == .bodyMass ? VitaTheme.caution : VitaTheme.intake
                    Label("补录", systemImage: "plus")
                        .font(VitaType.secondary.weight(.semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(tint.opacity(0.14), in: .capsule)
                }
                Image(systemName: "chevron.right")
                    .font(VitaType.meta.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(VitaType.body)
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(value == nil ? "补录\(metric.label)" : "修改\(metric.label)")
    }
}

/// 建议的计算过程：输入、公式与结果都摆出来（TDD §6.2）。
private struct RecommendationCard: View {
    let recommendation: GoalRecommendation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "建议目标", systemImage: "target")
            HStack {
                Stat(value: recommendation.targets.energyKcal ?? 0, unit: "千卡", label: "能量", tint: VitaTheme.intake)
                Stat(value: recommendation.targets.proteinG ?? 0, unit: "g", label: "蛋白质", tint: VitaTheme.protein)
            }
            Divider()
            Group {
                Text("基础代谢 BMR = 10 × 体重 + 6.25 × 身高 − 5 × 年龄 \(recommendation.input.sex == .male ? "+ 5" : recommendation.input.sex == .female ? "− 161" : "− 78") = \(DisplayFormat.number(recommendation.bmrKcal, digits: 0)) 千卡")
                Text(recommendation.tdeeEstimated
                     ? "每日总消耗 TDEE ≈ BMR × 1.375（轻度活动，估算）= \(DisplayFormat.number(recommendation.tdeeKcal, digits: 0)) 千卡"
                     : "每日总消耗 TDEE = BMR + 今日活动消耗 = \(DisplayFormat.number(recommendation.tdeeKcal, digits: 0)) 千卡")
                Text("能量目标 = 90% × TDEE；蛋白质目标 = 1.8 g × 体重")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .vitaCard(padding: 20)
    }
}

private struct Stat: View {
    let value: Decimal
    let unit: String
    let label: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(DisplayFormat.number(value, digits: 0)).font(.title.weight(.bold)).foregroundStyle(tint).monospacedDigit()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 补录单项身体数据（`submitManualBodyMetrics`）。
private struct ManualMetricForm: View {
    let metric: MissingMetric
    let onSave: (ManualBodyMetrics) -> Void
    @State private var number = ""
    @State private var birth = Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date()
    @State private var sex: BiologicalSex = .female
    @FocusState private var numberFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                switch metric {
                case .bodyMass:
                    TextField("体重（kg）", text: $number).keyboardType(.decimalPad).focused($numberFocused)
                case .height:
                    TextField("身高（cm）", text: $number).keyboardType(.decimalPad).focused($numberFocused)
                case .dateOfBirth:
                    DatePicker("出生日期", selection: $birth, in: ...Date(), displayedComponents: .date)
                case .sex:
                    Picker("生理性别", selection: $sex) {
                        ForEach(BiologicalSex.allCases, id: \.self) { Text($0.label) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Text("只用于生成目标，不会写回 Apple 健康。").font(.footnote).foregroundStyle(.secondary)
                }
            }
            // 打开就弹出数字键盘，不用再点一次输入框。
            .onAppear { numberFocused = true }
            .navigationTitle("补录\(metric.label)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { onSave(metrics) }.disabled(!canSave)
                }
            }
        }
    }

    private var value: Decimal? { Decimal(string: number) }

    private var canSave: Bool {
        switch metric {
        case .bodyMass, .height: value != nil
        case .dateOfBirth, .sex: true
        }
    }

    private var metrics: ManualBodyMetrics {
        var metrics = ManualBodyMetrics(enteredAt: Date())
        switch metric {
        case .bodyMass: metrics.bodyMassKg = value
        case .height: metrics.heightCm = value
        case .dateOfBirth: metrics.dateOfBirth = LocalDate(date: birth, timeZone: .current)
        case .sex: metrics.sex = sex
        }
        return metrics
    }
}

extension MissingMetric: Identifiable {
    var id: String { rawValue }

    var label: String {
        switch self {
        case .bodyMass: "体重"
        case .height: "身高"
        case .dateOfBirth: "出生日期"
        case .sex: "生理性别"
        }
    }
}

extension BiologicalSex {
    var label: String {
        switch self {
        case .female: "女"
        case .male: "男"
        case .other: "其他"
        }
    }
}
