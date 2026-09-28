import Foundation
import SwiftData

/// Migration plan for the Cairn store.
public enum CairnMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [CairnSchemaV1.self, CairnSchemaV2.self, CairnSchemaV3.self, CairnSchemaV4.self]
    }

    public static var stages: [MigrationStage] {
        [
            MigrationStage.lightweight(fromVersion: CairnSchemaV1.self, toVersion: CairnSchemaV2.self),
            MigrationStage.lightweight(fromVersion: CairnSchemaV2.self, toVersion: CairnSchemaV3.self),
            MigrationStage.lightweight(fromVersion: CairnSchemaV3.self, toVersion: CairnSchemaV4.self),
        ]
    }
}
