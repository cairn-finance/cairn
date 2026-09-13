import Foundation
import SwiftData

/// Migration plan for the Cairn store. Version 1 is the initial schema; future
/// versions add a stage here. Keeping this in place from day one means schema
/// changes never require an ad-hoc reset.
public enum CairnMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [CairnSchemaV1.self]
    }

    public static var stages: [MigrationStage] {
        []
    }
}
