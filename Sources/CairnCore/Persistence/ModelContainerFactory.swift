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

    /// Info.plist key carrying the configured CloudKit container. It is populated
    /// from the `ICLOUD_CONTAINER_ID` build setting — the same one the
    /// entitlement uses — so the container the app requests and the container it
    /// is entitled to cannot drift apart.
    public static let containerIDInfoPlistKey = "CairnCloudKitContainerID"

    /// The CloudKit container to use at runtime.
    ///
    /// Prefers the configured value, because a container created under an
    /// earlier bundle id (or shared between apps) is not `iCloud.<bundle id>`.
    /// Falls back to that convention so a fresh clone, a test target, and a
    /// developer running without the xcconfig all still work.
    public static var configuredCloudKitContainerID: String {
        resolveCloudKitContainerID(
            configured: Bundle.main.object(forInfoDictionaryKey: containerIDInfoPlistKey) as? String,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    /// The resolution rule, split out so it can be tested without a bundle.
    ///
    /// A value that still contains a `$(…)` build-setting placeholder counts as
    /// unset: the plist would carry it literally only when the setting was never
    /// substituted, and asking CloudKit for `iCloud.$(ICLOUD_CONTAINER_ID)` traps
    /// instead of failing softly.
    public static func resolveCloudKitContainerID(configured: String?, bundleIdentifier: String?) -> String {
        if let configured {
            let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !trimmed.contains("$(") {
                return trimmed
            }
        }
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return "iCloud.\(bundleIdentifier)"
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
