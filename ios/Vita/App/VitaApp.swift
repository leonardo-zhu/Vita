import SwiftUI

@main
struct VitaApp: App {
    private let bootstrap: Result<AppServices, Error>
    @Environment(\.scenePhase) private var scenePhase

    init() {
        bootstrap = Result { AppServices(container: try AppContainer.live()) }
    }

    var body: some Scene {
        WindowGroup {
            switch bootstrap {
            case .success(let services):
                RootView(services: services)
                    // 启动和每次回到前台：检查远程配置（vita-admin.md §5），发出排队的诊断日志（ADR-014），
                    // 补传没传上去的称重，再把服务端的变化同步到 Apple 健康（架构设计 §9）。都不阻塞界面
                    .onChange(of: scenePhase, initial: true) { _, phase in
                        guard phase == .active else { return }
                        if let remote = services.remoteConfig { Task { await remote.refresh() } }
                        if let diagnostics = services.container.diagnostics as? DiagnosticsService {
                            Task { await diagnostics.flush() }
                        }
                        if services.isConnected, !LegacyMigration.hasLegacyData() {
                            Task {
                                await services.bodyComposition.flushQueue()
                                await services.healthSync.run()
                            }
                        }
                    }
            case .failure(let error):
                StartupFailureView(error: error)
            }
        }
    }
}
