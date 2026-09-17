#if DEBUG
import CoreData
import Foundation
import SwiftData
import CairnCore

/// Creates every record type and field in the CloudKit **Development**
/// environment, deterministically.
///
/// A normal Debug run only writes the fields that happen to hold a value, so
/// optional columns that are nil in the sample data — `orgURL`,
/// `lastSyncError`, the custom-currency names, the rule amount bounds, and so on
/// — would never appear in the schema. That matters because a field's encryption
/// state is fixed the moment the schema is deployed to Production: a field that
/// is missing from the deploy cannot be added as encrypted afterwards, and the
/// first real record that sets it would fail.
///
/// `initializeCloudKitSchema` walks the whole managed object model instead, so
/// every field is declared with the right type and encryption state. It runs
/// against a throwaway store in the temporary directory and never opens, reads,
/// or migrates the app's own store, so no real data and no old mirroring
/// metadata can reach the new container. It exits rather than starting the UI.
///
///     xcodebuild ... # or just Run with the argument
///     -cairn-initialize-cloudkit-schema
///
/// Debug only: the whole file is compiled out of Release builds.
enum SchemaInitializer {
    static let launchArgument = "-cairn-initialize-cloudkit-schema"

    /// Runs the initializer and exits the process when the argument is present.
    ///
    /// Called from `AppModel.init()` before anything touches the app's own
    /// container, so a requested run can never race the store that holds real
    /// data.
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }

        guard CloudAvailability.isAvailable else {
            report("iCloud is unavailable, so the development schema can't be created. \(CloudAvailability.unavailableReason)")
            exit(1)
        }

        let containerID = ModelContainerFactory.configuredCloudKitContainerID
        report("Preparing the CloudKit development schema for \(containerID)…")

        let container = makeContainer(containerID: containerID)
        container.loadPersistentStores { _, error in
            if let error {
                report("Could not open the throwaway store: \(error.localizedDescription)")
                exit(1)
            }
            do {
                // Every entity and attribute in the model, whether or not a value
                // exists for it yet.
                try container.initializeCloudKitSchema(options: [])
                cleanUp()
                report("Done. Every record type and field is up to date in the Development environment of \(containerID).")
                report(
                    "Next: in CloudKit Console, confirm the fields that should be encrypted "
                        + "show as encrypted, then deploy to Production."
                )
                exit(0)
            } catch {
                report("CloudKit refused the schema: \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    /// A CloudKit-backed container over a disposable store, never the app's.
    private static func makeContainer(containerID: String) -> NSPersistentCloudKitContainer {
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: CairnSchemaV1.models) else {
            report("Could not build a managed object model from CairnSchemaV1.")
            exit(1)
        }
        let container = NSPersistentCloudKitContainer(name: "CairnSchemaInit", managedObjectModel: model)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CairnSchemaInit",
            isDirectory: true
        )
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let description = NSPersistentStoreDescription(url: directory.appendingPathComponent("Cairn.sqlite"))
        description.type = NSSQLiteStoreType
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
            containerIdentifier: containerID
        )
        // Both are prerequisites of `initializeCloudKitSchema`, which walks
        // history-tracked changes to work out the schema.
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

        container.persistentStoreDescriptions = [description]
        return container
    }

    private static func cleanUp() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CairnSchemaInit",
            isDirectory: true
        )
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes to the console in a form that survives `xcodebuild` output and the
    /// Xcode debug area, and mirrors it into the device log so it is findable
    /// after the process exits.
    private static func report(_ message: String) {
        let line = "Cairn schema initializer: \(message)"
        print(line)
        NSLog("%@", line)
    }
}
#endif
