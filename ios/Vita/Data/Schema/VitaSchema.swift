import SwiftData

/// SwiftData schema 版本。后续每个破坏性变更新增一个 VersionedSchema 并在
/// `VitaMigrationPlan` 中登记迁移阶段。首个版本发布前（尚无需要保留的真实数据）直接扩充 V1。
enum VitaSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [
            AuditEvent.self,
            DaySession.self, ChatMessage.self,
            ConsumptionRecord.self, ConsumptionItem.self,
            FoodProduct.self, FoodVersion.self,
            DailyGoal.self,
        ]
    }
}

enum VitaMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [VitaSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

enum PersistenceStore {
    /// `inMemory` 供单元测试与预览使用，不落盘。
    static func makeContainer(inMemory: Bool) throws -> ModelContainer {
        let schema = Schema(VitaSchemaV1.models, version: VitaSchemaV1.versionIdentifier)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(
            for: schema,
            migrationPlan: VitaMigrationPlan.self,
            configurations: [configuration]
        )
    }
}
