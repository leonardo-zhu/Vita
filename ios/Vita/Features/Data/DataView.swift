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
    private let health: HealthService
    private let timeZone: () -> TimeZone
    private let now: () -> Date

    var date: LocalDate
    var mode: Mode = .day
    private(set) var state: State = .loading
    /// 所选日期的健康数据；异步读取，读完之前为空。
    private(set) var snapshot: HealthSnapshot?

    init(service: DayDataService, health: HealthService, now: @escaping () -> Date = Date.init, timeZone: @escaping () -> TimeZone = { .current }) {
        self.service = service
        self.health = health
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

    /// 读健康数据，同时刷新活动缓存（能量目标随活动计算），再按新读数重算页面。周视图刷新这一周。
    func loadHealth() async {
        snapshot = await health.snapshot(on: date)
        if mode == .week {
            let start = date.startOfWeek
            await health.refreshActivity(on: (0..<7).map { start.adding(days: $0) }.filter { $0 <= today })
        }
        reload()
    }

    func connectHealth() async {
        try? await health.requestAuthorization()
        await loadHealth()
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
        _model = State(initialValue: DayDataModel(service: services.dayData, health: services.health))
    }

    @State private var isSettingGoal = false
    @Environment(\.scenePhase) private var scenePhase

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
            .sheet(isPresented: $isSettingGoal) {
                GoalSetupView(services: services, date: model.date) {
                    isSettingGoal = false
                    model.reload()
                }
            }
        }
        .tint(VitaTheme.intake)
        .onAppear { model.reload() }
        .onChange(of: model.date) { model.reload() }
        .onChange(of: model.mode) { model.reload() }
        .task(id: "\(model.date.isoString)-\(model.mode)") { await model.loadHealth() }
        // 进入页面与回到前台时补同步，并刷新同步标记。
        .task { await syncHealth() }
        .onChange(of: scenePhase) {
            if scenePhase == .active { Task { await model.loadHealth(); await syncHealth() } }
        }
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
            DayDashboard(
                day: day,
                isToday: day.date == model.today,
                snapshot: model.snapshot,
                healthAvailable: services.health.isAvailable,
                onSetGoal: { isSettingGoal = true },
                onConnectHealth: { Task { await model.connectHealth(); await syncHealth() } },
                onRetrySync: { Task { await syncHealth() } }
            )
            // 每天一个视图身份：切换日期时直接换成那天的内容，不从前一天的进度圆环动画过去（否则卡片高度变化时圆环会跟着位移动画、看起来漂移）。
            .id(day.date)
        case .week(let week):
            WeekOverview(week: week, today: model.today) { date in
                model.date = date
                model.mode = .day
            }
        }
    }

    private func syncHealth() async {
        await services.healthSync.run()
        model.reload()
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
    let isToday: Bool
    let snapshot: HealthSnapshot?
    let healthAvailable: Bool
    let onSetGoal: () -> Void
    let onConnectHealth: () -> Void
    let onRetrySync: () -> Void

    private var needsSyncAttention: Bool {
        day.records.contains { $0.healthSync == .requiresUserResolution || $0.healthSync == .failedRetryable }
    }

    var body: some View {
        VStack(spacing: 16) {
            EnergyCard(summary: day.summary, isToday: isToday, activeEnergy: snapshot?.activeEnergyKcal.value, onSetGoal: onSetGoal)
            MacroCard(summary: day.summary)
            if needsSyncAttention { syncAttention }
            MealsSection(day: day)
            HealthSection(snapshot: snapshot, isAvailable: healthAvailable, onConnect: onConnectHealth)
        }
    }

    /// 同步遇到问题时明确告诉用户，不静默失效（PRD §3.3 权限处理）。
    private var syncAttention: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(title: "部分记录没有同步到 Apple 健康", systemImage: "heart.slash", tint: VitaTheme.caution)
            Text("记录已保存在 Vita。若关闭了写入权限，到“\(HealthApp.permissionPath)”打开后重试。")
                .font(VitaType.body)
                .foregroundStyle(.secondary)
            HStack {
                Button("重试同步", action: onRetrySync).glassButton()
                Button("打开健康 App", action: HealthApp.open).glassButton()
            }
        }
        .vitaCard(padding: 20)
    }
}

/// 主卡：还可以吃多少，并列出目标、已摄入与当日活动消耗。
private struct EnergyCard: View {
    let summary: DaySummary
    let isToday: Bool
    let activeEnergy: Decimal?
    let onSetGoal: () -> Void

    private var consumed: Decimal { summary.totals.energyKcal }
    private var target: Decimal? { summary.goal?.targets.energyKcal }

    var body: some View {
        if let target {
            goalCard(target: target)
        } else if isToday {
            // 没有目标时不摆一个孤零零的大号“0”，而是引导去生成目标；当天已有摄入时一并列出。
            InvitationCard(
                symbol: "target",
                tint: VitaTheme.intake,
                title: "设定每日目标",
                message: consumed > 0
                    ? "今天已摄入 \(DisplayFormat.energy(consumed))。设定目标后这里显示还可以吃多少。"
                    : "按身高、体重和活动量生成，之后这里显示还可以吃多少。",
                actionTitle: "生成每日目标",
                action: onSetGoal
            )
        } else {
            pastDayWithoutGoal
        }
    }

