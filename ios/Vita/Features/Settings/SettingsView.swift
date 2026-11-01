import SwiftUI

/// 设置：Conduit 访问令牌（只进 Keychain）、关于，以及连点版本号五次打开的本地调试覆盖（vita-admin.md §9）。
/// Conduit 地址来自构建配置，这里只展示、不能改（vita-admin.md §3.2）。
struct SettingsView: View {
    let services: AppServices
    /// 重新走一遍首次使用引导。
    var onReplayOnboarding: (() -> Void)?
    /// 清空数据之后重建界面，让各页面丢掉内存里的旧状态。
    var onDataReset: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    /// 令牌末四位，用来让用户认出是哪一把；nil 表示没有设置。
    @State private var tokenSuffix: String?
    @State private var isEditingToken = false
    @State private var isConfirmingRemoval = false
    @State private var message: String?
    @State private var versionTaps = 0
    @State private var showsDebug = false
    @State private var override = ConfigOverride()
    @State private var diagnosticsEnabled = true
    @State private var resetParts = DataResetPart.defaultSelection
    @State private var pendingReset: ResetRequest?

    private var secrets: any SecretStore { services.container.secrets }
    private var layered: LayeredConfigProvider? { services.container.config as? LayeredConfigProvider }
    private var diagnostics: DiagnosticsService? { services.container.diagnostics as? DiagnosticsService }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    serviceCard
                    if showsDebug {
                        debugCard
                        resetCard
                    }
                    aboutCard
                }
                .padding(16)
            }
            .background { VitaTheme.background }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .sheet(isPresented: $isEditingToken, onDismiss: loadToken) {
                TokenEntrySheet(isReplacing: tokenSuffix != nil) { token in
                    try secrets.write(token, for: .conduitToken)
                }
            }
            .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(message ?? "") }
        }
        .tint(VitaTheme.intake)
        .onAppear {
            loadToken()
            override = DebugOverrideStore.load() ?? ConfigOverride()
            showsDebug = override != ConfigOverride()
            diagnosticsEnabled = diagnostics?.isEnabled ?? false
        }
    }

    // MARK: - 模型服务

    private var serviceCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: tokenSuffix == nil ? "key.slash" : "key.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(
                        LinearGradient(colors: [statusTint.opacity(0.75), statusTint], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: .rect(cornerRadius: 13)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text("模型服务").font(VitaType.title)
                    if let tokenSuffix {
                        Label("已连接 · 令牌 ••••\(tokenSuffix)", systemImage: "checkmark.circle.fill")
                            .font(VitaType.secondary)
                            .foregroundStyle(VitaTheme.intake)
                    } else {
                        Label("还没有设置访问令牌", systemImage: "exclamationmark.circle")
                            .font(VitaType.secondary)
                            .foregroundStyle(VitaTheme.caution)
                    }
                }
                Spacer(minLength: 0)
            }
            if tokenSuffix == nil {
                Button { isEditingToken = true } label: {
                    Text("填写令牌").font(.body.weight(.semibold)).frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .glassButton(prominent: true)
            } else {
                HStack(spacing: 10) {
                    Button { isEditingToken = true } label: {
                        Text("更换令牌").frame(maxWidth: .infinity)
                    }
                    .glassButton()
                    Button(role: .destructive) { isConfirmingRemoval = true } label: {
                        Text("移除").frame(maxWidth: .infinity)
                    }
                    .glassButton()
                    .tint(.red)
                }
                .controlSize(.large)
                .confirmationDialog("移除令牌后将无法使用对话记录。", isPresented: $isConfirmingRemoval, titleVisibility: .visible) {
                    Button("移除令牌", role: .destructive, action: removeToken)
                }
            }
            Text("令牌只保存在本机钥匙串，不会写进日志。请求发往 \(services.container.environment.conduitBaseURL.host() ?? "")。")
                .font(VitaType.meta)
                .foregroundStyle(.secondary)
        }
        .vitaCard(padding: 20)
    }

    private var statusTint: Color { tokenSuffix == nil ? VitaTheme.caution : VitaTheme.protein }

    private func loadToken() {
        let token = (try? secrets.read(.conduitToken)) ?? nil
        tokenSuffix = token.flatMap { $0.isEmpty ? nil : String($0.suffix(4)) }
    }

    private func removeToken() {
        try? secrets.delete(.conduitToken)
        loadToken()
    }

    // MARK: - 调试覆盖

    private var debugCard: some View {
        let config = services.container.config.effectiveConfig()
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "调试覆盖", systemImage: "wrench.and.screwdriver", tint: VitaTheme.carbohydrate)
            SettingsField(
                title: "模型别名", source: Self.describe(config.source(of: .modelId)),
                placeholder: config.values.llm.modelId, text: binding(\.modelId)
            )
            SettingsField(
                title: "超时秒数", source: Self.describe(config.source(of: .timeoutSeconds)),
                placeholder: "\(config.values.llm.timeoutSeconds)",
                text: Binding(
                    get: { override.timeoutSeconds.map(String.init) ?? "" },
                    set: { override.timeoutSeconds = Int($0).flatMap { (5...300).contains($0) ? $0 : nil } }
                )
            )
            .keyboardType(.numberPad)
            VStack(alignment: .leading, spacing: 6) {
                fieldTitle("系统 prompt", source: Self.describe(config.source(of: .systemPrompt)))
                TextEditor(text: Binding(
                    get: { override.systemPromptText ?? config.values.prompts.system.text },
                    set: { override.systemPromptText = $0 == config.values.prompts.system.text ? nil : $0 }
                ))
                .font(VitaType.secondary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 160)
                .padding(8)
                .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 12))
            }
            HStack(spacing: 10) {
                Button { apply(override) } label: { Text("应用").frame(maxWidth: .infinity) }
                    .glassButton(prominent: true)
                Button(role: .destructive) {
                    override = ConfigOverride()
                    apply(nil)
                } label: { Text("全部清除").frame(maxWidth: .infinity) }
                    .glassButton()
            }
            Text("只保存在本机，下一轮对话开始时生效。")
                .font(VitaType.meta)
                .foregroundStyle(.secondary)
        }
        .vitaCard(padding: 20)
    }

    private func fieldTitle(_ title: String, source: String) -> some View {
        HStack {
            Text(title).font(VitaType.secondary.weight(.medium))
            Spacer()
            Text(source).font(VitaType.meta).foregroundStyle(.secondary)
        }
    }

    private func binding(_ keyPath: WritableKeyPath<ConfigOverride, String?>) -> Binding<String> {
        Binding(
            get: { override[keyPath: keyPath] ?? "" },
            set: { override[keyPath: keyPath] = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        )
    }

    private func apply(_ value: ConfigOverride?) {
        DebugOverrideStore.save(value)
        layered?.setOverride(DebugOverrideStore.load())
        message = value == nil ? "已清除，使用内置配置。" : "已应用。"
    }

    static func describe(_ source: ConfigSource) -> String {
        switch source {
        case .builtin: "内置"
        case .remote(let version): "远程 \(version)"
        case .localOverride: "本地覆盖"
        }
    }

    // MARK: - 清空数据

    private enum ResetRequest: Identifiable {
        case selected, everything
        var id: Self { self }
    }

    private var resetCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "清空数据", systemImage: "trash", tint: .red)
            ForEach(DataResetPart.allCases) { part in
                Toggle(isOn: Binding(
                    get: { resetParts.contains(part) },
                    set: { if $0 { resetParts.insert(part) } else { resetParts.remove(part) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.title(of: part)).font(VitaType.secondary.weight(.medium))
                        Text(Self.detail(of: part)).font(VitaType.meta).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 10) {
                Button(role: .destructive) { pendingReset = .selected } label: { Text("清空所选").frame(maxWidth: .infinity) }
                    .glassButton()
                    .disabled(resetParts.isEmpty)
                Button(role: .destructive) { pendingReset = .everything } label: { Text("全部清空").frame(maxWidth: .infinity) }
                    .glassButton(prominent: true)
            }
            .tint(.red)
            Text("“全部清空”相当于删掉重装：所有分组连同令牌和本机设置一起清掉。Apple 健康里的数据不动，已经写进去的饮食记录会留在“健康”里。")
                .font(VitaType.meta)
                .foregroundStyle(.secondary)
        }
        .vitaCard(padding: 20)
        .confirmationDialog(
            pendingReset == .everything ? "清空全部数据，回到刚安装时的状态？" : "清空所选的数据？",
            isPresented: Binding(get: { pendingReset != nil }, set: { if !$0 { pendingReset = nil } }),
            titleVisibility: .visible,
            presenting: pendingReset
        ) { request in
            Button(request == .everything ? "全部清空" : "清空", role: .destructive) { performReset(request) }
        } message: { request in
            Text("无法恢复。Apple 健康里的数据不受影响。")
        }
    }

    private func performReset(_ request: ResetRequest) {
        do {
            if request == .everything {
                try services.dataReset.resetEverything()
            } else {
                try services.dataReset.reset(resetParts)
            }
            if request == .everything || resetParts.contains(.debugOverride) {
                layered?.setOverride(nil)
            }
            dismiss()
            onDataReset?()
        } catch {
            message = "清空失败：\(error.localizedDescription)"
        }
    }

    static func title(of part: DataResetPart) -> String {
        switch part {
        case .records: "记录与对话"
        case .goals: "目标与引导"
        case .debugOverride: "调试覆盖"
        case .token: "Conduit 令牌"
        }
    }

    static func detail(of part: DataResetPart) -> String {
        switch part {
        case .records: "饮食记录、对话、确认卡、个人食品库、营养标签照片（Apple 健康里的不动）"
        case .goals: "每日目标、补录的身体数据；下次打开重走首次引导"
        case .debugOverride: "本地覆盖的模型别名、超时与 prompt"
        case .token: "清掉后需要重新填写"
        }
    }

    // MARK: - 关于

    private var aboutCard: some View {
        VStack(spacing: 0) {
            // 连点五次版本号打开调试覆盖。
            row("版本", AppVersion.current)
                .contentShape(.rect)
                .onTapGesture {
                    versionTaps += 1
                    if versionTaps >= 5 { withAnimation { showsDebug = true } }
                }
            Divider().padding(.vertical, 12)
            configRow
            if let diagnostics {
                Divider().padding(.vertical, 12)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("诊断日志", isOn: $diagnosticsEnabled)
                        .onChange(of: diagnosticsEnabled) { _, enabled in diagnostics.setEnabled(enabled) }
                    Text("只上报错误码、耗时与版本号，用来排查问题；不包含对话、饮食和健康数据。关掉后不再记录，还没发出的也会删掉。")
                        .font(VitaType.meta).foregroundStyle(.secondary)
                }
            }
            if let onReplayOnboarding {
                Divider().padding(.vertical, 12)
                Button {
                    dismiss()
                    onReplayOnboarding()
                } label: {
                    HStack {
                        Text("重新查看首次引导")
                        Spacer()
                        Image(systemName: "chevron.right").font(VitaType.meta.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .font(VitaType.body)
        .vitaCard(padding: 20)
    }

    /// 生效配置的版本与来源，以及远程配置上次检查的结果；点“刷新”立即检查一次（vita-admin.md §5）。
    private var configRow: some View {
        let effective = services.container.config.effectiveConfig()
        let remote = services.remoteConfig
        let isRemote = effective.sources.values.contains { if case .remote = $0 { true } else { false } }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("配置")
                Spacer()
                Text("\(effective.values.configVersion) · \(isRemote ? "远程" : "内置")")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            if let remote {
                HStack(spacing: 8) {
                    Text(Self.describe(remote))
                        .font(VitaType.meta).foregroundStyle(.secondary)
                    Spacer()
                    if remote.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("立即刷新") { Task { await remote.refresh() } }
                            .font(VitaType.meta.weight(.semibold))
                    }
                }
            }
        }
    }

    static func describe(_ remote: RemoteConfigService) -> String {
        let checked = remote.lastCheckedAt.map { "上次检查 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "还没检查过远程配置"
        switch remote.lastOutcome {
        case .updated(let version): return "已更新到 \(version)，下一轮对话生效"
        case .failed(let code): return "检查失败（\(code)），继续用当前配置"
        case .unchanged, nil: return checked
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// 卡片里的单行输入框：标题与来源在上，圆角输入框在下。
private struct SettingsField: View {
    let title: String
    let source: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(VitaType.secondary.weight(.medium))
                Spacer()
                Text(source).font(VitaType.meta).foregroundStyle(.secondary)
            }
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 12))
        }
    }
}

/// 填写或更换令牌。用系统的粘贴按钮读取剪贴板，不触发“允许粘贴”询问；默认遮盖，可切换显示。
private struct TokenEntrySheet: View {
    let isReplacing: Bool
    let save: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var reveals = false
    @State private var failed = false
    @FocusState private var focused: Bool

    private var trimmed: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("在 Conduit 的应用 Vita 里生成一把访问令牌，复制后粘贴到这里。")
                    .font(VitaType.body)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Group {
                        if reveals {
                            TextField("访问令牌", text: $token)
                        } else {
                            SecureField("访问令牌", text: $token)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .focused($focused)
                    Button(reveals ? "隐藏" : "显示", systemImage: reveals ? "eye.slash" : "eye") { reveals.toggle() }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 14))
                PasteButton(payloadType: String.self) { strings in
                    if let first = strings.first { token = first.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                .buttonBorderShape(.capsule)
                .labelStyle(.titleAndIcon)
                if failed {
                    Text("保存失败，请再试一次。").font(VitaType.secondary).foregroundStyle(VitaTheme.caution)
                }
                Spacer()
                Button {
                    do {
                        try save(trimmed)
                        dismiss()
                    } catch {
                        failed = true
                    }
                } label: {
                    Text(isReplacing ? "保存新令牌" : "保存").font(.body.weight(.semibold)).frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .glassButton(prominent: true)
                .disabled(trimmed.isEmpty)
            }
            .padding(20)
            .navigationTitle(isReplacing ? "更换令牌" : "填写令牌")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
        .tint(VitaTheme.intake)
        .presentationDetents([.medium])
        .onAppear { focused = true }
    }
}
