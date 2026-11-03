import SwiftUI

/// 健康仪表盘（PRD §3.5 Health）：只展示 PRD 读取范围内的数据，并区分未连接、无数据、读取失败与有数据（TDD §6.1）。
struct HealthSection: View {
    let snapshot: HealthSnapshot?
    let isAvailable: Bool
    let onConnect: () -> Void
    let onWeigh: () -> Void

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("健康").font(.title3.weight(.semibold))
                Spacer()
                Button("身体成分", systemImage: "scalemass", action: onWeigh)
                    .font(VitaType.body.weight(.medium))
            }
            .padding(.horizontal, 4)
            if !isAvailable {
                Text("这台设备不支持 Apple 健康。")
                    .font(VitaType.body)
                    .foregroundStyle(.secondary)
                    .vitaCard()
            } else if let snapshot, !snapshot.authorizationRequested {
                connectCard
            } else if let snapshot, snapshot.accessLikelyDenied {
                deniedCard
            } else if let snapshot {
                if snapshot.writeDenied { writeDeniedNotice }
                LazyVGrid(columns: columns, spacing: 12) {
                    MetricCard(title: "体重", symbol: "scalemass.fill", tint: VitaTheme.protein,
                               reading: snapshot.bodyMassKg, format: { DisplayFormat.number($0, digits: 1) }, unit: "kg",
                               footnote: snapshot.bmi.map { "BMI " + DisplayFormat.number($0, digits: 1) })
                    MetricCard(title: "体脂率", symbol: "figure", tint: VitaTheme.fat,
                               reading: snapshot.bodyFatFraction, format: { DisplayFormat.number($0 * 100, digits: 1) }, unit: "%")
                    MetricCard(title: "睡眠", symbol: "bed.double.fill", tint: VitaTheme.carbohydrate,
                               reading: snapshot.sleepHours, format: { DisplayFormat.number($0, digits: 1) }, unit: "小时",
                               footnote: "前一晚")
                    MetricCard(title: "活动消耗", symbol: "flame.fill", tint: VitaTheme.caution,
                               reading: snapshot.activeEnergyKcal, format: { DisplayFormat.number($0, digits: 0) }, unit: "千卡",
                               footnote: "当天")
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
        }
    }

    private var connectCard: some View {
        InvitationCard(
            symbol: "heart.fill",
            tint: .pink,
            title: "连接 Apple 健康",
            message: "读取体重、睡眠和活动，并把确认的饮食和体脂秤称重写回健康。",
            actionTitle: "连接 Apple 健康",
            action: onConnect
        )
    }

    /// 点了“不允许”：iOS 不会再次弹出授权框，只能去健康 App 里打开（PRD §3.3 权限处理）。
    private var deniedCard: some View {
        InvitationCard(
            symbol: "heart.slash.fill",
            tint: VitaTheme.caution,
            title: "没有 Apple 健康权限",
            message: "到“\(HealthApp.permissionPath)”里打开需要的项目。",
            actionTitle: "打开健康 App",
            action: HealthApp.open
        )
    }

    private var writeDeniedNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "heart.slash").foregroundStyle(VitaTheme.caution)
            Text("没有允许写入，饮食记录不会同步到 Apple 健康。").font(VitaType.secondary).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("打开健康", action: HealthApp.open).font(VitaType.secondary.weight(.semibold))
        }
        .vitaCard(padding: 14)
    }
}

private struct MetricCard<Value: Equatable & Codable & Sendable>: View {
    let title: String
    let symbol: String
    let tint: Color
    let reading: HealthReading<Value>
    let format: (Value) -> String
    let unit: String
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(VitaType.body.weight(.medium))
                .foregroundStyle(tint)
            switch reading {
            case .value(let value, let source, let measuredAt):
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(format(value)).font(.title2.weight(.semibold)).monospacedDigit()
                    Text(unit).font(VitaType.meta).foregroundStyle(.secondary)
                }
                Text([footnote, source == .manual ? "手动补录" : measuredAt.map(DisplayFormat.relativeDay)].compactMap { $0 }.joined(separator: " · "))
                    .font(VitaType.meta)
                    .foregroundStyle(.secondary)
            case .noData:
                Text("--").font(.title2.weight(.semibold)).foregroundStyle(.tertiary)
                Text("暂无数据").font(VitaType.meta).foregroundStyle(.secondary)
            case .failed:
                Text("--").font(.title2.weight(.semibold)).foregroundStyle(.tertiary)
                Text("读取失败").font(VitaType.meta).foregroundStyle(VitaTheme.caution)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(VitaTheme.card, in: .rect(cornerRadius: 22))
        .shadow(color: .black.opacity(0.04), radius: 12, y: 4)
    }
}

/// 记录卡上的 Apple 健康同步标记：已同步、待同步、可重试、需要用户处理是不同状态（TDD §4.1）。
struct HealthSyncBadge: View {
    let state: SyncState

    var body: some View {
        Image(systemName: symbol)
            .font(.caption)
            .foregroundStyle(tint)
            .accessibilityLabel(label)
    }

    private var symbol: String {
        switch state {
        case .synced: "heart.fill"
        case .pending: "heart"
        case .failedRetryable: "arrow.clockwise.heart"
        case .requiresUserResolution: "heart.slash"
        }
    }

    private var tint: Color {
        switch state {
        case .synced: .pink
        case .pending: .secondary
        case .failedRetryable, .requiresUserResolution: VitaTheme.caution
        }
    }

    var label: String {
        switch state {
        case .synced: "已同步到 Apple 健康"
        case .pending: "等待同步到 Apple 健康"
        case .failedRetryable: "同步失败，稍后重试"
        case .requiresUserResolution: "没有写入 Apple 健康的权限"
        }
    }
}
