import SwiftUI

/// 身体成分（身体成分模块 §6）：打开即找秤，先同步秤里的离线记录，称重锁定后存下并写入 Apple 健康
/// （没允许时存为手动补录）；下面是全部称重历史，可删除（连同健康里的那份）。
struct BodyCompositionView: View {
    let services: AppServices

    @State private var connection = ScaleConnection()
    @State private var profile: HealthSnapshot?
    @State private var latest: Latest?
    @State private var history: [BodyWeighing] = []
    @State private var syncedCount = 0
    @State private var manualCount = 0
    @State private var pendingDeletion: BodyWeighing?
    @State private var message: String?

    /// 这次打开页面后站上去称的那一次。
    private struct Latest {
        let measurement: ScaleMeasurement
        var weighing: BodyWeighing?
        var destination: ScaleSaveDestination?
        var errorMessage: String?
        var canRetry = false
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                weightCard
                if let latest { resultCard(latest) }
                if syncedCount > 0 { syncedNotice }
                historySection
            }
            .padding(16)
        }
        .background { VitaTheme.background }
        .navigationTitle("身体成分")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if connection.phase == .finished {
                Button(action: weighAgain) {
                    Text("再称一次").font(.body.weight(.semibold)).frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .glassButton()
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .confirmationDialog(
            "删除这次称重？", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible, presenting: pendingDeletion
        ) { weighing in
            Button("删除", role: .destructive) { Task { await delete(weighing) } }
        } message: { weighing in
            Text(weighing.inAppleHealth ? "Apple 健康里的这次体重和体脂率也会一起删除。" : "只删除 Vita 里的记录。")
        }
        .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: {
            Text(message ?? "")
        }
        .task {
            reloadHistory()
            await services.bodyComposition.prepareHealthWrite()
            connection.onFinal = { measurement in Task { await save(measurement) } }
            connection.onOfflineRecord = { await saveOffline($0) }
            connection.start()
            profile = await services.health.snapshot(on: LocalDate(date: Date(), timeZone: .current))
            connection.user = profile.flatMap(scaleUser)
        }
        .onDisappear { connection.stop() }
    }

    // MARK: - 称重

    private var weightCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "scalemass.fill").font(.title).foregroundStyle(VitaTheme.protein)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(connection.live.map { DisplayFormat.number($0.weightKg, digits: 2) } ?? "--")
                    .font(.system(size: 52, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(connection.live == nil ? .tertiary : .primary)
                Text("kg").font(.title3).foregroundStyle(.secondary)
            }
            .animation(.snappy, value: connection.live?.weightKg)
            HStack(spacing: 6) {
                if [.searching, .connecting].contains(connection.phase) { ProgressView().controlSize(.small) }
                Text(statusText).font(VitaType.body).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .vitaCard()
    }

    private var statusText: String {
        if connection.seemsBusy, [.searching, .connecting].contains(connection.phase) {
            return "连不上秤：它可能正连着蚂蚁阿福等其他 App，请先把那个 App 关掉"
        }
        return switch connection.phase {
        case .idle: "准备中"
        case .unavailable(let reason): reason
        case .searching: "正在找秤，请踩一下秤面唤醒"
        case .connecting: "找到秤，正在连接"
        case .waiting: connection.live?.isStable == true ? "读数稳定，正在测量体脂" : "已连接，请光脚站上去"
        case .finished: "称重完成"
        }
    }

    private func resultCard(_ latest: Latest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                metric("体重", DisplayFormat.number(latest.weighing?.weightKg ?? latest.measurement.weightKg, digits: 2), "kg")
                metric("体脂率", latest.weighing?.bodyFatFraction.map { DisplayFormat.number($0 * 100, digits: 1) } ?? "--", "%")
                metric("BMI", latest.weighing?.bmi.map { DisplayFormat.number($0, digits: 1) } ?? "--", "")
            }
            if let weighing = latest.weighing, weighing.bodyFatFraction == nil {
                Text(weighing.impedance == nil
                     ? "没测到阻抗，这次只记体重。光脚站稳、等秤显示完成再下秤。"
                     : "缺少身高、出生日期或性别，无法估算体脂率。可在“每日目标”里补录。")
                    .font(VitaType.secondary)
                    .foregroundStyle(.secondary)
            }
            Divider()
            saveStatus(latest)
        }
        .vitaCard()
    }

    @ViewBuilder
    private func saveStatus(_ latest: Latest) -> some View {
        if let errorMessage = latest.errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(VitaTheme.caution)
                if latest.canRetry { Button("重试") { Task { await save(latest.measurement) } }.glassButton() }
            }
            .font(VitaType.secondary)
        } else {
            switch latest.destination {
            case .appleHealth:
                Label("已写入 Apple 健康", systemImage: "heart.fill").foregroundStyle(.pink)
            case .manual:
                manualHint
            case nil:
                Label("正在保存", systemImage: "arrow.down.circle").foregroundStyle(.secondary)
            }
        }
    }

    /// iOS 不会再次弹出授权，只能去健康 App 里打开。
    private var manualHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("没有写入 Apple 健康的权限，已存为手动补录，只用于生成目标。可在\(HealthApp.permissionPath) 里打开体重和体脂率。", systemImage: "heart.slash")
                .foregroundStyle(.secondary)
            Button("打开健康", action: HealthApp.open).font(VitaType.secondary.weight(.semibold))
        }
        .font(VitaType.secondary)
    }

    private var syncedNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("已同步秤里的 \(syncedCount) 条离线记录", systemImage: "arrow.down.circle.fill")
                .font(VitaType.body.weight(.medium))
                .foregroundStyle(VitaTheme.protein)
            if latest == nil, manualCount > 0 { manualHint }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .vitaCard(padding: 14)
    }

    // MARK: - 历史

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("称重记录").font(.title3.weight(.semibold)).padding(.horizontal, 4)
            if history.isEmpty {
                Text("还没有称重记录。").font(VitaType.body).foregroundStyle(.secondary).vitaCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(history.enumerated()), id: \.element.id) { index, weighing in
                        if index > 0 { Divider() }
                        historyRow(weighing)
                    }
                }
                .vitaCard(padding: 0)
                if history.contains(where: { !$0.timeReliable }) {
                    Text("标“同步”的是 Vita 校准秤的时钟之前存下的离线记录，没有可靠的称重时间，按同步时间保存。")
                        .font(VitaType.secondary)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    private func historyRow(_ weighing: BodyWeighing) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(weighing.measuredAt, format: .dateTime.month().day()).font(VitaType.body.weight(.medium))
                Text(weighing.timeReliable ? weighing.measuredAt.formatted(.dateTime.hour().minute()) : "同步")
                    .font(VitaType.meta)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 64, alignment: .leading)
            Text("\(DisplayFormat.number(weighing.weightKg, digits: 2)) kg").monospacedDigit()
            if let fat = weighing.bodyFatFraction {
                Text("体脂 \(DisplayFormat.number(fat * 100, digits: 1))%").monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: weighing.inAppleHealth ? "heart.fill" : "heart.slash")
                .foregroundStyle(weighing.inAppleHealth ? AnyShapeStyle(.pink) : AnyShapeStyle(.tertiary))
                .accessibilityLabel(weighing.inAppleHealth ? "已写入 Apple 健康" : "未写入 Apple 健康")
            Menu("更多", systemImage: "ellipsis") {
                Button("删除", systemImage: "trash", role: .destructive) { pendingDeletion = weighing }
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(.secondary)
        }
        .font(VitaType.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func metric(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(VitaType.meta).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                Text(unit).font(VitaType.meta).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 动作

    /// 秤要整数身高和年龄；缺任何一项就不下发用户。
    private func scaleUser(_ profile: HealthSnapshot) -> ScaleCommand.User? {
        guard let height = profile.heightCm.value, let weight = profile.bodyMassKg.value,
              let birth = profile.dateOfBirth.value, let sex = profile.sex.value, sex != .other else { return nil }
        let age = GoalRecommendationPolicy.age(of: birth, on: LocalDate(date: Date(), timeZone: .current))
        return .init(heightCm: NSDecimalNumber(decimal: height).intValue, weightKg: weight, ageYears: age, isMale: sex == .male)
    }

    /// 健康数据还没读完时先补读，体脂率要用身高、年龄、性别。
    private func loadProfile() async -> HealthSnapshot {
        if let profile { return profile }
        let loaded = await services.health.snapshot(on: LocalDate(date: Date(), timeZone: .current))
        profile = loaded
        return loaded
    }

    private func save(_ measurement: ScaleMeasurement) async {
        latest = Latest(measurement: measurement)
        do {
            let (weighing, destination) = try await services.bodyComposition.record(measurement, source: .live, profile: await loadProfile())
            latest?.weighing = weighing
            latest?.destination = destination
        } catch HealthServiceError.invalidMetrics {
            latest?.errorMessage = "读数超出正常范围，没有保存。"
        } catch {
            latest?.errorMessage = "保存失败。"
            latest?.canRetry = true
        }
        reloadHistory()
    }

    /// 返回 true 时秤会删掉这条：存好了，或读数异常（留着会一直挡住后面的记录）。
    private func saveOffline(_ record: ScaleOfflineRecord) async -> Bool {
        do {
            let (_, destination) = try await services.bodyComposition.record(
                record.measurement, recordedAt: record.recordedAt, source: .offline, profile: await loadProfile()
            )
            syncedCount += 1
            if destination == .manual { manualCount += 1 }
            reloadHistory()
            return true
        } catch HealthServiceError.invalidMetrics {
            return true
        } catch {
            return false
        }
    }

    private func delete(_ weighing: BodyWeighing) async {
        do {
            if try await services.bodyComposition.delete(weighing.id) == .keptInAppleHealth {
                message = "已从 Vita 删除。没有 Apple 健康的写入权限，健康里的这次记录需要到健康 App 里手动删除。"
            }
        } catch {
            message = "删除失败，请稍后再试。"
        }
        reloadHistory()
    }

    private func reloadHistory() {
        history = (try? services.bodyComposition.weighings()) ?? []
    }

    private func weighAgain() {
        latest = nil
        connection.start()
    }
}
