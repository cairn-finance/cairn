import CoreData
import Foundation
import Observation
import SwiftData
import CairnCore

/// The app-wide coordinator. Owns the store, the sync engine, the credential
/// store, and the small amount of UI state that needs to survive navigation.
@MainActor
@Observable
final class AppModel {
    enum Keys {
        static let useCloudKit = "cairn.useCloudKit"
        static let onboardingComplete = "cairn.onboardingComplete"
        static let appLockEnabled = "cairn.appLockEnabled"
    }

    enum SyncState: Equatable {
        case idle
        case syncing
        case success
        case failed(String)
    }

    @ObservationIgnored let container: ModelContainer
    @ObservationIgnored let storeMode: StoreMode
    @ObservationIgnored let cloudFallbackReason: String?
    @ObservationIgnored let requestedCloud: Bool
    @ObservationIgnored let engine: SyncEngine
    @ObservationIgnored let client: SimpleFINClient
    @ObservationIgnored let credentials: any CredentialStore

    private(set) var onboardingComplete: Bool
    private(set) var appLockEnabled: Bool
    var useCloudKit: Bool
    var syncState: SyncState = .idle
    var remainingBudget: Int = SyncEngine.dailyRequestLimit
    var banner: String?

    init(inMemory: Bool = false) {
        let defaults = UserDefaults.standard
        // New installs default to iCloud Sync so the onboarding default works
        // without a relaunch; cloud falls back to local when unavailable.
        let cloud = (defaults.object(forKey: Self.Keys.useCloudKit) as? Bool) ?? true
        useCloudKit = cloud
        requestedCloud = cloud
        onboardingComplete = defaults.bool(forKey: Self.Keys.onboardingComplete)
        appLockEnabled = defaults.bool(forKey: Self.Keys.appLockEnabled)

        credentials = inMemory ? InMemoryCredentialStore() : KeychainCredentialStore()
        client = SimpleFINClient(session: SimpleFINClient.ephemeralSession())

        let result: ModelContainerFactory.Result
        do {
            result = try ModelContainerFactory.make(
                mode: cloud ? .cloud : .local,
                inMemory: inMemory
            )
        } catch {
            // Last-resort fallback so the app always launches with a working store.
            do {
                result = try ModelContainerFactory.make(mode: .local, inMemory: true)
            } catch {
                fatalError("Cairn could not open even an in-memory data store: \(error)")
            }
        }

        container = result.container
        storeMode = result.mode
        cloudFallbackReason = result.cloudFallbackReason
        engine = SyncEngine(modelContainer: result.container)

        Task { await bootstrap() }
    }

    private func bootstrap() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(SampleData.launchArgument) {
            try? await engine.seedDefaultCategoriesIfNeeded()
            SampleData.populate(context: container.mainContext)
            UserDefaults.standard.set(true, forKey: Self.Keys.onboardingComplete)
            onboardingComplete = true
        }
        #endif

