import SwiftUI

/// 首次引导是否已完成（或被跳过）。设置里的“重新查看首次引导”会把它清掉。
enum OnboardingState {
    static let key = "vita.onboarding.completed"
}

/// 启动时先看这台设备连上 Vita 服务没有、1.0 的数据迁走没有，都好了才进 Chat / Data 双层导航。
/// 首次打开时再盖上 Onboarding。
struct RootView: View {
    let services: AppServices
    @AppStorage(OnboardingState.key) private var onboardingCompleted = false
    /// 断开设备或清空后递增，整棵界面重建。
    @State private var resetGeneration = 0
    @State private var phase: Phase?

    private enum Phase {
        case connect
        case migrate(LegacyMigration)
        case ready
        case failed(String)
    }

    var body: some View {
        Group {
            switch phase {
            case nil:
                ProgressView()
            case .connect:
                ConnectView(services: services) { Task { await evaluate() } }
            case .migrate(let migration):
                MigrationView(migration: migration) { Task { await evaluate() } }
            case .failed(let message):
                ContentUnavailableView("无法打开 1.0 的数据", systemImage: "exclamationmark.triangle", description: Text(message))
            case .ready:
                tabs
            }
        }
        .environment(\.locale, DisplayFormat.locale)
        .task(id: resetGeneration) { await evaluate() }
    }

    private var tabs: some View {
        TabView {
            ChatView(services: services) { resetGeneration += 1 }
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            DataView(services: services)
                .tabItem { Label("Data", systemImage: "chart.bar") }
        }
        .id(resetGeneration)
        // 界面只有中文：系统控件（日期选择器等）也按中文显示，不跟随系统语言。
        .environment(\.locale, DisplayFormat.locale)
        .fullScreenCover(isPresented: Binding(get: { !onboardingCompleted }, set: { if !$0 { onboardingCompleted = true } })) {
            OnboardingView(services: services) { onboardingCompleted = true }
                .environment(\.locale, DisplayFormat.locale)
        }
    }

    private func evaluate() async {
        guard services.isConnected else {
            phase = .connect
            return
        }
        do {
            if let migration = try services.legacyMigration() {
                if try migration.isEmpty() {
                    // 装过 1.0 但没记过东西：没什么可迁的，直接删掉旧库。
                    try migration.discardEmptyStore()
                } else {
                    phase = .migrate(migration)
                    return
                }
            }
        } catch {
            phase = .failed(String(describing: error))
            return
        }
        // 已经在用的人（服务端已有目标）不再看引导。
        if !onboardingCompleted, (try? await services.goals.activeGoal(on: LocalDate(date: Date(), timeZone: .current))) != nil {
            onboardingCompleted = true
        }
        phase = .ready
    }
}

struct StartupFailureView: View {
    let error: Error

    var body: some View {
        ContentUnavailableView(
            "无法启动 Vita",
            systemImage: "exclamationmark.triangle",
            description: Text(String(describing: error))
        )
    }
}
