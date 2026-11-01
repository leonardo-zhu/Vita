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
                    // 启动和每次回到前台：检查远程配置（vita-admin.md §5），发出排队的诊断日志（ADR-014）。都不阻塞界面
                    .onChange(of: scenePhase, initial: true) { _, phase in
                        guard phase == .active else { return }
                        if let remote = services.remoteConfig { Task { await remote.refresh() } }
                        if let diagnostics = services.container.diagnostics as? DiagnosticsService {
                            Task { await diagnostics.flush() }
                        }
                    }
            case .failure(let error):
                StartupFailureView(error: error)
            }
        }
    }
}
