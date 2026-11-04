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
                    // 启动和每次回到前台：补传没传上去的称重，再把服务端的变化同步到 Apple 健康（架构设计 §9）。不阻塞界面
                    .onChange(of: scenePhase, initial: true) { _, phase in
                        guard phase == .active else { return }
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
