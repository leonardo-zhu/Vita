import Observation
import SwiftUI

@MainActor
@Observable
final class DayDataModel {
    enum Mode: String, CaseIterable {
        case day = "日"
        case week = "周"
    }

    enum State {
        case loading
        case day(DayData)
        case week(WeekData)
        case failed(String)
    }

    private let service: DayDataService
    private let timeZone: () -> TimeZone
    private let now: () -> Date

    var date: LocalDate
    var mode: Mode = .day
    private(set) var state: State = .loading

    init(service: DayDataService, now: @escaping () -> Date = Date.init, timeZone: @escaping () -> TimeZone = { .current }) {
        self.service = service
        self.now = now
        self.timeZone = timeZone
        self.date = LocalDate(date: now(), timeZone: timeZone())
    }

    var today: LocalDate { LocalDate(date: now(), timeZone: timeZone()) }

    func reload() {
        do {
            state = switch mode {
            case .day: .day(try service.day(date))
            case .week: .week(try service.week(containing: date))
            }
        } catch {
            state = .failed(String(describing: error))
        }
    }

    func shift(_ direction: Int) {
        date = date.adding(days: direction * (mode == .day ? 1 : 7))
        if date > today { date = today }
    }

    var canGoForward: Bool {
        switch mode {
        case .day: date < today
        case .week: date.startOfWeek < today.startOfWeek
        }
    }

    var title: String {
        switch mode {
        case .day: date == today ? "今天 · \(DisplayFormat.date(date))" : DisplayFormat.date(date)
        case .week: "\(DisplayFormat.shortDate(date.startOfWeek)) – \(DisplayFormat.shortDate(date.startOfWeek.adding(days: 6)))"
        }
    }
}

/// Data 页（PRD §3.5）：当日还能吃多少、宏量营养、按餐次的记录，以及周趋势。只读，修改走对话。
struct DataView: View {
    let services: AppServices
    @State private var model: DayDataModel
    @State private var isPickingDate = false

    init(services: AppServices) {
        self.services = services
        _model = State(initialValue: DayDataModel(service: services.dayData))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("视图", selection: $model.mode) {
                        ForEach(DayDataModel.Mode.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    datePager
                    content
                    libraryLink
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background { VitaTheme.background }
            .navigationTitle("数据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("选择日期", systemImage: "calendar") { isPickingDate = true }
                }
            }
            .sheet(isPresented: $isPickingDate) { datePicker }
        }
        .tint(VitaTheme.intake)
        .onAppear { model.reload() }
        .onChange(of: model.date) { model.reload() }
        .onChange(of: model.mode) { model.reload() }
    }

