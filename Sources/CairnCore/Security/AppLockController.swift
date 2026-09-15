import Foundation
import LocalAuthentication
import Observation

/// Owns the "require unlock to open" state: whether the lock is on, whether the
/// app is currently locked, and the lifecycle of the unlock prompt.
///
/// Kept in CairnCore so the state machine can be tested with a fake
/// `DeviceAuthenticator`. The lock always fails open: if the device can no
/// longer authenticate (for example its passcode was removed), unlocking is
/// allowed and the lock turns itself off, rather than trapping the person
/// outside their own data.
@MainActor
@Observable
public final class AppLockController {
    /// Whether "require unlock to open" is on.
    public private(set) var isEnabled: Bool
    /// Whether the lock screen should be covering the app right now.
    public private(set) var isLocked: Bool
    /// True while the system prompt is on screen, so the UI can show progress.
    public private(set) var isUnlocking = false
    /// A message for a failed unlock. A deliberate cancellation leaves this nil.
    public private(set) var lastError: String?

    @ObservationIgnored private let authenticator: any DeviceAuthenticator

    public init(enabled: Bool, authenticator: any DeviceAuthenticator) {
        self.authenticator = authenticator
        self.isEnabled = enabled
        self.isLocked = enabled
    }

    /// Whether the device can authenticate at all. When false the lock must stay
    /// off, because there would be no way to open the app.
    public var canAuthenticate: Bool { authenticator.canAuthenticate }

    /// "Face ID", "Touch ID", or nil when only passcode / password is available.
    public var biometryName: String? { authenticator.biometryName }

    /// The label for the unlock button, naming the biometry when there is one.
    public var unlockActionTitle: String {
        if let name = authenticator.biometryName { return "Unlock with \(name)" }
        return "Unlock"
    }

    /// Turns the lock on or off. Enabling locks immediately so the next
    /// foreground requires an unlock; refusing when the device can't
    /// authenticate keeps the app openable.
    public func setEnabled(_ enabled: Bool) {
        guard !enabled || authenticator.canAuthenticate else { return }
        isEnabled = enabled
        isLocked = enabled
        lastError = nil
    }

    /// Locks again, for when the app leaves the foreground.
    public func lock() {
        guard isEnabled, !isLocked else { return }
        isLocked = true
        lastError = nil
    }

    /// Prompts for an unlock if one is needed. Safe to call on every foreground;
    /// concurrent callers are collapsed into one prompt.
    public func unlock() async {
        guard isEnabled, isLocked, !isUnlocking else { return }

        // Fail open rather than lock someone out of their own data.
        guard authenticator.canAuthenticate else {
            isEnabled = false
            isLocked = false
            lastError = nil
            return
        }

        isUnlocking = true
        defer { isUnlocking = false }
        do {
            try await authenticator.authenticate(reason: "Unlock Cairn")
            isLocked = false
            lastError = nil
        } catch {
            lastError = Self.failureMessage(for: error)
        }
    }

    /// A deliberate cancellation is not an error worth showing; a real failure
    /// (a lockout, for example) is.
    private static func failureMessage(for error: any Error) -> String? {
        guard let laError = error as? LAError else {
            return error.localizedDescription
        }
        switch laError.code {
        case .userCancel, .systemCancel, .appCancel, .notInteractive:
            return nil
        default:
            return "Cairn couldn’t unlock. Try again, or use your device passcode."
        }
    }
}
