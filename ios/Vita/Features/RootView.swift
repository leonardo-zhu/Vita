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
