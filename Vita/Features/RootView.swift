import SwiftUI

/// Chat / Data 双层导航的占位骨架（Phase 5 实现）。
struct RootView: View {
    var body: some View {
        TabView {
            PlaceholderScreen(title: "Chat")
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            PlaceholderScreen(title: "Data")
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
            "无法打开本地数据库",
            systemImage: "exclamationmark.triangle",
            description: Text(String(describing: error))
        )
    }
}
