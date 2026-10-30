import SwiftUI

/// Chat / Data 双层导航。Chat 随 Phase 5 实现。
struct RootView: View {
    let services: AppServices

    var body: some View {
        TabView {
            PlaceholderScreen(title: "Chat")
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            DataView(service: services.dayData)
                .tabItem { Label("Data", systemImage: "chart.bar") }
        }
    }
}

private struct PlaceholderScreen: View {
    let title: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView(title, systemImage: "hammer", description: Text("尚未实现"))
                .navigationTitle(title)
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
