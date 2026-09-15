import Foundation

/// Prompts for a device-owner unlock: biometrics (Face ID / Touch ID) or the
/// device passcode / login password.
///
/// Abstracted behind a protocol so `AppLockController` can be exercised in tests
/// without showing a system prompt. It is main-actor isolated because the real
/// prompt is a UI operation and the controller that drives it is UI state.
@MainActor
public protocol DeviceAuthenticator: Sendable {
    /// The biometry in use, for UI copy ("Face ID", "Touch ID"), or `nil` when
    /// only the passcode / password is available.
    var biometryName: String? { get }

    /// Whether an unlock can succeed right now. False when the device has no
    /// passcode or password set — a locked app would then be unrecoverable.
    var canAuthenticate: Bool { get }

    /// Shows the system prompt and returns normally only on success.
    func authenticate(reason: String) async throws
}
