import SwiftUI

/// 第一次打开（或断开后）：填 Admin“设备”页签发的设备令牌，连上 Vita 服务。
struct ConnectView: View {
    let services: AppServices
    let onConnected: () -> Void

    var body: some View {
        NavigationStack {
            DeviceTokenForm(services: services, isReplacing: false) { _ in onConnected() }
                .navigationTitle("连接 Vita 服务")
                .navigationBarTitleDisplayMode(.inline)
        }
        .tint(VitaTheme.intake)
    }
}

/// 填写或更换设备令牌：先调 `/v1/me` 确认有效再存进钥匙串。用系统的粘贴按钮读剪贴板，不触发“允许粘贴”询问。
struct DeviceTokenForm: View {
    let services: AppServices
    let isReplacing: Bool
    /// 连上后回调设备名。
    let onConnected: (String) -> Void
    @State private var token = ""
    @State private var reveals = false
    @State private var isChecking = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    private var trimmed: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("在 Vita Admin 的“设备”页为这台手机签发一个令牌，复制后粘贴到这里。令牌只保存在本机钥匙串。")
                        .font(VitaType.body)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Group {
                            if reveals {
                                TextField("设备令牌", text: $token)
                            } else {
                                SecureField("设备令牌", text: $token)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(commit)
                        Button(reveals ? "隐藏" : "显示", systemImage: reveals ? "eye.slash" : "eye") { reveals.toggle() }
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.secondary)
                        PasteButton(payloadType: String.self) { strings in
                            if let first = strings.first { token = first.trimmingCharacters(in: .whitespacesAndNewlines) }
                        }
                        .labelStyle(.iconOnly)
                        .buttonBorderShape(.circle)
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, 6)
                    .padding(.vertical, 6)
                    .frame(minHeight: 48)
                    .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 14))
                    if let failure {
                        Text(failure).font(VitaType.secondary).foregroundStyle(VitaTheme.caution)
                    }
                    Text("服务地址：\(services.container.environment.apiBaseURL.host() ?? "")")
                        .font(VitaType.meta)
                        .foregroundStyle(.secondary)
                }
                .vitaCard()
                Button(action: commit) {
                    Group {
                        if isChecking {
                            ProgressView()
                        } else {
                            Text(isReplacing ? "验证并保存" : "连接").font(.body.weight(.semibold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .glassButton(prominent: true)
                .disabled(trimmed.isEmpty || isChecking)
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background { VitaTheme.background }
        .onAppear { focused = true }
    }

    private func commit() {
        guard !trimmed.isEmpty, !isChecking else { return }
        isChecking = true
        failure = nil
        Task {
            do {
                let name = try await services.connect(token: trimmed)
                onConnected(name)
            } catch let error as APIError {
                failure = error.userMessage
            } catch {
                failure = "保存失败，请再试一次。"
            }
            isChecking = false
        }
    }
}

/// 把 1.0 存在手机上的数据迁到服务端（架构设计 §13）。迁完、核对一致才删本机的库；不一致时什么都不删。
struct MigrationView: View {
    let migration: LegacyMigration
    let onFinished: () -> Void

    @State private var expected: LegacyMigration.Expected?
    @State private var step: LegacyMigration.Step?
    @State private var report: LegacyMigration.Report?
    @State private var failure: String?
    @State private var isRunning = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let report {
                        finished(report)
                    } else {
                        intro
                        if let step { progress(step) }
                        if let failure {
                            Text(failure)
                                .font(VitaType.secondary)
                                .foregroundStyle(VitaTheme.caution)
                                .padding(.horizontal, 4)
                        }
                    }
                }
                .padding(16)
            }
            .background { VitaTheme.background }
            .safeAreaInset(edge: .bottom) {
                Button(action: report == nil ? start : onFinished) {
                    Text(report == nil ? (failure == nil ? "开始迁移" : "重试") : "开始使用")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .glassButton(prominent: true)
                .disabled(isRunning)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .navigationTitle("迁移到 Vita 2.0")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(VitaTheme.intake)
        .interactiveDismissDisabled()
        .task { expected = try? migration.localTotals() }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "这台手机上的数据", systemImage: "iphone")
            Text("2.0 起数据存在你的 Vita 服务上，App 里改的、Admin 里改的都是同一份。迁移会把下面这些传上去，核对一致后才删掉手机上的这份；导出文件留在“文件”App 的 Vita 文件夹里。")
                .font(VitaType.body)
                .foregroundStyle(.secondary)
            if let expected {
                row("饮食记录", "\(expected.records) 条，\(expected.items) 项")
                row("记录的天数", "\(expected.dailyEnergy.count) 天")
                row("个人食品", "\(expected.products) 个，\(expected.versions) 个版本")
                row("每日目标", "\(expected.goals) 个")
                row("体脂秤称重", "\(expected.weighings) 次")
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            Text("Apple 健康里 Vita 写过的饮食与称重会换成带同步标识的新版本，数值不变。")
                .font(VitaType.meta)
                .foregroundStyle(.secondary)
        }
        .vitaCard(padding: 20)
    }

    private func progress(_ current: LegacyMigration.Step) -> some View {
        let steps: [(LegacyMigration.Step, String)] = [
            (.exporting, "整理本机数据"), (.uploading, "上传到服务端"), (.verifying, "核对条数与每日能量"),
            (.rewritingHealth, "更新 Apple 健康"), (.cleaningUp, "删除本机旧数据"),
        ]
        let index = steps.firstIndex { $0.0 == current } ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.offset) { offset, item in
                HStack(spacing: 8) {
                    if offset < index || (offset == index && failure == nil && report != nil) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(VitaTheme.intake)
                    } else if offset == index, failure != nil {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(VitaTheme.caution)
                    } else if offset == index {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "circle").foregroundStyle(.tertiary)
                    }
                    Text(item.1).foregroundStyle(offset <= index ? .primary : .secondary)
                }
                .font(VitaType.body)
            }
        }
        .vitaCard(padding: 20)
    }

    private func finished(_ report: LegacyMigration.Report) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "迁移完成", systemImage: "checkmark.seal.fill")
            row("饮食记录", "\(report.records) 条，\(report.items) 项")
            row("记录的天数", "\(report.days) 天")
            row("个人食品", "\(report.products) 个")
            row("对话消息", "\(report.messages) 条")
            row("体脂秤称重", "\(report.weighings) 次")
            Text("导出文件 \(report.exportFile?.lastPathComponent ?? "") 留在“文件”App → 我的 iPhone → Vita，建议至少保留一个月。")
                .font(VitaType.meta)
                .foregroundStyle(.secondary)
        }
        .vitaCard(padding: 20)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(VitaType.body)
    }

    private func start() {
        failure = nil
        step = .exporting
        isRunning = true
        Task {
            defer { isRunning = false }
            do {
                report = try await migration.run { step = $0 }
            } catch let error as LegacyMigration.MigrationError {
                failure = error.userMessage
            } catch let error as APIError {
                failure = error.userMessage
            } catch {
                failure = "迁移失败：\(error.localizedDescription)"
            }
        }
    }
}