        // Seeding may briefly wait for the first CloudKit import, so run it
        // alongside the initial sync instead of delaying it.
        async let seeding: Void = seedDefaultCategoriesWhenReady()
        await refreshBudget()
        migrateCredentials(synchronizable: useCloudKit)
        if onboardingComplete {
            await syncAll(force: false)
        }
        await seeding
    }

    /// Seeds the default categories once. On a CloudKit store this waits briefly
    /// for the first import so a second device doesn't create its own settings
    /// row and category set before the original data arrives.
    private func seedDefaultCategoriesWhenReady() async {
        if storeMode == .cloud {
            await waitForFirstCloudImport()
        }
        try? await engine.seedDefaultCategoriesIfNeeded()
    }

    /// Waits until CloudKit reports that its initial setup or import has ended,
    /// or the timeout elapses. On a fresh account nothing may be imported, so
    /// the timeout ensures seeding still happens.
    private func waitForFirstCloudImport(timeout: Duration = .seconds(20)) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await note in NotificationCenter.default.notifications(
                    named: NSPersistentCloudKitContainer.eventChangedNotification
                ) {
                    guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                        as? NSPersistentCloudKitContainer.Event else { continue }
                    if event.endDate != nil, event.type == .import || event.type == .setup {
                        return
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Onboarding

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.Keys.onboardingComplete)
        onboardingComplete = true
        // Connecting a bank already synced it; don't spend a second request here.
        Task { try? await engine.markOnboardingComplete(useCloudKit: useCloudKit) }
    }

    /// Claims a SimpleFIN setup token, stores the Access URL in the Keychain, and
    /// starts the first sync. Returns `false` (and stores nothing) if the
    /// credential can't be saved, since the token is single-use.
    @discardableResult
    func connectInstitution(token: String) async -> Bool {
        syncState = .syncing
        do {
            let accessURL = try await client.claim(token: token)
            let credentialID = UUID()
            try storeCredential(accessURL.absoluteString, id: credentialID)

            var sfinURL = ""
            if let scheme = accessURL.scheme, let host = accessURL.host {
                sfinURL = "\(scheme)://\(host)"
            }

            let institution = Institution(
                bankConnectionID: "",
                name: "Connecting…",
                credentialID: credentialID
            )
            institution.sfinURL = sfinURL
            container.mainContext.insert(institution)
            try container.mainContext.save()

            await syncAll(force: true)
            return true
        } catch {
            let message: String
            if error is CredentialStoreError {
                message = "Cairn couldn’t save this credential to the Keychain, so the connection wasn’t completed. Create a new SimpleFIN token and try again."
            } else {
                message = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            syncState = .failed(message)
            return false
        }
    }

    // MARK: - Sync

    func syncAll(force: Bool) async {
        let context = container.mainContext
        guard let institutions = try? context.fetch(FetchDescriptor<Institution>()),
              !institutions.isEmpty else {
            syncState = .idle
            return
        }

        syncState = .syncing
        var failures: [String] = []
        var skippedForCredential = 0
        var reportedBudget = false
        var reportedThrottle = false

        // Each institution is independent: its own credential, its own request
        // budget, and its own failures. One bank failing must not stop the rest.
        for institution in institutions {
            let name = institution.name.isEmpty ? "A bank" : institution.name
            do {
                let decision = try await engine.decideSync(
                    institutionID: institution.persistentModelID,
                    force: force,
                    now: Date()
                )
                switch decision {
                case .budgetExhausted:
                    if !reportedBudget {
                        banner = "\(name) has reached today’s SimpleFIN request limit. It will sync again tomorrow."
                        reportedBudget = true
                    }
                case let .throttled(until):
                    if force, !reportedThrottle {
                        banner = "Just synced. Next automatic refresh after \(until.formatted(date: .omitted, time: .shortened))."
                        reportedThrottle = true
                    }
                case .proceed:
                    guard let secret = try credentials.secret(for: institution.credentialID),
                          let accessURL = URL(string: secret) else {
                        skippedForCredential += 1
                        continue
                    }
                    let outcome = try await engine.performSync(
                        institutionID: institution.persistentModelID,
                        accessURL: accessURL,
                        client: client,
                        now: Date()
                    )
                    failures.append(contentsOf: outcome.serverErrors.map { "\(name): \($0)" })
                }
            } catch {
                let reason = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
                failures.append("\(name): \(reason)")
            }
        }

        await refreshBudget()
        if let first = failures.first {
            syncState = .failed(first)
        } else if skippedForCredential > 0 {
            syncState = .failed(
                "Waiting for iCloud Keychain to deliver the credential for \(skippedForCredential) "
                + "institution\(skippedForCredential == 1 ? "" : "s"). Make sure iCloud Keychain is on for the same Apple Account."
            )
        } else {
            syncState = .success
        }
    }

    func refreshBudget() async {
        remainingBudget = (try? await engine.minimumRemainingBudget(now: Date())) ?? SyncEngine.dailyRequestLimit
    }

    // MARK: - Institution management

    func disconnect(_ institution: Institution) async {
        let credentialID = institution.credentialID
        try? credentials.delete(id: credentialID)
        container.mainContext.delete(institution)
        try? container.mainContext.save()
        await syncAll(force: false)
    }

    // MARK: - Lock

    func setAppLock(enabled: Bool) {
        appLockEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.Keys.appLockEnabled)
        Task { try? await engine.setAppLock(enabled: enabled) }
    }

    // MARK: - Export & deletion

    func exportData(json: Bool) async -> Data? {
        do {
            return json ? try await engine.exportJSON() : Data(try await engine.exportCSV().utf8)
        } catch {
            banner = "Export failed: \(error.localizedDescription)"
            return nil
        }
    }

    func deleteAllData() async {
        try? await engine.deleteAllData()
        try? credentials.deleteAll()
        UserDefaults.standard.removeObject(forKey: Self.Keys.onboardingComplete)
        // Deliberately keep the storage preference: a "This Device Only" user
        // who deletes their data must not be silently switched to iCloud.
        onboardingComplete = false
        remainingBudget = SyncEngine.dailyRequestLimit
        syncState = .idle
    }

    /// Switches the storage mode. The SwiftData container is chosen at launch,
    /// so the data store part applies on the next start — but the Keychain
    /// credential is migrated immediately so it stops (or starts) syncing now.
    func requestStoreModeChange(to mode: StoreMode) {
        let cloud = mode == .cloud
        UserDefaults.standard.set(cloud, forKey: Self.Keys.useCloudKit)
        useCloudKit = cloud
        migrateCredentials(synchronizable: cloud)
        banner = cloud
            ? "iCloud Sync will be enabled the next time you open Cairn."
            : "This Device Only takes effect the next time you open Cairn. The stored credential has already stopped syncing."
    }

    /// Stores the credential with the requested iCloud Keychain setting. Falls
    /// back to this-device-only when iCloud Keychain is unavailable, but throws
    /// if neither succeeds so the caller can refuse to complete the connection.
    private func storeCredential(_ secret: String, id: UUID) throws {
        do {
            try credentials.store(secret, id: id, synchronizable: useCloudKit)
        } catch let syncError {
            do {
                try credentials.store(secret, id: id, synchronizable: false)
                banner = "iCloud Keychain sync isn’t available here, so the credential is stored on this device only."
            } catch {
                throw syncError
            }
        }
    }

    /// Re-stores credentials whose synchronizability no longer matches the
    /// preference. Skips items that already match so the synced copy is not
    /// churned on every launch. `store` adds before deleting, so a failure here
    /// never removes the existing credential.
    private func migrateCredentials(synchronizable: Bool) {
        guard let institutions = try? container.mainContext.fetch(FetchDescriptor<Institution>()) else {
            return
        }
        for institution in institutions {
            guard let secret = try? credentials.secret(for: institution.credentialID) else { continue }
            if let current = try? credentials.isSynchronizable(for: institution.credentialID),
               current == synchronizable {
                continue
            }
            do {
                try credentials.store(secret, id: institution.credentialID, synchronizable: synchronizable)
            } catch {
                let name = institution.name.isEmpty ? "an institution" : institution.name
                banner = "Couldn’t update iCloud Keychain sync for \(name): \(error.localizedDescription)"
            }
        }
    }
}
