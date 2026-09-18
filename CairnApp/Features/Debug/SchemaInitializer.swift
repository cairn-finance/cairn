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
                report("Could not open the throwaway store:")
                describe(error)
                exit(1)
            }
            // Check the model against CloudKit's rules first: a model it cannot
            // translate fails with "A Core Data error occurred." and no clue as to
            // which field, and there is no point in a CloudKit round trip for that.
            let problems = validateForCloudKit(container.managedObjectModel)
            guard problems.isEmpty else {
                report("Fix those, then run this again. Nothing was sent to CloudKit.")
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
                report("CloudKit refused the schema:")
                describe(error)
                exit(1)
            }
        }
    }

    /// Prints the whole error chain.
    ///
    /// Core Data wraps the useful part: a refusal surfaces as "A Core Data error
    /// occurred." with the field or rule that was rejected buried in
    /// `NSUnderlyingErrorKey` or `NSDetailedErrorsKey`. Without this the tool
    /// reports a dead end instead of something to act on.
    private static func describe(_ error: any Error, depth: Int = 0) {
        guard depth < 6 else { return }
        let nsError = error as NSError
        let indent = String(repeating: "  ", count: depth)
        report("\(indent)\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)")
        for key in [NSLocalizedFailureReasonErrorKey, NSLocalizedRecoverySuggestionErrorKey] {
            if let value = nsError.userInfo[key] {
                report("\(indent)  \(key): \(value)")
            }
        }
        for detail in (nsError.userInfo[NSDetailedErrorsKey] as? [NSError]) ?? [] {
            describe(detail, depth: depth + 1)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            describe(underlying, depth: depth + 1)
        }
    }

    /// Reports every way the model breaks Core Data's CloudKit requirements.
    ///
    /// `initializeCloudKitSchema` answers a model it cannot translate with "A
    /// Core Data error occurred." and nothing else, which is useless from a
    /// terminal or a CI log. These are the documented requirements — every
    /// attribute optional or given a default, every relationship optional and
    /// with an inverse, no uniqueness constraints, nothing encrypted in an index,
    /// and only CloudKit-compatible attribute types — so a refusal names the
    /// offending field.
    private static func validateForCloudKit(_ model: NSManagedObjectModel) -> [String] {
        var problems: [String] = []
        var notes: [String] = []
        var typeCounts: [String: Int] = [:]

        for entity in model.entities {
            let entityName = entity.name ?? "unnamed entity"

            if !entity.uniquenessConstraints.isEmpty {
                problems.append("\(entityName): CloudKit has no uniqueness constraints.")
            }

            // Everything an index touches, so an encrypted attribute can be named.
            var indexed: Set<String> = []
            for index in entity.indexes {
                for element in index.elements {
                    if let property = element.property {
                        indexed.insert(property.name)
                    }
                }
            }

            for (name, attribute) in entity.attributesByName {
                let type = typeName(attribute.attributeType)
                typeCounts[type, default: 0] += 1

                if !attribute.isOptional, attribute.defaultValue == nil {
                    problems.append("\(entityName).\(name): not optional and has no default value.")
                }
                // `entity.indexes` is the modern home for every index, including
                // those declared with `#Index`; the old per-attribute flag is
                // deprecated and already covered by that set.
                if attribute.allowsCloudEncryption, indexed.contains(name) {
                    problems.append(
                        "\(entityName).\(name): encrypted, so CloudKit cannot index it — take it out of #Index."
                    )
                }
                if !isCloudKitCompatible(attribute.attributeType) {
                    problems.append("\(entityName).\(name): \(type) is not a CloudKit attribute type.")
                }
                if attribute.allowsCloudEncryption, !attribute.isOptional {
                    notes.append("\(entityName).\(name) is encrypted and required")
                }
            }

            for (name, relationship) in entity.relationshipsByName {
                if !relationship.isOptional {
                    problems.append("\(entityName).\(name): relationships must be optional for CloudKit.")
                }
                if relationship.inverseRelationship == nil {
                    problems.append("\(entityName).\(name): relationships need an inverse.")
                }
                if relationship.deleteRule == .denyDeleteRule {
                    problems.append("\(entityName).\(name): the deny delete rule is not supported by CloudKit.")
                }
            }
        }

        report("Model check: \(problems.count) violation(s).")
        for problem in problems {
            report("  violation: \(problem)")
        }
        if !notes.isEmpty {
            report("  for review: \(notes.joined(separator: "; ")).")
        }
        let summary = typeCounts.keys.sorted()
            .map { "\($0)=\(typeCounts[$0] ?? 0)" }
            .joined(separator: " ")
        report("  attribute types: \(summary)")
        return problems
    }

    /// CloudKit's field types are a subset of Core Data's.
    private static func isCloudKitCompatible(_ type: NSAttributeType) -> Bool {
        switch type {
        case .stringAttributeType, .integer16AttributeType, .integer32AttributeType,
             .integer64AttributeType, .doubleAttributeType, .floatAttributeType,
             .booleanAttributeType, .dateAttributeType, .binaryDataAttributeType,
             .decimalAttributeType, .UUIDAttributeType, .URIAttributeType:
            return true
        default:
            // `.transformableAttributeType`, `.objectIDAttributeType`,
            // `.undefinedAttributeType`: nothing CloudKit can store.
            return false
        }
    }

    private static func typeName(_ type: NSAttributeType) -> String {
        switch type {
        case .stringAttributeType: return "string"
        case .integer16AttributeType: return "int16"
        case .integer32AttributeType: return "int32"
        case .integer64AttributeType: return "int64"
        case .doubleAttributeType: return "double"
        case .floatAttributeType: return "float"
        case .booleanAttributeType: return "boolean"
        case .dateAttributeType: return "date"
        case .binaryDataAttributeType: return "data"
        case .decimalAttributeType: return "decimal"
        case .UUIDAttributeType: return "uuid"
        case .URIAttributeType: return "uri"
        case .transformableAttributeType: return "transformable"
        case .objectIDAttributeType: return "objectID"
        default: return "unknown(\(type.rawValue))"
        }
    }

    /// A CloudKit-backed container over a disposable store, never the app's.
    private static func makeContainer(containerID: String) -> NSPersistentCloudKitContainer {
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: CairnSchemaV1.models) else {
            report("Could not build a managed object model from CairnSchemaV1.")
            exit(1)
        }
        let container = NSPersistentCloudKitContainer(name: "CairnSchemaInit", managedObjectModel: model)
        var attributeCount = 0
        for entity in model.entities {
            attributeCount += entity.attributesByName.count
        }
        report("Model: \(model.entities.count) entities, \(attributeCount) attributes.")

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
