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
        static let useAppleIntelligence = "cairn.useAppleIntelligenceCategorization"
        static let categorizeOnlyWhileCharging = "cairn.categorizeOnlyWhileCharging"
        static let walletSyncEnabled = "cairn.walletSyncEnabled"
    }

    enum SyncState: Equatable {
        case idle
        case syncing
        case success
        /// The pass finished with nothing actually wrong, but something still
        /// needs attention — for example a saved connection whose credential
        /// isn't on this device. This is a notice, not a failure.
        case waiting(title: String, detail: String, credentialIDs: [UUID])
        case failed(String)
    }

    /// The SwiftData container. It is replaced only when a failed launch is
    /// retried successfully; until then no store work runs against the
    /// placeholder container created for the error screen.
    @ObservationIgnored private(set) var container: ModelContainer
    private(set) var storeMode: StoreMode
    private(set) var cloudFallbackReason: String?
    @ObservationIgnored let requestedCloud: Bool
    @ObservationIgnored private(set) var engine: SyncEngine
    /// Non-nil when the persistent store could not be opened. While set, the app
    /// shows the recovery screen and refuses to run sync, Wallet import,
    /// categorization, or any background work.
    private(set) var storeFailure: String?
    #if os(iOS)
    /// Reads eligible Apple Wallet data through FinanceKit. iPhone/iPad only.
    @ObservationIgnored private(set) var walletEngine: WalletSyncEngine
    #endif
    @ObservationIgnored let client: SimpleFINClient
    @ObservationIgnored let credentials: any CredentialStore
    /// Debug-only: true when the app was launched on the built-in synthetic
    /// sample data. Such a run has no credential and no server, so its setup
    /// never touches the network.
    @ObservationIgnored let isSampleMode: Bool
    /// The "require unlock to open" state machine. UI reads `lock.isLocked`.
    @ObservationIgnored let lock: AppLockController
    /// Watches network reachability so offline can be explained as a pause
    /// rather than reported as a sync failure.
    @ObservationIgnored let connectivity = NetworkMonitor()

    private(set) var onboardingComplete: Bool
    var useCloudKit: Bool
    /// Whether Wallet data should be read from FinanceKit. The person can clear
    /// Wallet rows without being able to revoke the system authorization, so
    /// this records that choice; otherwise the next sync imports them straight
    /// back.
    private(set) var walletSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(walletSyncEnabled, forKey: Self.Keys.walletSyncEnabled)
        }
    }
    var syncState: SyncState = .idle
    var remainingBudget: Int = SyncEngine.dailyRequestLimit
    var banner: String?

    /// Keychain credentials with no `Institution` row, offered for reconnection.
    private(set) var recoverableCredentials: [RecoverableCredential] = []
    /// Credentials whose reconnect is currently in flight, so the action can be
    /// disabled and a second tap ignored.
    private(set) var reconnectingCredentialIDs: Set<UUID> = []

    /// Watches for iCloud changes so an offer is withdrawn once the row that
    /// references its credential arrives.
    @ObservationIgnored private var remoteChangeTask: Task<Void, Never>?
    /// Set once the first import has settled; until then a remote change must
    /// not trigger a scan that could offer a credential still arriving.
    @ObservationIgnored private var credentialsScanReady = false
    /// Coalesces repair passes: a remote change can arrive while one is running.
    @ObservationIgnored private var isRepairingConnections = false
    /// Set while a sync resumed by a restored connection is in flight, so a
    /// second path update cannot start an overlapping pass.
    @ObservationIgnored var isResumingAfterReconnect = false

    /// Automatic categorization progress, surfaced in Insights.
    enum CategorizationState: Equatable {
        case idle
        case running
        case finished(categorized: Int, counts: SyncEngine.CategorizationCounts)
    }

    private(set) var categorizationState: CategorizationState = .idle
    private(set) var categorizationCounts = SyncEngine.CategorizationCounts()

    /// Subscriptions and other regular payments detected from history. Kept
    /// here so Home and Insights can summarize them without their own full
    /// transaction queries. Recomputed when sync or a flag change can alter it.
    private(set) var recurringSeries: [RecurringSeries] = []

    /// Progress of the on-device model pass, shown while it runs.
    struct ModelProgress: Equatable {
        var processed: Int
        var total: Int
    }

    private(set) var modelProgress: ModelProgress?

    /// Whether the on-device model may be used. Rules and learned history always
    /// run, regardless of this setting.
    var useAppleIntelligence: Bool {
        didSet {
            UserDefaults.standard.set(useAppleIntelligence, forKey: Self.Keys.useAppleIntelligence)
        }
    }

    /// Whether the bulk (background) model pass waits for external power. The
    /// short foreground pass always runs, so the most recent activity is
    /// categorized even on battery.
    var categorizeOnlyWhileCharging: Bool {
        didSet {
            UserDefaults.standard.set(
                categorizeOnlyWhileCharging,
                forKey: Self.Keys.categorizeOnlyWhileCharging
            )
        }
    }

    /// Why the model pass last stopped early, so the UI can explain that it will
    /// continue rather than looking stuck.
    private(set) var modelPauseReason: CategorizationPower.Decision?

    /// How much of the backlog a run will work through. A foreground pass is
    /// deliberately small so the app stays responsive and cool; the bulk of a
    /// large backlog runs in the background, ideally while charging.
    enum CategorizationScope: Sendable, Equatable {
        case foreground
        case background
    }

    private static let foregroundModelCallCap = 6
    private static let backgroundModelCallCap = 80

    @ObservationIgnored private var isAutoCategorizing = false

    init(inMemory: Bool = false) {
        #if DEBUG
        // Debug-only schema tool. It exits the process, and it runs here rather
        // than in the App type so it cannot race the store that holds real data.
        SchemaInitializer.runIfRequested()
        #endif

        let defaults = UserDefaults.standard
        // Local-first: iCloud sync is opted into, never assumed. The privacy
        // policy and README both promise that data reaches iCloud only if the
        // person chooses it, and the first connection's backfill would otherwise
        // upload before anyone was asked.
        let cloud = (defaults.object(forKey: Self.Keys.useCloudKit) as? Bool) ?? false
        useCloudKit = cloud
        requestedCloud = cloud
        onboardingComplete = defaults.bool(forKey: Self.Keys.onboardingComplete)
        walletSyncEnabled = (defaults.object(forKey: Self.Keys.walletSyncEnabled) as? Bool) ?? true
        lock = AppLockController(
            enabled: defaults.bool(forKey: Self.Keys.appLockEnabled),
            authenticator: LocalAuthenticator()
        )
        useAppleIntelligence = (defaults.object(forKey: Self.Keys.useAppleIntelligence) as? Bool) ?? true
        categorizeOnlyWhileCharging =
            (defaults.object(forKey: Self.Keys.categorizeOnlyWhileCharging) as? Bool) ?? true

        #if DEBUG
        let sampleMode = ProcessInfo.processInfo.arguments.contains(SampleData.launchArgument)
        #else
        let sampleMode = false
        #endif
        isSampleMode = sampleMode
        credentials = (inMemory || sampleMode) ? InMemoryCredentialStore() : KeychainCredentialStore()
        client = SimpleFINClient(session: SimpleFINClient.ephemeralSession())

        // Cloud -> local is the one accepted fallback: `openForLaunch` uses the
        // same on-disk store without CloudKit and reports why. If even local
        // fails, it returns `.failed` rather than opening an empty store, so the
        // person sees an error instead of a silently empty app.
        switch ModelContainerFactory.openForLaunch(
            requestedMode: cloud ? .cloud : .local,
            inMemory: inMemory
        ) {
        case let .ready(openedContainer, mode, reason):
            container = openedContainer
            storeMode = mode
            cloudFallbackReason = reason
            storeFailure = nil
        case let .failed(message):
            // The error screen needs a container for SwiftUI to build its view
            // tree, but this throwaway is never read from or written to: no
            // bootstrap, sync, Wallet import, categorization, or background task
            // runs while `storeFailure` is set. Only reopening the real store
            // can clear it, and that never touches or deletes the on-disk store.
            guard let placeholder = try? ModelContainerFactory.make(mode: .local, inMemory: true) else {
                fatalError("Cairn could not create a placeholder store after a failed open: \(message)")
            }
            container = placeholder.container
            storeMode = placeholder.mode
            cloudFallbackReason = nil
            storeFailure = message
        }

        engine = SyncEngine(modelContainer: container)
        #if os(iOS)
        walletEngine = WalletSyncEngine(modelContainer: container)
        #endif

        PowerSource.prepare()
        // Reachability is independent of the store, so it starts even when the
        // recovery screen is up; offline is still worth explaining there.
        // A restored path resumes the sync the offline copy promises.
        connectivity.onBecameOnline = { [weak self] in
            self?.resumeSyncAfterReconnect()
        }
        connectivity.start()
        // A background pass must never run against a store that failed to open.
        if storeFailure == nil {
            BackgroundCategorization.run = { [weak self] in
                await self?.autoCategorize(scope: .background)
            }
            Task { await bootstrap() }
        } else {
            BackgroundCategorization.run = nil
        }
    }

    /// Re-attempts opening the persistent store after a failed launch. A second
    /// failure keeps the recovery screen up; success replaces the placeholder
    /// and runs the normal startup. The on-disk store is only ever opened, never
    /// written to or removed by this.
    func retryStoreOpen() {
        switch ModelContainerFactory.openForLaunch(requestedMode: requestedCloud ? .cloud : .local) {
        case let .ready(openedContainer, mode, reason):
            container = openedContainer
            storeMode = mode
            cloudFallbackReason = reason
            engine = SyncEngine(modelContainer: openedContainer)
            #if os(iOS)
            walletEngine = WalletSyncEngine(modelContainer: openedContainer)
            #endif
            BackgroundCategorization.run = { [weak self] in
                await self?.autoCategorize(scope: .background)
            }
            storeFailure = nil
            Task { await bootstrap() }
        case let .failed(message):
            storeFailure = message
        }
    }

    private func bootstrap() async {
        // Nothing runs against a placeholder store: the recovery screen is up
        // and every store path is skipped until a retry opens the real store.
        guard storeFailure == nil else { return }

        #if DEBUG
        if isSampleMode {
            try? await engine.seedDefaultCategoriesIfNeeded()
            SampleData.populate(context: container.mainContext)
            UserDefaults.standard.set(true, forKey: Self.Keys.onboardingComplete)
            onboardingComplete = true
            // The sample connection has no credential and no server, so running
            // the network path would only report it as unable to sync. Present
            // the synthetic ledger as a healthy, recently synced account.
            await refreshRecurring()
            syncState = .success
            // Still run the deterministic pass so repeat merchants in the
            // synthetic ledger are categorized, as they would be in a real run.
            Task { await autoCategorize() }
            return
        }
        #endif

        // Seeding may briefly wait for the first CloudKit import, so run it
        // alongside the initial sync instead of delaying it. The orphan scan
        // needs the stricter import wait, so it runs alongside too.
        async let seeding: Void = seedDefaultCategoriesWhenReady()
        async let recovery: Void = recoverOrphanedCredentialsWhenReady()
        await refreshBudget()
        migrateCredentials(synchronizable: useCloudKit)
        // A connection interrupted mid-connect, or delivered by iCloud before
        // its credential arrived, can still wear the old "Connecting…" name.
        try? await engine.repairPlaceholderNames()
        if onboardingComplete {
            await syncAll(force: false)
        }
        await seeding
        observeRemoteStoreChanges()
        await recovery
        // Kick off categorization without blocking launch; a large backlog can
        // take minutes on-device.
        await refreshRecurring()
        Task { await autoCategorize() }
    }

    /// Seeds the default categories once. On a CloudKit store this waits briefly
    /// for the first import so a second device doesn't create its own settings
    /// row and category set before the original data arrives.
    private func seedDefaultCategoriesWhenReady() async {
        if storeMode == .cloud {
            await waitForFirstCloudImport()
        }
        try? await engine.seedDefaultCategoriesIfNeeded()
        // Collapse any duplicate set a second device may have seeded before
        // iCloud delivered the first one's categories.
        _ = try? await engine.deduplicateCategories()
    }

    /// Waits until CloudKit reports that a matching event has ended, or the
    /// timeout elapses. On a fresh account nothing may be imported, so the timeout
    /// ensures callers still proceed.
    ///
    /// Category seeding accepts a `.setup` end, because it only needs the store
    /// to have settled. The orphan scan passes `[.import]`: a `.setup` event
    /// ends before any records arrive, so waiting on it would let a credential
    /// look orphaned while its institution is still on the way.
    private func waitForFirstCloudImport(
        timeout: Duration = .seconds(20),
        types: Set<NSPersistentCloudKitContainer.EventType> = [.import, .setup]
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await note in NotificationCenter.default.notifications(
                    named: NSPersistentCloudKitContainer.eventChangedNotification
                ) {
                    guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                        as? NSPersistentCloudKitContainer.Event else { continue }
                    if event.endDate != nil, types.contains(event.type) {
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

    /// Scans for orphaned credentials only once the first CloudKit import has
    /// ended, so a row that is still arriving is never treated as missing. The
    /// duplicate-connection repair takes the same gate: it must see the settled
    /// institution set before it merges anything.
    private func recoverOrphanedCredentialsWhenReady() async {
        if storeMode == .cloud {
            await waitForFirstCloudImport(types: [.import])
        }
        credentialsScanReady = true
        await repairConnections()
        scanForRecoverableCredentials()
    }

    /// Re-runs the orphan scan and the duplicate repair whenever a remote change
    /// lands. A row delivered by iCloud can reference a credential that was
    /// offered before it arrived, or add a duplicate the local device has not
    /// merged yet, so both are re-checked as soon as the store changes.
    private func observeRemoteStoreChanges() {
        remoteChangeTask?.cancel()
        remoteChangeTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: .NSPersistentStoreRemoteChange
            ) {
                guard let self else { return }
                await self.repairConnections()
                self.scanForRecoverableCredentials()
            }
        }
    }

    /// Merges duplicate connections, then re-keys the Access URL of any
    /// credential that merged away onto the survivor, so a device that held only
    /// the retired copy keeps access.
    private func repairConnections() async {
        guard storeFailure == nil, !isRepairingConnections else { return }
        isRepairingConnections = true
        defer { isRepairingConnections = false }

        do {
            let outcome = try await engine.repairDuplicateConnections()
            guard outcome.didChange || !outcome.retiredCredentials.isEmpty else { return }

            let results = CredentialReKey.reKey(
                retirements: outcome.retiredCredentials,
                store: credentials,
                synchronizable: useCloudKit,
                dryRun: Self.skipCredentialReKey
            )
            for result in results {
                if let failure = result.failure {
                    await cairnLog(.warning, failure)
                } else {
                    await cairnLog(.info, result.message)
                }
            }
            await cairnLog(
                .info,
                "Connection repair: groups=\(outcome.duplicateGroups) "
                    + "accounts moved=\(outcome.movedAccounts) merged=\(outcome.mergedAccounts) "
                    + "retired=\(outcome.retiredCredentials.count) unsafe=\(outcome.unsafeMerges)"
            )
            await refreshBudget()
        } catch {
            await cairnLog(.warning, "Connection repair failed: \(error.localizedDescription)")
        }
    }

    /// Debug-only: `-cairn-skip-credential-rekey` runs the duplicate repair but
    /// only logs which local Keychain copy a re-key would keep, so a repair can
    /// be exercised on a copied store without touching its credentials. Always
    /// `false` in Release.
    private static var skipCredentialReKey: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-cairn-skip-credential-rekey")
        #else
        false
        #endif
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
        await cairnLog(.info, "connectInstitution: claiming setup token.")
        do {
            let accessURL = try await client.claim(token: token)
            await cairnLog(.info, "Claimed access URL for \(accessURL.host ?? "unknown host").")
            let adoption = try await establishConnection(
                accessURL: accessURL,
                proposedCredentialID: UUID()
            )
            if case .ambiguous = adoption {
                banner = String(
                    localized: "This SimpleFIN account’s connections match more than one saved connection. Cairn left them as they are, so you’ll keep seeing both until it combines the duplicates automatically."
                )
            }
            return true
        } catch {
            let message: String
            if error is CredentialStoreError {
                message = String(
                    localized: "Cairn couldn’t save this credential to the Keychain, so the connection wasn’t completed. Create a new SimpleFIN token and try again."
                )
            } else {
                message = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            syncState = .failed(message)
            await cairnLog(.error, "connectInstitution failed: \(message)")
            return false
        }
    }

    /// The one path a fresh claim and a reconnect both take: fetch once, decide
    /// whether this Access URL belongs to a credential already stored, store the
    /// secret under the chosen credential id, then apply the fetched data.
    ///
    /// `retiringCredentialID` is the orphaned credential a reconnect is
    /// rebuilding; it is deleted only after the new write and the apply succeed.
    @discardableResult
    private func establishConnection(
        accessURL: URL,
        proposedCredentialID: UUID,
        retiringCredentialID: UUID? = nil
    ) async throws -> ConnectionAdoption {
        let probe = try await engine.probeConnection(
            accessURL: accessURL,
            proposedCredentialID: proposedCredentialID,
            client: client,
            now: Date()
        )
        // Store only once the probe has proved the token works. A setup token is
        // single-use, so a Keychain failure here leaves nothing to clean up and
        // the caller can ask for a new token.
        try storeCredential(accessURL.absoluteString, id: probe.credentialID)
        _ = try await engine.applyClaim(probe, accessURL: accessURL, now: Date())
        if let retiringCredentialID, retiringCredentialID != probe.credentialID {
            try? credentials.delete(id: retiringCredentialID)
        }
        return probe.adoption
    }

    // MARK: - Recovering an orphaned credential

    /// A credential in the Keychain with no `Institution` row. It can be rebuilt
    /// from its Access URL without a new SimpleFIN setup token.
    struct RecoverableCredential: Identifiable, Equatable {
        let id: UUID
        /// The Access URL's host, the only part safe to show. The URL and its
        /// credentials are never displayed.
        let host: String
    }

    /// Reconnects an orphaned credential from its stored Access URL, reusing the
    /// same institution path as a fresh connect and keeping the existing
    /// credential id, so no second copy is stored.
    @discardableResult
    func reconnect(_ credential: RecoverableCredential) async -> Bool {
        // One reconnect per credential. Both taps run on the main actor, so the
        // guard and the insert happen before this pass can suspend.
        guard !reconnectingCredentialIDs.contains(credential.id) else { return false }
        reconnectingCredentialIDs.insert(credential.id)
        defer { reconnectingCredentialIDs.remove(credential.id) }

        guard let secret = try? credentials.secret(for: credential.id),
              let accessURL = URL(string: secret) else {
            banner = String(
                localized: "That saved SimpleFIN connection couldn’t be read. Connect again, or forget it with Not Now."
            )
            return false
        }
        await cairnLog(.info, "Reconnecting saved credential for \(credential.host).")

        // A row may have arrived while this was pending — iCloud delivered it,
        // or another pass created it. The same matching a new claim uses then
        // adopts it instead of inserting a second institution for one
        // credential, so the re-check that used to guard this is no longer
        // needed.
        let id = credential.id
        syncState = .syncing
        do {
            let adoption = try await establishConnection(
                accessURL: accessURL,
                proposedCredentialID: id,
                retiringCredentialID: id
            )
            if case .ambiguous = adoption {
                banner = String(
                    localized: "This saved connection’s banks match more than one saved connection. Cairn left them as they are, so you’ll keep seeing both until it combines the duplicates automatically."
                )
            }
            removeRecoverable(id: id)
            // Reconnecting from onboarding has to leave that screen; from
            // Settings the app is already past it.
            if !onboardingComplete { completeOnboarding() }
            return true
        } catch {
            let message = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            syncState = .failed(message)
            await cairnLog(.error, "Reconnect failed for \(credential.host): \(message)")
            return false
        }
    }

    /// Forgets an orphaned credential. Only called after the person confirms,
    /// because reconnecting later needs a new setup token. Logs the host alone.
    func forget(_ credential: RecoverableCredential) {
        do {
            try credentials.delete(id: credential.id)
            Task { await cairnLog(.info, "Forgot saved credential for \(credential.host).") }
        } catch {
            banner = String(localized: "Couldn’t remove the saved connection: \(error.localizedDescription)")
        }
        removeRecoverable(id: credential.id)
    }

    private func removeRecoverable(id: UUID) {
        recoverableCredentials.removeAll { $0.id == id }
    }

    /// Finds Keychain credentials with no institution and offers to reconnect
    /// them. Runs only after the initial import has settled, so a row still
    /// arriving through iCloud is never mistaken for missing.
    private func scanForRecoverableCredentials() {
        // A remote change can fire before the initial import has settled; a
        // scan then would see a partial institution set.
        guard credentialsScanReady else { return }
        let institutionIDs =
            (try? container.mainContext.fetch(FetchDescriptor<Institution>()))?.map(\.credentialID) ?? []
        let storedIDs = (try? credentials.allIDs()) ?? []
        // The caller has already awaited the first import when the store is
        // cloud-backed, so any institution that is coming has arrived.
        switch CredentialRecovery.decide(
            storedCredentialIDs: storedIDs,
            institutionCredentialIDs: institutionIDs,
            institutionsReady: true
        ) {
        case .none:
            recoverableCredentials = []
        case let .offer(ids):
            recoverableCredentials = ids.compactMap { id in
                guard let secret = try? credentials.secret(for: id),
                      let url = URL(string: secret),
                      let host = url.host, !host.isEmpty else { return nil }
                return RecoverableCredential(id: id, host: host)
            }
        }
        for credential in recoverableCredentials {
            Task { await cairnLog(.info, "Found an orphaned SimpleFIN credential for \(credential.host).") }
        }
    }

    // MARK: - Apple Wallet (FinanceKit)

    /// Whether eligible Wallet accounts exist locally.
    var walletAccountCount: Int {
        #if os(iOS)
        let source = AccountSource.financeKit.rawValue
        return (try? container.mainContext.fetchCount(
            FetchDescriptor<Account>(predicate: #Predicate { $0.sourceRaw == source })
        )) ?? 0
        #else
        return 0
        #endif
    }

    /// Removes Wallet accounts (and their transactions) from this device. It
    /// cannot revoke the system authorization; only Settings can, so it also
    /// remembers the choice and stops reading Wallet until the person connects
    /// again. Cross-platform so a Mac can clear rows it received through iCloud.
    ///
    /// See `docs/wallet-sync.md`: because Wallet rows live in the synced store
    /// while FinanceKit authorization is per device, this deletion cannot stick
    /// on its own — another authorized device imports the same cards again — and
    /// the shape of the fix is still an open decision.
    func disconnectWallet() async {
        // Without this the next sync would re-import the same rows, because
        // FinanceKit access is still granted.
        walletSyncEnabled = false
        // The memory describes rows this device just removed; left behind it
        // would outlive them and scope a later removal against stale keys.
        WalletAccountRetention.forget()

        let source = AccountSource.financeKit.rawValue
        let context = container.mainContext
        let accounts = (try? context.fetch(
            FetchDescriptor<Account>(predicate: #Predicate { $0.sourceRaw == source })
        )) ?? []
        for account in accounts { context.delete(account) }
        do {
            try context.save()
        } catch {
            await cairnLog(
                .error,
                "disconnectWallet: couldn't remove Wallet rows: \(error.localizedDescription)"
            )
        }
        await syncAll(force: false)
    }

    #if os(iOS)
    /// Connects Apple Wallet: asks FinanceKit for access, then imports whatever
    /// the person selected. There is no SimpleFIN token or request budget, so
    /// this never touches a bank server.
    @discardableResult
    func connectWallet() async -> Bool {
        syncState = .syncing
        await cairnLog(.info, "connectWallet: requesting Wallet authorization.")
        do {
            guard try await walletEngine.requestAuthorization() else {
                syncState = .idle
                banner = String(localized: "Cairn wasn’t granted access to Wallet financial data.")
                return false
            }
            walletSyncEnabled = true
            await syncAll(force: false)
            return syncState.errorMessage == nil
        } catch {
            let message = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            syncState = .failed(message)
            await cairnLog(.error, "connectWallet failed: \(message)")
            return false
        }
    }

    /// True when the person has Wallet sync turned on and FinanceKit access is
    /// granted, so Wallet should refresh.
    private func isWalletConnected() async -> Bool {
        guard WalletAvailability.isSupported, walletSyncEnabled else { return false }
        return await walletEngine.isAuthorized()
    }

    /// Refreshes Wallet and returns an error message on failure, so it can join
    /// the same failure list as SimpleFIN.
    private func refreshWallet() async -> String? {
        do {
            let outcome = try await walletEngine.sync(now: Date())
            await cairnLog(
                .info,
                "Wallet: accounts=\(outcome.accountsUpserted) inserted=\(outcome.transactionsInserted) "
                    + "updated=\(outcome.transactionsUpdated) removed=\(outcome.accountsRemoved)"
            )
            return nil
        } catch {
            let reason = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            await cairnLog(.error, "Wallet sync failed: \(reason)")
            return "Apple Wallet: \(reason)"
        }
    }
    #else
    private func isWalletConnected() async -> Bool { false }
    private func refreshWallet() async -> String? { nil }
    #endif

    // MARK: - Sync

    func syncAll(force: Bool) async {
        let context = container.mainContext
        let institutions = (try? context.fetch(FetchDescriptor<Institution>())) ?? []
        // Apple Wallet is refreshed through FinanceKit, so a device with only
        // Wallet accounts still has something to sync.
        let walletReady = await isWalletConnected()

        guard walletReady || !institutions.isEmpty else {
            syncState = .idle
            return
        }

        syncState = .syncing
        await cairnLog(
            .info,
            "syncAll: \(institutions.count) institution(s), force=\(force), wallet=\(walletReady)"
        )
        var failures: [String] = []
        var missingCredentialIDs: [UUID] = []
        var missingCredentialNames: [String] = []
        var skipped = 0
        var reportedBudget = false
        var reportedThrottle = false

        // Institutions that share one Access URL share a credential and a
        // request budget, so sync each credential once and let the fetch fan out
        // to its connections. One failing bank must not stop the rest.
        let credentialsByID = Dictionary(grouping: institutions, by: \.credentialID)
        for (_, group) in credentialsByID {
            guard let institution = group.first(where: { $0.bankConnectionID.isEmpty }) ?? group.first else {
                continue
            }
            let name = institution.name.isEmpty ? "A bank" : institution.name
            do {
                let decision = try await engine.decideSync(
                    institutionID: institution.persistentModelID,
                    force: force,
                    now: Date()
                )
                switch decision {
                case .budgetExhausted:
                    await cairnLog(.warning, "\(name): daily request budget exhausted.")
                    if !reportedBudget {
                        banner = String(localized: "\(name) has reached today’s SimpleFIN request limit. It will sync again tomorrow.")
                        reportedBudget = true
                    }
                case let .throttled(until):
                    await cairnLog(.info, "\(name): throttled until \(until.formatted(date: .omitted, time: .shortened)).")
                    if force, !reportedThrottle {
                        banner = String(localized: "Just synced. Next automatic refresh after \(until.formatted(date: .omitted, time: .shortened)).")
                        reportedThrottle = true
                    }
                case .proceed:
                    guard let secret = try credentials.secret(for: institution.credentialID),
                          let accessURL = URL(string: secret) else {
                        let reason = useCloudKit
                            ? "no stored credential on this device yet (may still arrive via iCloud Keychain)"
                            : "no stored credential on this device (This Device Only, so it can’t arrive later)"
                        await cairnLog(.warning, "\(name): \(reason); skipping.")
                        missingCredentialIDs.append(institution.credentialID)
                        missingCredentialNames.append(name)
                        skipped += 1
                        continue
                    }
                    let outcome = try await engine.performSync(
                        institutionID: institution.persistentModelID,
                        accessURL: accessURL,
                        client: client,
                        now: Date()
                    )
                    await cairnLog(
                        .info,
                        "\(name): synced accounts=\(outcome.accountsUpserted) "
                            + "inserted=\(outcome.transactionsInserted) updated=\(outcome.transactionsUpdated) "
                            + "serverErrors=\(outcome.serverErrors.count)"
                    )
                    failures.append(contentsOf: outcome.serverErrors.map { "\(name): \($0)" })
                    await backfillIfNeeded(
                        institution: institution,
                        accessURL: accessURL,
                        name: name
                    )
                }
            } catch SimpleFINError.institutionGone {
                // The duplicate repair merged this row away between picking it
                // and fetching. Nothing is wrong with the connection, so this
                // is a skip rather than a failure to show.
                await cairnLog(.info, "\(name): skipped; the saved connection was merged or removed by another pass.")
                skipped += 1
            } catch {
                let reason = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
                await cairnLog(.error, "\(name): \(reason)")
                failures.append("\(name): \(reason)")
            }
        }

        if walletReady, let walletFailure = await refreshWallet() {
            failures.append(walletFailure)
        }

        await refreshBudget()
        await cairnLog(.info, "syncAll finished: failures=\(failures.count) skipped=\(skipped)")

        // A credential whose connections are also held by another credential is
        // about to be merged by the repair, so it must not be offered for
        // Reconnect or Remove: doing either would fight the merge.
        let redundant = (try? await engine.redundantCredentialIDs()) ?? []
        if !redundant.isEmpty, !missingCredentialIDs.isEmpty {
            var keptIDs: [UUID] = []
            var keptNames: [String] = []
            for (index, id) in missingCredentialIDs.enumerated() where !redundant.contains(id) {
                keptIDs.append(id)
                if index < missingCredentialNames.count { keptNames.append(missingCredentialNames[index]) }
            }
            missingCredentialIDs = keptIDs
            missingCredentialNames = keptNames
        }

        if let first = failures.first {
            syncState = .failed(first)
        } else if !missingCredentialIDs.isEmpty {
            syncState = Self.missingCredentialState(
                names: missingCredentialNames,
                credentialIDs: missingCredentialIDs,
                cloudBacked: useCloudKit
            )
        } else {
            syncState = .success
        }

        // Categorize in the background so the sync UI finishes immediately.
        Task { await autoCategorize() }
    }

    /// Fetches older transactions for a credential until the institution's
    /// history runs out. Runs once per credential per device, two 45-day pages
    /// per pass, and keeps the daily request budget in mind.
    private func backfillIfNeeded(
        institution: Institution,
        accessURL: URL,
        name: String
    ) async {
        let credentialID = institution.credentialID
        let key = Self.backfillCompleteKey(credentialID)
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        let client = self.client
        let outcome = await engine.backfillHistory(
            institutionID: institution.persistentModelID,
            accessURL: accessURL,
            fetch: { url, start, end in
                try await client.fetchAccounts(
                    accessURL: url,
                    startDate: start,
                    endDate: end,
                    includePending: false
                )
            },
            maxPages: Self.backfillPagesPerPass
        )

        if outcome.reachedFloor {
            UserDefaults.standard.set(true, forKey: key)
        }
        if outcome.pagesFetched > 0 {
            await cairnLog(
                .info,
                "\(name): backfill pages=\(outcome.pagesFetched) "
                    + "inserted=\(outcome.transactionsInserted) updated=\(outcome.transactionsUpdated) "
                    + "floor=\(outcome.reachedFloor)"
            )
        }
        if let failure = outcome.failure {
            await cairnLog(.warning, "\(name): backfill stopped: \(failure)")
        }
    }

    /// Whether one credential's history has already been walked back to its
    /// floor on this device. Device-local: a reinstall repeats the walk once,
    /// which is harmless because the rows are deduplicated.
    private static func backfillCompleteKey(_ credentialID: UUID) -> String {
        "cairn.backfillComplete.\(credentialID.uuidString)"
    }

    /// How many older pages one sync pass may fetch for a credential. Two pages
    /// plus the primary sync stays far inside the 24-requests-per-day budget.
    private static let backfillPagesPerPass = 2

    /// The notice shown when one or more saved connections have no credential on
    /// this device. A cloud-backed store may still deliver it through iCloud
    /// Keychain; a This-Device-Only store never will, so say so plainly instead
    /// of blaming iCloud Keychain.
    private static func missingCredentialState(
        names: [String],
        credentialIDs: [UUID],
        cloudBacked: Bool
    ) -> SyncState {
        let count = credentialIDs.count
        let title = count == 1
            ? "A connection can’t sync yet"
            : "\(count) connections can’t sync yet"
        let list = names.isEmpty ? "A saved connection" : names.joined(separator: ", ")
        let detail = cloudBacked
            ? "No credential on this device for \(list). If you connected it on another device, iCloud "
                + "Keychain may still be delivering it; otherwise remove it and connect again with a new token."
            : "No credential on this device for \(list). This Device Only means it will never arrive, so "
                + "remove it and connect again with a new token."
        return .waiting(title: title, detail: detail, credentialIDs: credentialIDs)
    }

    func refreshBudget() async {
        remainingBudget = (try? await engine.minimumRemainingBudget(now: Date())) ?? SyncEngine.dailyRequestLimit
    }

    // MARK: - Institution management

    /// Revokes one SimpleFIN Access URL. Because a single Access URL can back
    /// several connections (banks), every institution sharing its credential is
    /// removed together — otherwise the next sync would recreate them.
    func disconnect(_ institution: Institution) async {
        await removeConnections(credentialIDs: [institution.credentialID])
    }

    /// Removes every saved connection that shares one of these credentials,
    /// along with the credentials themselves. Used by the disconnect action and
    /// by the notice for connections whose credential never arrived.
    ///
    /// A connection another credential still reaches has its accounts moved
    /// there first, so a removal never takes data that a surviving connection
    /// needs. Only credentials with no institution left have their Keychain item
    /// deleted.
    func removeConnections(credentialIDs: [UUID]) async {
        do {
            let outcome = try await engine.removeConnections(credentialIDs: Set(credentialIDs))
            for credentialID in outcome.retiredCredentialIDs {
                try? credentials.delete(id: credentialID)
            }
            if outcome.retainedInstitutions > 0 {
                banner = String(localized: "Some accounts are still used by another saved connection, so they were kept.")
            }
            await refreshBudget()
        } catch {
            banner = String(localized: "Couldn’t remove the connection: \(error.localizedDescription)")
            return
        }
        await syncAll(force: false)
    }

    // MARK: - Manual accounts & import

    /// Creates a manual account for data SimpleFIN can't reach. Returns the new
    /// account so a caller can continue a flow, such as importing into it.
    @discardableResult
    func createManualAccount(
        name: String,
        type: AccountType,
        openingBalanceMinorUnits: Int64,
        currency: Currency
    ) -> Account {
        let account = Account(
            bankAccountID: "manual-\(UUID().uuidString)",
            name: name,
            currency: currency
        )
        account.sourceRaw = AccountSource.manual.rawValue
        account.accountTypeRaw = type.rawValue
        account.startingBalanceMinorUnits = openingBalanceMinorUnits
        account.balanceMinorUnits = openingBalanceMinorUnits
        account.balanceDate = .now
        container.mainContext.insert(account)
        try? container.mainContext.save()
        return account
    }

    /// Imports parsed CSV rows into an account, returning what was inserted.
    func importTransactions(
        _ imports: [ImportedTransaction],
        into account: Account
    ) async -> SyncEngine.ImportOutcome? {
        do {
            let outcome = try await engine.importTransactions(imports, intoAccountID: account.persistentModelID)
            Task { await autoCategorize() }
            return outcome
        } catch {
            banner = String(localized: "Import failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Categorization

    /// Runs categorization automatically: rules and learned history first, then
    /// the on-device Apple Intelligence model in batches until the backlog is
    /// cleared (or a per-session cap is reached).
    ///
    /// Safe to call often; overlapping calls are coalesced, and the model only
    /// ever looks at merchants it hasn't placed before.
    func autoCategorize(scope: CategorizationScope = .foreground) async {
        guard !isAutoCategorizing else { return }
        isAutoCategorizing = true
        categorizationState = .running
        defer {
            isAutoCategorizing = false
            modelProgress = nil
        }

        let ruleOutcome = await recategorize()
        let ruleCategorized = ruleOutcome?.categorized ?? 0
        var aiCategorized = 0
        var modelCalls = 0
        var merchantsAsked = 0
        modelPauseReason = nil

        if useAppleIntelligence, AppleIntelligenceCategorizer.isAvailable {
            if !modelWorkAllowed(for: scope) {
                // Recorded so the UI can say why nothing moved this time.
                modelPauseReason = powerDecision(for: scope)
            }
            await refreshCategorizationCounts()
            let total = categorizationCounts.pendingModel
            if total > 0, modelWorkAllowed(for: scope) {
                modelProgress = ModelProgress(processed: 0, total: total)
                // One model call covers a whole batch of distinct merchants,
                // sized to this device's context window.
                let batchSize = AppleIntelligenceCategorizer.recommendedMerchantBatchSize
                let callCap = scope == .foreground ? Self.foregroundModelCallCap : Self.backgroundModelCallCap
                var calls = 0
                while calls < callCap, !Task.isCancelled {
                    // Re-check each time so a device that gets hot, or is
                    // unplugged, stops promptly instead of pushing through.
                    guard modelWorkAllowed(for: scope) else {
                        modelPauseReason = powerDecision(for: scope)
                        break
                    }
                    guard let outcome = await runAppleIntelligenceBatch(limit: batchSize) else { break }
                    aiCategorized += outcome.categorized
                    modelCalls += outcome.modelCalls
                    merchantsAsked += outcome.merchantsAsked
                    calls += 1
                    let processed = max(0, total - outcome.remaining)
                    modelProgress = ModelProgress(processed: min(processed, total), total: total)
                    // Stop as soon as the model stops making progress or reports a
                    // throttle; either way it is not worth continuing right now.
                    if outcome.attempted == 0 || outcome.throttled || outcome.remaining == 0 { break }
                    // Yield between batches so the app stays responsive.
                    try? await Task.sleep(for: .milliseconds(120))
                }
            }
        }

        await refreshCategorizationCounts()
        await refreshRecurring()
        await cairnLog(
            .info,
            "Auto-categorize(\(scope == .background ? "background" : "foreground")): "
                + "rules=\(ruleCategorized) ai=\(aiCategorized) calls=\(modelCalls) "
                + "merchants=\(merchantsAsked) pending=\(categorizationCounts.pendingModel) "
                + "unresolved=\(categorizationCounts.unresolved)"
        )
        categorizationState = .finished(
            categorized: ruleCategorized + aiCategorized,
            counts: categorizationCounts
        )
    }

    /// Whether the on-device model may run right now. Rules and memory always
    /// run; only the expensive model pass is gated.
    private func modelWorkAllowed(for scope: CategorizationScope) -> Bool {
        powerDecision(for: scope) == .proceed
    }

    private func powerDecision(for scope: CategorizationScope) -> CategorizationPower.Decision {
        CategorizationPower.evaluate(
            thermalState: ProcessInfo.processInfo.thermalState,
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            isOnExternalPower: PowerSource.isOnExternalPower,
            requiresExternalPower: scope == .background && categorizeOnlyWhileCharging
        )
    }

    /// Rules plus merchant memory. Fast and deterministic, always on-device.
    @discardableResult
    func recategorize() async -> SyncEngine.RecategorizeOutcome? {
        do {
            return try await engine.recategorize()
        } catch {
            await cairnLog(.warning, "Rule categorization failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Re-runs the deterministic pass after the person adds, edits, removes,
    /// disables, or reorders a rule, so existing transactions pick the change
    /// up immediately instead of waiting for the next sync.
    @discardableResult
    func applyRules() async -> SyncEngine.RecategorizeOutcome? {
        do {
            let outcome = try await engine.applyRules()
            await refreshCategorizationCounts()
            await refreshRecurring()
            return outcome
        } catch {
            await cairnLog(.warning, "Couldn't apply rules: \(error.localizedDescription)")
            return nil
        }
    }

    /// Updates the counts shown in Insights.
    func refreshCategorizationCounts() async {
        categorizationCounts = (try? await engine.categorizationCounts()) ?? SyncEngine.CategorizationCounts()
    }

    /// Recomputes detected subscriptions and regular payments entirely
    /// on-device. Cheap enough to run after a sync or a flag change; it only
    /// groups transactions already in the local store.
    ///
    /// Runs on the engine's context rather than the main context: the detector
    /// reads transaction relationships, and a repair or sync running in the
    /// background can delete a duplicate row mid-pass. Mapping a stale
    /// main-context copy would trap in SwiftData.
    func refreshRecurring() async {
        recurringSeries = (try? await engine.recurringSeries()) ?? []
    }

    /// Called right after the person changes a transaction's category, so the
    /// same merchant's other automatic rows pick the correction up immediately.
    func propagateUserCategory(of transactionID: PersistentIdentifier) {
        Task {
            do {
                _ = try await engine.propagateUserCategory(transactionID: transactionID)
            } catch {
                await cairnLog(
                    .warning,
                    "Couldn't apply category to similar merchants: \(error.localizedDescription)"
                )
            }
            await refreshCategorizationCounts()
            await refreshRecurring()
        }
    }

    private func runAppleIntelligenceBatch(limit: Int = 12) async -> SyncEngine.RecategorizeOutcome? {
        do {
            return try await engine.appleIntelligenceCategorizeBatch(limit: limit)
        } catch {
            await cairnLog(.warning, "On-device categorization pass failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Lock

    func setAppLock(enabled: Bool) {
        lock.setEnabled(enabled)
        if enabled, !lock.isEnabled {
            banner = String(localized: "Set a device passcode or password first — the app lock needs one.")
        }
        UserDefaults.standard.set(lock.isEnabled, forKey: Self.Keys.appLockEnabled)
        Task { try? await engine.setAppLock(enabled: lock.isEnabled) }
    }

    // MARK: - Export & deletion

    func exportData(json: Bool) async -> Data? {
        do {
            return json ? try await engine.exportJSON() : Data(try await engine.exportCSV().utf8)
        } catch {
            banner = String(localized: "Export failed: \(error.localizedDescription)")
            return nil
        }
    }

    func deleteAllData() async {
        do {
            try await engine.deleteAllData()
        } catch {
            // Never claim success when the store refused. A partial delete with a
            // reassuring message is worse than an honest failure.
            await cairnLog(.error, "Delete All Data failed: \(error.localizedDescription)")
            banner = String(localized: "Cairn couldn’t delete everything: \(error.localizedDescription)")
            return
        }

        do {
            try credentials.deleteAll()
        } catch {
            await cairnLog(.warning, "Couldn’t clear stored credentials: \(error.localizedDescription)")
            banner = String(localized: "Data deleted, but a stored bank credential couldn’t be removed.")
        }

        UserDefaults.standard.removeObject(forKey: Self.Keys.onboardingComplete)
        // Deliberately keep the storage preference: a "This Device Only" user
        // who deletes their data must not be silently switched to iCloud. The
        // app lock is part of "everything", so it is turned off and forgotten.
        UserDefaults.standard.removeObject(forKey: Self.Keys.appLockEnabled)
        lock.setEnabled(false)
        // Wallet access is granted to the system rather than to us, so it can't
        // be revoked here. Leaving the flag on would quietly re-import Apple Card
        // data after "delete everything", so connecting again is explicit, like
        // re-entering a SimpleFIN token.
        walletSyncEnabled = false
        WalletAccountRetention.forget()

        await DiagnosticsLog.shared.clear()
        recurringSeries = []
        recoverableCredentials = []
        onboardingComplete = false
        remainingBudget = SyncEngine.dailyRequestLimit
        syncState = .idle
    }

    /// Records the storage choice made during onboarding. The container is
    /// opened at launch, so the store itself changes on the next start — but
    /// nothing has been uploaded before this point, because the default is
    /// local.
    func chooseStoreMode(cloud: Bool) {
        guard cloud != useCloudKit else { return }
        UserDefaults.standard.set(cloud, forKey: Self.Keys.useCloudKit)
        useCloudKit = cloud
        migrateCredentials(synchronizable: cloud)
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
            ? String(localized: "iCloud Sync will be enabled the next time you open Cairn.")
            : String(
                localized: "This Device Only takes effect the next time you open Cairn. Cairn now reads the credential from this device; the copy in iCloud Keychain is left for your other devices."
            )
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
                banner = String(localized: "iCloud Keychain sync isn’t available here, so the credential is stored on this device only.")
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
        // Rewrite only what differs. Rewriting a synced item pushes a new revision
        // through iCloud Keychain to every device, so doing it unconditionally
        // would generate sync traffic from every device on every launch. The one
        // exception is a device-only item still carrying the older, backup-
        // migratable accessibility class, which is refreshed once and then left
        // alone.
        for institution in institutions {
            let id = institution.credentialID
            guard let secret = try? credentials.secret(for: id) else { continue }
            // Ask about each copy separately: after switching from iCloud to This
            // Device Only both exist, and a lookup that ignores synchronizability
            // can return the iCloud copy — which would make the local copy look
            // wrong, and rewrite it, on every launch.
            let deviceOnly = try? credentials.accessibility(for: id, synchronizable: false)
            let synced = try? credentials.accessibility(for: id, synchronizable: true)
            guard CredentialMigration.needsRewrite(
                wantedSynchronizable: synchronizable,
                deviceOnlyAccessibility: deviceOnly,
                syncedAccessibility: synced
            ) else {
                continue
            }
            do {
                try credentials.store(secret, id: id, synchronizable: synchronizable)
            } catch {
                let name = institution.name.isEmpty ? "an institution" : institution.name
                banner = String(localized: "Couldn’t update iCloud Keychain sync for \(name): \(error.localizedDescription)")
            }
        }
    }
}
