import Foundation

/// Whether Cairn may attempt to open a CloudKit-backed store.
///
/// CloudKit raises a hard exception (a process trap) when asked to create a
/// container without the `com.apple.developer.icloud-services` entitlement, or
/// when the container isn't registered — it does not throw a `Swift.Error`, so
/// the decision must be made before creating the container.
///
/// Cairn ships the iCloud entitlement in every configuration (see
/// `Config/Cairn.entitlements`), so this is a runtime check: CloudKit is used
/// whenever an iCloud account is available, and the store falls back to local
/// otherwise. This mirrors the approach used in Hecate.
public enum CloudAvailability {
    /// Launch argument that forces local-only storage.
    public static let disableArgument = "-cairn-disable-cloudkit"

    public static var isAvailable: Bool {
        if ProcessInfo.processInfo.arguments.contains(disableArgument) {
            return false
        }
        if isRunningTests {
            return false
        }
        // `ubiquityIdentityToken` is nil when there is no iCloud account *and*
        // when the app lacks the iCloud entitlement, so it is a safe gate that
        // also protects unsigned/CI builds from CloudKit's trap.
        return FileManager.default.ubiquityIdentityToken != nil
    }

    public static var unavailableReason: String {
        "iCloud is unavailable (not signed in, or this build lacks an iCloud entitlement), so data stays on this device."
    }

    /// Xcode sets different variables depending on how tests are hosted; the
    /// XCTest framework being loaded in-process is the reliable signal.
    private static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil {
            return true
        }
        return NSClassFromString("XCTestCase") != nil
    }
}
