import SwiftUI

/// 设置：Vita 服务的设备令牌（只进 Keychain）与关于。服务地址来自构建配置，这里只展示、不能改（vita-admin.md §3.2）。
/// 数据都在服务端；要改数据或清数据去 Admin。
struct SettingsView: View {
    let services: AppServices
    /// 重新走一遍首次使用引导。
    var onReplayOnboarding: (() -> Void)?
    /// 断开设备之后重建界面，回到连接页。
    var onDataReset: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    /// 令牌末四位，用来让用户认出是哪一把；nil 表示没有设置。
    @State private var tokenSuffix: String?
    @State private var isEditingToken = false
    @State private var isConfirmingDisconnect = false
    @State private var message: String?
    @State private var isResyncing = false


    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    serviceCard
                    healthCard
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
            // 在设置里推入一页，不再叠一层弹窗（叠在设置弹窗上会被键盘挡住、中间空一大块）。
            .navigationDestination(isPresented: $isEditingToken) {
                DeviceTokenForm(services: services, isReplacing: true) { name in
                    isEditingToken = false
                    loadToken()
                    message = "已连接为“\(name)”。"
                }
                .navigationTitle("更换令牌")
                .navigationBarTitleDisplayMode(.inline)
            }
            .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(message ?? "") }
        }
        .tint(VitaTheme.intake)
        .onAppear {
            loadToken()
        }
    }

    // MARK: - Vita 服务

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
                    Text("Vita 服务").font(VitaType.title)
                    if let tokenSuffix {
                        Label("已连接 · 令牌 ••••\(tokenSuffix)", systemImage: "checkmark.circle.fill")
                            .font(VitaType.secondary)
                            .foregroundStyle(VitaTheme.intake)
                    } else {
                        Label("还没有设备令牌", systemImage: "exclamationmark.circle")
                            .font(VitaType.secondary)
                            .foregroundStyle(VitaTheme.caution)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Button { isEditingToken = true } label: {
                    Text("更换令牌").frame(maxWidth: .infinity)
                }
                .glassButton()
                Button(role: .destructive) { isConfirmingDisconnect = true } label: {
                    Text("断开").frame(maxWidth: .infinity)
                }
                .glassButton()
                .tint(.red)
            }
            .controlSize(.large)
            .confirmationDialog("断开后这台手机要重新填写令牌才能使用。服务端的数据和 Apple 健康里的都不受影响。", isPresented: $isConfirmingDisconnect, titleVisibility: .visible) {
                Button("断开这台设备", role: .destructive, action: disconnect)
            }
            Text("令牌只保存在本机钥匙串，不会写进日志。数据存在 \(services.container.environment.apiBaseURL.host() ?? "")；要修改或清空数据，请到 Vita Admin。")
                .font(VitaType.meta)
                .foregroundStyle(.secondary)
        }
        .vitaCard(padding: 20)
    }

    private var statusTint: Color { tokenSuffix == nil ? VitaTheme.caution : VitaTheme.protein }

    private func loadToken() {
        let token = (try? services.container.secrets.read(.deviceToken)) ?? nil
        tokenSuffix = token.flatMap { $0.isEmpty ? nil : String($0.suffix(4)) }
    }

    private func disconnect() {
        do {
            try services.dataReset.disconnect()
            dismiss()
            onDataReset?()
        } catch {
            message = "断开失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Apple 健康

    /// 健康里少了数据（比如授权后）时，从头重新同步一遍：按同步标识覆盖，不会重复。
    private var healthCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "Apple 健康", systemImage: "heart.fill", tint: .pink)
            Text("确认过的饮食记录和体脂秤称重会写进 Apple 健康。改了授权或健康里少了数据时，可以从头同步一遍，已有的会被覆盖、不会重复。")
                .font(VitaType.meta)
                .foregroundStyle(.secondary)
            Button {
                isResyncing = true
                Task {
                    services.healthSync.resetCursor()
                    let result = await services.healthSync.run()
                    isResyncing = false
                    message = result.waitingForPermission > 0
                        ? "已同步 \(result.synced) 项，另有 \(result.waitingForPermission) 项需要在“健康”App 里允许 Vita 写入。"
                        : result.failed > 0 ? "已同步 \(result.synced) 项，\(result.failed) 项失败，稍后会自动重试。" : "已同步 \(result.synced) 项。"
                }
            } label: {
                Group {
                    if isResyncing { ProgressView() } else { Text("重新同步") }
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .glassButton()
            .disabled(isResyncing)
        }
        .vitaCard(padding: 20)
    }

    // MARK: - 关于

    private var aboutCard: some View {
        VStack(spacing: 0) {
            row("版本", AppVersion.display)
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

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
