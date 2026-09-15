import Foundation
import LocalAuthentication

/// The real `DeviceAuthenticator`, backed by LocalAuthentication.
///
/// Uses `.deviceOwnerAuthentication`, so it accepts Face ID or Touch ID and
/// falls back to the device passcode (iOS) or login password (macOS). Calling
/// `canEvaluatePolicy` first is what populates `biometryType`.
public struct LocalAuthenticator: DeviceAuthenticator {
    public init() {}

    public var biometryName: String? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            return nil
        }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return nil
        }
    }

    public var canAuthenticate: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    public func authenticate(reason: String) async throws {
        let context = LAContext()
        try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }
}
