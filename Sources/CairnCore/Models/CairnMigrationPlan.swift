import Foundation
import SwiftData

/// Migration plan for the Cairn store.
public enum CairnMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [CairnSchemaV1.self, CairnSchemaV2.self]
    }

    public static var stages: [MigrationStage] {
        [MigrationStage.lightweight(fromVersion: CairnSchemaV1.self, toVersion: CairnSchemaV2.self)]
    }
}
