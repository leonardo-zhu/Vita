import SwiftData
import SwiftUI

@main
struct VitaApp: App {
    private let bootstrap: Result<AppServices, Error>

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
            case .failure(let error):
                StartupFailureView(error: error)
            }
        }
    }
}
