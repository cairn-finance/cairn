import LocalAuthentication
import Testing
@testable import CairnCore

@MainActor
@Suite("App lock")
struct AppLockTests {
    /// Drives `AppLockController` without showing a system prompt.
    @MainActor
    final class FakeAuthenticator: DeviceAuthenticator, @unchecked Sendable {
        var biometryName: String? = "Face ID"
        var canAuthenticate = true
        var result: Result<Void, any Error> = .success(())
        private(set) var authenticateCount = 0

        func authenticate(reason: String) async throws {
            authenticateCount += 1
            try result.get()
        }
    }

    private struct AuthFailure: Error {}

    @Test("Starts locked when enabled, and unlocks on success")
    func unlocks() async {
        let authenticator = FakeAuthenticator()
        let lock = AppLockController(enabled: true, authenticator: authenticator)
        #expect(lock.isLocked)
        await lock.unlock()
        #expect(!lock.isLocked)
        #expect(lock.lastError == nil)
        #expect(authenticator.authenticateCount == 1)
    }

    @Test("A failed unlock stays locked and explains itself")
    func failureStaysLocked() async {
        let authenticator = FakeAuthenticator()
        authenticator.result = .failure(AuthFailure())
        let lock = AppLockController(enabled: true, authenticator: authenticator)
        await lock.unlock()
        #expect(lock.isLocked)
        #expect(lock.lastError != nil)
    }

    @Test("A not-interactive launch race stays quiet, not an error")
    func notInteractiveIsSilent() async {
        let authenticator = FakeAuthenticator()
        authenticator.result = .failure(LAError(.notInteractive))
        let lock = AppLockController(enabled: true, authenticator: authenticator)
        await lock.unlock()
        #expect(lock.isLocked)
        #expect(lock.lastError == nil)
    }

    @Test("Locking again needs another unlock")
    func relocks() async {
        let authenticator = FakeAuthenticator()
        let lock = AppLockController(enabled: true, authenticator: authenticator)
        await lock.unlock()
        #expect(!lock.isLocked)
        lock.lock()
        #expect(lock.isLocked)
    }

    @Test("An unlock that is not needed does nothing")
    func idleUnlockIsANoOp() async {
        let authenticator = FakeAuthenticator()
        let lock = AppLockController(enabled: false, authenticator: authenticator)
        await lock.unlock()
        #expect(authenticator.authenticateCount == 0)
    }

    @Test("Enabling is refused when the device can't authenticate")
    func refusesToEnable() {
        let authenticator = FakeAuthenticator()
        authenticator.canAuthenticate = false
        let lock = AppLockController(enabled: false, authenticator: authenticator)
        lock.setEnabled(true)
        #expect(!lock.isEnabled)
        #expect(!lock.isLocked)
    }

    @Test("Disabling clears the lock")
    func disablingUnlocks() {
        let authenticator = FakeAuthenticator()
        let lock = AppLockController(enabled: true, authenticator: authenticator)
        lock.setEnabled(false)
        #expect(!lock.isEnabled)
        #expect(!lock.isLocked)
    }

    @Test("The lock fails open when the device can no longer authenticate")
    func failsOpen() async {
        let authenticator = FakeAuthenticator()
        let lock = AppLockController(enabled: true, authenticator: authenticator)
        authenticator.canAuthenticate = false
        await lock.unlock()
        #expect(!lock.isLocked)
        #expect(!lock.isEnabled)
    }

    @Test("The unlock label names the biometry when there is one")
    func unlockTitle() {
        let withBiometry = FakeAuthenticator()
        let named = AppLockController(enabled: true, authenticator: withBiometry)
        #expect(named.unlockActionTitle == "Unlock with Face ID")

        let withoutBiometry = FakeAuthenticator()
        withoutBiometry.biometryName = nil
        let unnamed = AppLockController(enabled: true, authenticator: withoutBiometry)
        #expect(unnamed.unlockActionTitle == "Unlock")
    }
}
