import SwiftData
import SwiftUI

@main
struct VitaApp: App {
    private let bootstrap: Result<AppContainer, Error> = Result { try AppContainer.live() }

    var body: some Scene {
        WindowGroup {
            switch bootstrap {
            case .success(let container):
                RootView()
                    .modelContainer(container.modelContainer)
            case .failure(let error):
                StartupFailureView(error: error)
            }
        }
    }
}
