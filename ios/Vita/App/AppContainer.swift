import SwiftData

/// 依赖装配根。Presentation 只拿到 Application Service，不直接接触 SwiftData / Keychain；
/// 后续 Service、LLMClient、HealthKitAdapter 在此装配，并在测试中替换为替身。
struct AppContainer: Sendable {
    let modelContainer: ModelContainer
    let secrets: any SecretStore

    static func live() throws -> AppContainer {
        AppContainer(
            modelContainer: try PersistenceStore.makeContainer(inMemory: false),
            secrets: KeychainSecretStore()
        )
    }

    static func inMemory(secrets: any SecretStore = InMemorySecretStore()) throws -> AppContainer {
        AppContainer(
            modelContainer: try PersistenceStore.makeContainer(inMemory: true),
            secrets: secrets
        )
    }
}
