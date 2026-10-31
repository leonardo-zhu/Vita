import SwiftUI

/// 设置：Conduit 访问令牌（只进 Keychain）与隐藏的本地调试覆盖（vita-admin.md §9）。
/// Conduit 地址来自构建配置，这里只展示、不能改（vita-admin.md §3.2）。
struct SettingsView: View {
    let services: AppServices
    @Environment(\.dismiss) private var dismiss

    @State private var hasToken = false
    @State private var tokenDraft = ""
    @State private var message: String?
    @State private var versionTaps = 0
    @State private var showsDebug = false
    @State private var override = ConfigOverride()

    private var secrets: any SecretStore { services.container.secrets }
    private var layered: LayeredConfigProvider? { services.container.config as? LayeredConfigProvider }

    var body: some View {
        NavigationStack {
            Form {
                tokenSection
                if showsDebug { debugSection }
                aboutSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(message ?? "") }
        }
        .tint(VitaTheme.intake)
        .onAppear {
            hasToken = ((try? secrets.read(.conduitToken)) ?? nil)?.isEmpty == false
            override = DebugOverrideStore.load() ?? ConfigOverride()
            showsDebug = override != ConfigOverride()
        }
    }

    // MARK: - 令牌

    private var tokenSection: some View {
        Section {
            HStack {
                Text("状态")
                Spacer()
                Group {
                    Image(systemName: hasToken ? "checkmark.circle.fill" : "exclamationmark.circle")
                    Text(hasToken ? "已设置" : "未设置")
                }
                .foregroundStyle(hasToken ? VitaTheme.intake : VitaTheme.caution)
            }
            SecureField(hasToken ? "粘贴新令牌以替换" : "粘贴 Conduit 访问令牌", text: $tokenDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("保存令牌", action: saveToken)
                .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if hasToken {
                Button("删除令牌", role: .destructive, action: deleteToken)
            }
        } header: {
            Text("模型服务")
        } footer: {
            Text("令牌只保存在本机钥匙串，不会出现在日志里。请求发往 \(services.container.environment.conduitBaseURL.host() ?? "")。")
        }
    }

    private func saveToken() {
        let token = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try secrets.write(token, for: .conduitToken)
            tokenDraft = ""
            hasToken = true
        } catch {
            message = "保存失败，请再试一次。"
        }
    }

    private func deleteToken() {
        try? secrets.delete(.conduitToken)
        hasToken = false
    }

    // MARK: - 调试覆盖

    private var debugSection: some View {
        Section {
            let config = services.container.config.effectiveConfig()
            TextField("模型别名（\(config.values.llm.modelId)）", text: binding(\.modelId))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            LabeledContent("来源", value: Self.describe(config.source(of: .modelId)))
            TextField("超时秒数（\(config.values.llm.timeoutSeconds)）", text: Binding(
                get: { override.timeoutSeconds.map(String.init) ?? "" },
                set: { override.timeoutSeconds = Int($0).flatMap { (5...300).contains($0) ? $0 : nil } }
            ))
            .keyboardType(.numberPad)
            VStack(alignment: .leading) {
                Text("系统 prompt（\(Self.describe(config.source(of: .systemPrompt)))）").font(VitaType.meta).foregroundStyle(.secondary)
                TextEditor(text: Binding(
                    get: { override.systemPromptText ?? config.values.prompts.system.text },
                    set: { override.systemPromptText = $0 == config.values.prompts.system.text ? nil : $0 }
                ))
                .font(VitaType.secondary)
                .frame(minHeight: 160)
            }
            Button("应用覆盖") { apply(override) }
            Button("清除全部覆盖", role: .destructive) {
                override = ConfigOverride()
                apply(nil)
            }
        } header: {
            Text("调试覆盖")
        } footer: {
            Text("只保存在本机，下一轮对话开始时生效。")
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

    private static func describe(_ source: ConfigSource) -> String {
        switch source {
        case .builtin: "内置"
        case .remote(let version): "远程 \(version)"
        case .localOverride: "本地覆盖"
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            // 连点五次版本号打开调试覆盖。
            LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                .contentShape(.rect)
                .onTapGesture {
                    versionTaps += 1
                    if versionTaps >= 5 { withAnimation { showsDebug = true } }
                }
            LabeledContent("配置", value: services.container.config.effectiveConfig().values.configVersion)
        }
    }
}