    private var datePager: some View {
        HStack {
            Button("前一\(model.mode == .day ? "天" : "周")", systemImage: "chevron.left") { model.shift(-1) }
                .labelStyle(.iconOnly)
            Spacer()
            Text(model.title).font(.headline).monospacedDigit()
            Spacer()
            Button("后一\(model.mode == .day ? "天" : "周")", systemImage: "chevron.right") { model.shift(1) }
                .labelStyle(.iconOnly)
                .disabled(!model.canGoForward)
        }
        .font(.title3)
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        case .failed(let message):
            ContentUnavailableView("无法读取数据", systemImage: "exclamationmark.triangle", description: Text(message))
        case .day(let day):
            DayDashboard(day: day)
        case .week(let week):
            WeekOverview(week: week, today: model.today) { date in
                model.date = date
                model.mode = .day
            }
        }
    }

    private var libraryLink: some View {
        NavigationLink {
            NutritionLibraryView(services: services)
        } label: {
            CardHeader(title: "营养库", systemImage: "books.vertical") {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .vitaCard()
        }
        .buttonStyle(.plain)
    }

    private var datePicker: some View {
        NavigationStack {
            DatePicker(
                "日期",
                selection: Binding(
                    get: { Calendar.current.date(from: DateComponents(year: model.date.year, month: model.date.month, day: model.date.day)) ?? Date() },
                    set: { model.date = LocalDate(date: $0, timeZone: .current) }
                ),
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .padding()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("今天") { model.date = model.today; isPickingDate = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { isPickingDate = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 日视图

private struct DayDashboard: View {
    let day: DayData

    var body: some View {
        VStack(spacing: 16) {
            EnergyCard(summary: day.summary)
            MacroCard(summary: day.summary)
            MealsSection(day: day)
        }
    }
}

/// 主卡：还可以吃多少。活动消耗随 Phase 4 的 HealthKit 读取加入等式。
private struct EnergyCard: View {
    let summary: DaySummary

    private var consumed: Decimal { summary.totals.energyKcal }
    private var target: Decimal? { summary.goal?.targets.energyKcal }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    if let target {
                        let remaining = target - consumed
                        Text(remaining >= 0 ? "还可以吃" : "已超出")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(remaining >= 0 ? VitaTheme.intake : VitaTheme.caution)
                        BigNumber(value: abs(remaining), unit: "千卡")
                    } else {
                        Text("今日已摄入")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(VitaTheme.intake)
                        BigNumber(value: consumed, unit: "千卡")
                    }
                }
                Spacer()
                if let target, target > 0 {
                    let fraction = NSDecimalNumber(decimal: consumed / target).doubleValue
                    ZStack {
                        ProgressRing(fraction: fraction, tint: VitaTheme.intake, lineWidth: 12)
                        Text(DisplayFormat.percent(consumed / target))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    .frame(width: 84, height: 84)
                }
            }
            if let target {
                HStack(spacing: 0) {
                    EquationTerm(value: target, label: "目标")
                    EquationSign("+")
                    // 运动消耗来自 HealthKit 活动能量，Phase 4 接入后再计入。
                    EquationTerm(value: nil, label: "运动消耗")
                    EquationSign("−")
                    EquationTerm(value: consumed, label: "已摄入")
                }
            } else {
                Text("还没有每日目标。完成目标设定后，这里会显示还可以吃多少。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if summary.estimatedItemCount > 0 {
                Label("其中 \(summary.estimatedItemCount) 项为 AI 估算", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(VitaTheme.caution)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(VitaTheme.caution.opacity(0.12), in: .capsule)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 28)
                .fill(LinearGradient(colors: [VitaTheme.cardTint, VitaTheme.card], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .shadow(color: .black.opacity(0.05), radius: 16, y: 6)
    }
}

private struct BigNumber: View {
    let value: Decimal
    let unit: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value.formatted(.number.precision(.fractionLength(0)).rounded(rule: .toNearestOrAwayFromZero)))
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(unit).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

private struct EquationTerm: View {
    let value: Decimal?
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value.map { $0.formatted(.number.precision(.fractionLength(0)).rounded(rule: .toNearestOrAwayFromZero)) } ?? "--")
                .font(.headline)
                .monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct EquationSign: View {
    let sign: String
    init(_ sign: String) { self.sign = sign }

    var body: some View {
        Text(sign).font(.headline).foregroundStyle(.tertiary)
    }
}

private struct MacroCard: View {
    let summary: DaySummary

    var body: some View {
        HStack(spacing: 12) {
            ForEach([Nutrient.proteinG, .fatG, .carbohydrateG], id: \.self) { nutrient in
                let progress = summary.progress.first { $0.nutrient == nutrient }!
                VStack(spacing: 8) {
                    ZStack {
                        ProgressRing(
                            fraction: progress.fraction.map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0,
                            tint: VitaTheme.color(for: nutrient),
                            lineWidth: 7
                        )
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text(progress.consumed.formatted(.number.precision(.fractionLength(0)).rounded(rule: .toNearestOrAwayFromZero)))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                            Text("g").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 60, height: 60)
                    Text(nutrient.label).font(.subheadline)
                    Text(progress.target.map { "目标 " + DisplayFormat.grams($0) } ?? "未设目标")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .vitaCard(padding: 20)
    }
}

/// 按餐次排列的记录卡片。
private struct MealsSection: View {
    let day: DayData

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("饮食记录").font(.title3.weight(.semibold)).padding(.horizontal, 4)
            if day.records.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "fork.knife.circle")
                        .font(.system(size: 40))
                        .foregroundStyle(VitaTheme.intake.opacity(0.6))
                    Text("这一天还没有记录").font(.headline)
                    Text("在 Chat 里告诉 Vita 你吃了什么，确认后会出现在这里。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .vitaCard(padding: 24)
            }
            ForEach(day.records) { record in
                NavigationLink {
                    RecordDetailView(record: record)
                } label: {
                    MealCard(record: record)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct MealCard: View {
    let record: DayData.Record

    var body: some View {
        let slot = MealSlot(record.eventTime)
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: record.mealLabel ?? slot.period.label, systemImage: slot.symbol, tint: slot.tint) {
                Text(DisplayFormat.energy(record.totals.energyKcal))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            if record.eventTime.precision != .mealPeriod {
                Text(DisplayFormat.eventTime(record.eventTime)).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(record.items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.displayName)
                    Text(item.originalAmountText).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    if item.snapshot.nutritionSource == .aiEstimated {
                        Image(systemName: "sparkles").font(.caption2).foregroundStyle(VitaTheme.caution)
                    }
                    Spacer()
                    Text(DisplayFormat.energy(item.snapshot.values.energyKcal))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(item.includeInSummary ? .primary : .tertiary)
                        .strikethrough(!item.includeInSummary)
                }
            }
        }
        .vitaCard()
    }
}

/// 卡片图标用的餐次：有餐段用餐段，有时刻按时刻粗分。只决定图标与默认标题，不改变记录的时间精度。
struct MealSlot {
    let period: MealPeriod

    init(_ time: EventTime) {
        if let mealPeriod = time.mealPeriod {
            period = mealPeriod
            return
        }
        guard let timestamp = time.timestamp else {
            period = .other
            return
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: time.timeZoneIdentifier) ?? .current
        period = switch calendar.component(.hour, from: timestamp) {
        case 5..<10: .breakfast
        case 10..<15: .lunch
        case 17..<21: .dinner
        default: .snack
        }
    }

    var symbol: String {
        switch period {
        case .breakfast: "sunrise.fill"
        case .lunch: "sun.max.fill"
        case .dinner: "moon.stars.fill"
        case .snack: "cup.and.saucer.fill"
        case .other: "fork.knife"
        }
    }

    var tint: Color {
        switch period {
        case .breakfast: VitaTheme.fat
        case .lunch: VitaTheme.intake
        case .dinner: VitaTheme.protein
        case .snack: VitaTheme.carbohydrate
        case .other: .secondary
        }
    }
}
