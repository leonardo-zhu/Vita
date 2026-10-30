import SwiftUI

/// Chat / Data 双层导航。
struct RootView: View {
    let services: AppServices

    var body: some View {
        TabView {
            ChatView(services: services)
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            DataView(services: services)
                .tabItem { Label("Data", systemImage: "chart.bar") }
        }
        // 界面只有中文：系统控件（日期选择器等）也按中文显示，不跟随系统语言。
        .environment(\.locale, DisplayFormat.locale)
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
