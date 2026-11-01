import SwiftData
import SwiftUI

@main
struct VitaApp: App {
    private let bootstrap: Result<AppServices, Error>
    @Environment(\.scenePhase) private var scenePhase

    init() {
        bootstrap = Result { AppServices(container: try AppContainer.live()) }
        #if DEBUG
        if case .success(let services) = bootstrap, ProcessInfo.processInfo.arguments.contains(SampleData.launchArgument) {
            try? SampleData.seedToday(services)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            switch bootstrap {
            case .success(let services):
                RootView(services: services)
                    .modelContainer(services.container.modelContainer)
                    // 启动和每次回到前台都检查一次远程配置（vita-admin.md §5），不阻塞界面
                    .onChange(of: scenePhase, initial: true) { _, phase in
                        guard phase == .active, let remote = services.remoteConfig else { return }
                        Task { await remote.refresh() }
                    }
            case .failure(let error):
                StartupFailureView(error: error)
            }
        }
    }
}
