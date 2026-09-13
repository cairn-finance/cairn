import Foundation
import SwiftData

/// Which persistence back end the app should use.
public enum StoreMode: String, Sendable, CaseIterable, Codable {
    /// Sync through the user's iCloud private database.
    case cloud
    /// Keep everything on this device only.
    case local

    public var displayName: String {
        switch self {
        case .cloud: "iCloud Sync"
        case .local: "This Device Only"
        }
    }

    public var summary: String {
        switch self {
        case .cloud:
            "Data syncs through your private iCloud database."
        case .local:
            "Nothing leaves this device. No iCloud. No credential sync."
        }
    }
}

/// Builds the SwiftData container. When `cloud` is requested the container uses
/// the app's CloudKit private database; if that cannot be created (for example
/// the entitlement is missing in a debug build) the factory reports the failure
/// so the app can fall back to local storage rather than crashing.
public struct ModelContainerFactory: Sendable {
    public static let cloudKitContainerID = "iCloud.com.example.cairn"

    /// The CloudKit container to use at runtime. It follows the bundle
    /// identifier (`iCloud.<bundle id>`), matching the entitlement, so each
    /// developer's local signing automatically uses their own container.
    public static var configuredCloudKitContainerID: String {
        if let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty {
            return "iCloud.\(bundleID)"
        }
        return cloudKitContainerID
    }

    public struct Result: Sendable {
        public let container: ModelContainer
        public let mode: StoreMode
        /// Non-nil when cloud was requested but local was used instead.
        public let cloudFallbackReason: String?
    }

    public enum FactoryError: Error, LocalizedError {
        case containerCreationFailed(String)

        public var errorDescription: String? {
            switch self {
            case let .containerCreationFailed(message):
                "Could not open the Cairn data store: \(message)"
            }
        }
    }

    public static func make(
        mode: StoreMode,
        inMemory: Bool = false,
        cloudKitContainerID: String = configuredCloudKitContainerID
    ) throws -> Result {
        let schema = Schema(versionedSchema: CairnSchemaV1.self)

        if mode == .cloud {
            // Never touch CloudKit without the entitlement: it traps instead of
            // throwing, so the local fallback below could not catch it.
            guard CloudAvailability.isAvailable else {
                let local = try makeLocal(schema: schema, inMemory: inMemory)
                return Result(container: local, mode: .local, cloudFallbackReason: CloudAvailability.unavailableReason)
            }

            let cloudConfiguration = ModelConfiguration(
                "Cairn",
                schema: schema,
                isStoredInMemoryOnly: inMemory,
                cloudKitDatabase: .private(cloudKitContainerID)
            )
            do {
                let container = try ModelContainer(
                    for: schema,
                    migrationPlan: CairnMigrationPlan.self,
                    configurations: cloudConfiguration
                )
                return Result(container: container, mode: .cloud, cloudFallbackReason: nil)
            } catch {
                let local = try makeLocal(schema: schema, inMemory: inMemory)
                return Result(
                    container: local,
                    mode: .local,
                    cloudFallbackReason: error.localizedDescription
                )
            }
        }

        let container = try makeLocal(schema: schema, inMemory: inMemory)
        return Result(container: container, mode: .local, cloudFallbackReason: nil)
    }

    private static func makeLocal(schema: Schema, inMemory: Bool) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "Cairn",
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )
        do {
            return try ModelContainer(
                for: schema,
                migrationPlan: CairnMigrationPlan.self,
                configurations: configuration
            )
        } catch {
            throw FactoryError.containerCreationFailed(error.localizedDescription)
        }
    }
}