    /// 目标从生效日起一直沿用；早于第一个目标的日子只显示摄入，不在这里邀请设目标，以免让人以为每天都要设。
    /// 用紧凑的一行，不摆大号数字。
    private var pastDayWithoutGoal: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("这天已摄入")
                    .font(VitaType.body.weight(.medium))
                    .foregroundStyle(VitaTheme.intake)
                Text("这天还没有设定目标")
                    .font(VitaType.secondary)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(DisplayFormat.number(consumed, digits: 0))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Text("千卡").font(VitaType.meta).foregroundStyle(.secondary)
            }
        }
        .vitaCard(padding: 20)
    }

    private func goalCard(target: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    let remaining = target - consumed
                    Text(remaining >= 0 ? "还可以吃" : "已超出")
                        .font(VitaType.body.weight(.medium))
                        .foregroundStyle(remaining >= 0 ? VitaTheme.intake : VitaTheme.caution)
                    BigNumber(value: abs(remaining), unit: "千卡")
                }
                Spacer()
                if target > 0 {
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
            if let energy = summary.energy {
                // 能量目标随活动计算（ADR-018）：第三项是截至现在的热量收支，下面一行说明目标怎么来的。
                HStack(spacing: 0) {
                    EquationTerm(value: target, label: "目标")
                    EquationTerm(value: consumed, label: "已摄入")
                    EquationTerm(
                        value: summary.balance.map { abs($0.balanceKcal) },
                        label: (summary.balance?.balanceKcal ?? 0) > 0 ? "热量盈余" : "热量缺口"
                    )
                }
                EnergyExplanation(energy: energy, isToday: isToday)
            } else {
                // 固定目标已按每日总消耗（含活动）推算，运动消耗只作参考，不再加进“还可以吃”，避免重复计算。
                HStack(spacing: 0) {
                    EquationTerm(value: target, label: "目标")
                    EquationTerm(value: consumed, label: "已摄入")
                    EquationTerm(value: activeEnergy, label: "运动消耗")
                }
            }
            HStack {
                if summary.estimatedItemCount > 0 {
                    Label("其中 \(summary.estimatedItemCount) 项为 AI 估算", systemImage: "sparkles")
                        .font(VitaType.meta)
                        .foregroundStyle(VitaTheme.caution)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(VitaTheme.caution.opacity(0.12), in: .capsule)
                }
                Spacer()
                // 只在今天调整，避免从过去某天新建一个从那天起生效的目标。
                if isToday {
                    Button("调整目标", systemImage: "slider.horizontal.3", action: onSetGoal)
                        .font(VitaType.secondary.weight(.medium))
                }
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
            Text(unit).font(VitaType.body).foregroundStyle(.secondary)
        }
    }
}

/// 随活动计算的能量目标怎么来的：消耗 = 基础 + 活动，再减去缺口（或加上盈余）；运动比平时多时说明计入了多少。
private struct EnergyExplanation: View {
    let energy: EnergyTarget
    let isToday: Bool

    private func kcal(_ value: Decimal) -> String { DisplayFormat.number(value, digits: 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let adjustment = energy.adjustmentKcal
            let sign = adjustment < 0 ? "−" : "+"
            Text("消耗约 \(kcal(energy.tdeeKcal))（基础 \(kcal(energy.bmrKcal)) + 活动 \(kcal(energy.countedActivityKcal))）"
                 + (adjustment == 0 ? "" : " \(sign) \(adjustment < 0 ? "缺口" : "盈余") \(kcal(abs(adjustment)))"))
            if energy.projectedActivityKcal > energy.baselineActivityKcal {
                let extra = energy.projectedActivityKcal - energy.baselineActivityKcal
                Text("\(isToday ? "今天" : "这天")活动比平时多 \(kcal(extra))，计入一半 +\(kcal(energy.countedActivityKcal - energy.baselineActivityKcal))")
            } else if energy.activityEstimated {
                Text("没有读到\(isToday ? "今天" : "这天")的活动数据，按平时 \(kcal(energy.baselineActivityKcal)) 估计")
            } else if isToday {
                Text("今天的活动按已消耗加上剩余时段的平时水平估计，随实际消耗更新")
            }
            if energy.raisedToBMR {
                Text("目标不低于基础代谢，已按基础代谢计")
            }
        }
        .font(VitaType.meta)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            Text(label).font(VitaType.meta).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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
                    Text(nutrient.label).font(VitaType.body)
                    Text(progress.target.map { "目标 " + DisplayFormat.grams($0) } ?? "未设目标")
                        .font(VitaType.meta)
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
                InvitationCard(
                    symbol: "fork.knife",
                    tint: VitaTheme.intake,
                    title: "这一天还没有记录",
                    message: "在 Chat 里说说吃了什么，确认后显示在这里。"
                )
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
                if let sync = record.healthSync { HealthSyncBadge(state: sync) }
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
