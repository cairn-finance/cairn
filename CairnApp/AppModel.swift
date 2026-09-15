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

    /// Automatic categorization progress, surfaced in Insights.
    enum CategorizationState: Equatable {
        case idle
        case running
        case finished(categorized: Int, counts: SyncEngine.CategorizationCounts)
    }

    private(set) var categorizationState: CategorizationState = .idle
    private(set) var categorizationCounts = SyncEngine.CategorizationCounts()

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

    @ObservationIgnored private var isAutoCategorizing = false

    init(inMemory: Bool = false) {
        let defaults = UserDefaults.standard
        // New installs default to iCloud Sync so the onboarding default works
        // without a relaunch; cloud falls back to local when unavailable.
        let cloud = (defaults.object(forKey: Self.Keys.useCloudKit) as? Bool) ?? true
        useCloudKit = cloud
        requestedCloud = cloud
        onboardingComplete = defaults.bool(forKey: Self.Keys.onboardingComplete)
        appLockEnabled = defaults.bool(forKey: Self.Keys.appLockEnabled)
        useAppleIntelligence = (defaults.object(forKey: Self.Keys.useAppleIntelligence) as? Bool) ?? true

        #if DEBUG
        let sampleMode = ProcessInfo.processInfo.arguments.contains(SampleData.launchArgument)
        #else
        let sampleMode = false
        #endif
        credentials = (inMemory || sampleMode) ? InMemoryCredentialStore() : KeychainCredentialStore()
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
        // Kick off categorization without blocking launch; a large backlog can
        // take minutes on-device.
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
        await cairnLog(.info, "connectInstitution: claiming setup token.")
        do {
            let accessURL = try await client.claim(token: token)
            await cairnLog(.info, "Claimed access URL for \(accessURL.host ?? "unknown host").")
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
            await cairnLog(.error, "connectInstitution failed: \(message)")
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
        await cairnLog(.info, "syncAll: \(institutions.count) institution(s), force=\(force)")
        var failures: [String] = []
        var missingCredentialIDs: [UUID] = []
        var missingCredentialNames: [String] = []
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
                        banner = "\(name) has reached today’s SimpleFIN request limit. It will sync again tomorrow."
                        reportedBudget = true
                    }
                case let .throttled(until):
                    await cairnLog(.info, "\(name): throttled until \(until.formatted(date: .omitted, time: .shortened)).")
                    if force, !reportedThrottle {
                        banner = "Just synced. Next automatic refresh after \(until.formatted(date: .omitted, time: .shortened))."
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
                }
            } catch {
                let reason = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
                await cairnLog(.error, "\(name): \(reason)")
                failures.append("\(name): \(reason)")
            }
        }

        await refreshBudget()
        await cairnLog(.info, "syncAll finished: failures=\(failures.count) skipped=\(missingCredentialIDs.count)")
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
    func removeConnections(credentialIDs: [UUID]) async {
        let context = container.mainContext
        for credentialID in credentialIDs {
            let siblings = (try? context.fetch(
                FetchDescriptor<Institution>(predicate: #Predicate { $0.credentialID == credentialID })
            )) ?? []
            try? credentials.delete(id: credentialID)
            siblings.forEach(context.delete)
        }
        try? context.save()
        await syncAll(force: false)
    }

    // MARK: - Manual accounts & import

    /// Creates a manual account for data SimpleFIN can't reach.
    func createManualAccount(
        name: String,
        type: AccountType,
        openingBalanceMinorUnits: Int64,
        currency: Currency
    ) {
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
            banner = "Import failed: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Categorization

    /// Runs categorization automatically: rules and learned history first, then
    /// the on-device Apple Intelligence model in batches until the backlog is
    /// cleared (or a per-session cap is reached).
    ///
    /// Safe to call often; overlapping calls are coalesced, and the model only
    /// ever looks at transactions it hasn't tried before.
    func autoCategorize() async {
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

        if useAppleIntelligence, AppleIntelligenceCategorizer.isAvailable {
            await refreshCategorizationCounts()
            let total = categorizationCounts.pendingModel
            if total > 0 {
                modelProgress = ModelProgress(processed: 0, total: total)
                var processed = 0
                // Generous cap so a large backlog clears in one session, while
                // still yielding to keep the device responsive.
                let sessionCap = 200
                while processed < sessionCap, !Task.isCancelled {
                    guard let outcome = await runAppleIntelligenceBatch(limit: 10) else { break }
                    aiCategorized += outcome.categorized
                    processed += outcome.attempted
                    modelProgress = ModelProgress(processed: min(processed, total), total: total)
                    if outcome.attempted == 0 { break }
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
        }

        await refreshCategorizationCounts()
        await cairnLog(
            .info,
            "Auto-categorize: rules=\(ruleCategorized) ai=\(aiCategorized) "
                + "pending=\(categorizationCounts.pendingModel) unresolved=\(categorizationCounts.unresolved)"
        )
        categorizationState = .finished(
            categorized: ruleCategorized + aiCategorized,
            counts: categorizationCounts
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

    /// Updates the counts shown in Insights.
    func refreshCategorizationCounts() async {
        categorizationCounts = (try? await engine.categorizationCounts()) ?? SyncEngine.CategorizationCounts()
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
