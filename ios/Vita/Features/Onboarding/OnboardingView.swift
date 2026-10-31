import SwiftUI

/// 首次使用引导（PRD §3.7）：欢迎 → 连接 Apple 健康 → 生成每日目标 → 完成。每一步都能跳过；
/// 跳过时目标为空，之后在 Data 页或对话里再设。个人食品库不强制录入，只在完成页说明入口。
struct OnboardingView: View {
    let services: AppServices
    let onFinish: () -> Void

    private enum Step: Int, CaseIterable {
        case welcome, health, goal, done
    }

    @State private var step: Step = .welcome
    @State private var healthNote: String?
    @State private var isRequestingHealth = false
    @State private var goalSet = false

    private var today: LocalDate { LocalDate(date: Date(), timeZone: .current) }
    /// 不支持 Apple 健康的设备跳过这一步。
    private var steps: [Step] { Step.allCases.filter { $0 != .health || services.health.isAvailable } }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                switch step {
                case .welcome: welcome.transition(.pageForward)
                case .health: health.transition(.pageForward)
                case .goal: goal.transition(.pageForward)
                case .done: done.transition(.pageForward)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background { VitaTheme.background }
        .tint(VitaTheme.intake)
    }

    private func advance() {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        withAnimation(.smooth(duration: 0.35)) { step = steps[index + 1] }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(steps, id: \.self) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? VitaTheme.intake : Color.primary.opacity(0.12))
                        .frame(width: item == step ? 22 : 8, height: 8)
                }
            }
            .animation(.smooth, value: step)
            Spacer()
            if step != .done {
                Button("跳过", action: onFinish)
                    .font(VitaType.body)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .frame(height: 44)
    }

    // MARK: - 欢迎

    private var welcome: some View {
        page {
            Spacer(minLength: 24)
            HeroIcon(symbol: "fork.knife", tint: VitaTheme.intake)
            VStack(alignment: .leading, spacing: 8) {
                Text("你好，我是 Vita").font(.largeTitle.weight(.bold))
                Text("你的 AI 饮食与健康助理。说说吃了什么，我来算营养、对照目标。")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 18) {
                FeatureRow(symbol: "text.bubble", tint: VitaTheme.protein, title: "说一句就能记", detail: "不用逐项填表，像聊天一样描述就行。")
                FeatureRow(symbol: "checkmark.seal", tint: VitaTheme.intake, title: "确认后才保存", detail: "每次新增、修改或删除都先给你看确认卡。")
                FeatureRow(symbol: "lock.shield", tint: VitaTheme.carbohydrate, title: "数据留在本机", detail: "记录只存在这台设备。Apple 健康的身体数据只读取，饮食在你确认后才写回。")
            }
            .padding(.top, 8)
            Spacer()
        } actions: {
            primaryButton("开始", action: advance)
        }
    }

    // MARK: - Apple 健康

    private var health: some View {
        page {
            Spacer(minLength: 24)
            HeroIcon(symbol: "heart.fill", tint: .pink)
            VStack(alignment: .leading, spacing: 8) {
                Text("连接 Apple 健康").font(.largeTitle.weight(.bold))
                Text("用身体数据生成目标，确认的饮食也会同步过去。")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 12) {
                PermissionGroup(symbol: "arrow.down.circle.fill", tint: VitaTheme.protein, title: "读取", items: "身高、体重、体脂率、出生日期、生理性别、睡眠、活动能量")
                PermissionGroup(symbol: "arrow.up.circle.fill", tint: VitaTheme.intake, title: "写入", items: "确认后的膳食能量、蛋白质、脂肪、碳水")
            }
            if let healthNote {
                Label(healthNote, systemImage: "info.circle")
                    .font(VitaType.secondary)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(VitaTheme.caution.opacity(0.1), in: .rect(cornerRadius: 16))
                    .transition(.opacity)
            }
            Spacer()
        } actions: {
            if healthNote == nil {
                primaryButton(isRequestingHealth ? "等待授权…" : "连接 Apple 健康", action: connectHealth)
                    .disabled(isRequestingHealth)
                secondaryButton("暂不连接", action: advance)
            } else {
                primaryButton("继续", action: advance)
            }
        }
    }

    /// 被拒绝也不阻塞：说明之后在哪里打开，然后继续（PRD §3.7）。
    private func connectHealth() {
        isRequestingHealth = true
        Task {
            try? await services.health.requestAuthorization()
            let snapshot = await services.health.snapshot(on: today)
            isRequestingHealth = false
            if snapshot.accessLikelyDenied || snapshot.writeDenied {
                withAnimation {
                    healthNote = "没有获得全部权限也没关系，可以之后在“\(HealthApp.permissionPath)”里打开。缺少的身体数据下一步可以手动补。"
                }
            } else {
                advance()
            }
        }
    }

    // MARK: - 目标

    private var goal: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("生成每日目标").font(.largeTitle.weight(.bold))
                Text("按身体数据算出能量和蛋白质目标；缺的数据点一下就能补。")
                    .font(VitaType.body)
                    .foregroundStyle(.secondary)
                Button("稍后再设", action: advance)
                    .font(VitaType.body.weight(.medium))
                    .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            GoalSetupForm(services: services, date: today) {
                goalSet = true
                advance()
            }
        }
    }

    // MARK: - 完成

    private var done: some View {
        page {
            Spacer(minLength: 24)
            HeroIcon(symbol: "checkmark", tint: VitaTheme.intake)
            VStack(alignment: .leading, spacing: 8) {
                Text("准备好了").font(.largeTitle.weight(.bold))
                Text(goalSet ? "每日目标已保存。接下来就从第一餐开始吧。" : "目标可以随时在 Data 页生成，或在对话里请 Vita 帮你设。")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 18) {
                FeatureRow(symbol: "bubble.left.and.bubble.right", tint: VitaTheme.protein, title: "在 Chat 里记录", detail: "比如“中午吃了 200g 鸡胸肉和一碗米饭”。")
                FeatureRow(symbol: "chart.bar", tint: VitaTheme.intake, title: "在 Data 里查看", detail: "每天的摄入、目标进度和一周趋势。")
                FeatureRow(symbol: "books.vertical", tint: VitaTheme.fat, title: "常吃的食品慢慢攒", detail: "不用现在录入。之后在对话里说“把这个牛奶存起来”，就会进个人食品库。")
            }
            .padding(.top, 8)
            Spacer()
        } actions: {
            primaryButton("开始使用", action: onFinish)
        }
    }

    // MARK: - 版式

    private func page<Content: View, Actions: View>(
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            VStack(spacing: 10) { actions() }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.body.weight(.semibold)).frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .glassButton(prominent: true)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(VitaType.body.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 36)
    }
}

/// 每页顶部的大图标。
private struct HeroIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 36, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 80, height: 80)
            .background(
                LinearGradient(colors: [tint.opacity(0.7), tint], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: .rect(cornerRadius: 24)
            )
            .shadow(color: tint.opacity(0.3), radius: 16, y: 8)
    }
}

private struct FeatureRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.14), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(VitaType.title)
                Text(detail).font(VitaType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PermissionGroup: View {
    let symbol: String
    let tint: Color
    let title: String
    let items: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(VitaType.title)
                Text(items).font(VitaType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .vitaCard(padding: 16)
    }
}

private extension AnyTransition {
    /// 新页从右边进、旧页向左出。
    static var pageForward: AnyTransition {
        .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity))
    }
}
