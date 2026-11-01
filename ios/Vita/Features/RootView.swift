import SwiftUI

/// 首次引导是否已完成（或被跳过）。设置里的“重新查看首次引导”会把它清掉。
enum OnboardingState {
    static let key = "vita.onboarding.completed"
}

/// Chat / Data 双层导航。首次打开时盖上 Onboarding。
struct RootView: View {
    let services: AppServices
    @AppStorage(OnboardingState.key) private var onboardingCompleted = false
    /// 清空数据后递增，整棵界面重建。
    @State private var resetGeneration = 0

    var body: some View {
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
        .onAppear {
            // 已经在用的人（已有目标）不再看引导。
            if !onboardingCompleted, (try? services.goals.activeGoal(on: LocalDate(date: Date(), timeZone: .current))) != nil {
                onboardingCompleted = true
            }
        }
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

#if DEBUG
#Preview("Vita") {
    RootView(services: SampleData.previewServices())
}
#endif
