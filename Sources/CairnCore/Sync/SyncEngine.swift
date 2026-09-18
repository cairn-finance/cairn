import Foundation
import SwiftData

/// Identifies a transaction by the fields the store actually persists, so a row
/// can be re-fetched after an `await`.
///
/// `PersistentIdentifier` plus `isDeleted` is not enough: that flag only reflects
/// deletions made in the same context, so batch deletes and deletions made from
/// the main context slip through.
struct RowKey: Hashable {
    let bankTransactionID: String
    let accountIDIndex: String

    init(bankTransactionID: String, accountIDIndex: String) {
        self.bankTransactionID = bankTransactionID
        self.accountIDIndex = accountIDIndex
    }

    init(_ transaction: LedgerTransaction) {
        self.init(
            bankTransactionID: transaction.bankTransactionID,
            accountIDIndex: transaction.accountIDIndex
        )
    }
}

/// A summary of one sync pass, surfaced to the UI.
public struct SyncOutcome: Sendable, Equatable {
    public var accountsUpserted: Int = 0
    public var transactionsInserted: Int = 0
    public var transactionsUpdated: Int = 0
    public var pendingPromoted: Int = 0
    public var stalePendingRemoved: Int = 0
    public var serverErrors: [String] = []
    public var finishedAt: Date = .now

    public init() {}

    public var hadChanges: Bool {
        accountsUpserted > 0 || transactionsInserted > 0 || transactionsUpdated > 0
            || pendingPromoted > 0 || stalePendingRemoved > 0
    }
}

/// Whether a sync should run right now.
public enum SyncDecision: Sendable, Equatable {
    case proceed
    case throttled(until: Date)
    case budgetExhausted
}

/// The background persistence actor. All SwiftData writes happen here, off the
/// main thread; SwiftUI reads through `@Query` on the main context and CloudKit
/// propagates changes between devices.
@ModelActor
public actor SyncEngine {
    /// SimpleFIN Bridge's documented daily request ceiling per token. Kept
    /// conservative because every signed-in device shares one Access URL.
    public static let dailyRequestLimit = 24
    /// SimpleFIN rejects a transaction range longer than 90 days, so the first
    /// sync backfills just under that.
    public static let initialBackfillDays = 89
    /// Hard ceiling for any requested range, so an incremental sync after a long
    /// gap is clamped instead of being rejected.
    public static let maximumRequestDays = 89
    public static let syncOverlapDays = 7
    public static let stalePendingThreshold = 2

    /// The start date to request for a sync, clamped so the range never exceeds
    /// SimpleFIN's 90-day limit. A first sync backfills the full allowed window;
    /// later syncs re-request a short overlap to catch late-posted transactions.
    public static func requestStartDate(
        lastSyncDate: Date?,
        now: Date,
        calendar: Calendar = .current
    ) -> Date {
        let desired: Date
        if let lastSyncDate,
           let overlap = calendar.date(byAdding: .day, value: -syncOverlapDays, to: lastSyncDate) {
            desired = overlap
        } else {
            desired = calendar.date(byAdding: .day, value: -initialBackfillDays, to: now) ?? now
        }
        let earliestAllowed = calendar.date(byAdding: .day, value: -maximumRequestDays, to: now) ?? now
        return max(desired, earliestAllowed)
    }

    // MARK: - Settings

    public func settings() throws -> AppSettings {
        try loadOrCreateSettings()
    }

    /// Loads the app-wide settings singleton, collapsing duplicates that can
    /// appear when a second device creates its own row before iCloud delivers
    /// the first one.
    private func loadOrCreateSettings() throws -> AppSettings {
        let descriptor = FetchDescriptor<AppSettings>(
            predicate: #Predicate { $0.key == "default" },
            sortBy: [SortDescriptor(\.modifiedAt)]
        )
        let existing = try modelContext.fetch(descriptor)
        if let first = existing.first {
            if existing.count > 1 {
                for duplicate in existing.dropFirst() {
                    modelContext.delete(duplicate)
                }
                try modelContext.save()
            }
            return first
        }
        let settings = AppSettings()
        modelContext.insert(settings)
        try modelContext.save()
        return settings
    }

    /// Resets an institution's daily request counter when the day rolls over.
    private func rollRequestCounterIfNeeded(_ institution: Institution, now: Date, calendar: Calendar) {
        guard let last = institution.dailyRequestDate,
              calendar.isDate(last, inSameDayAs: now) else {
            institution.dailyRequestCount = 0
            institution.dailyRequestDate = now
            return
        }
    }

    public func decideSync(
        institutionID: PersistentIdentifier,
        force: Bool,
        now: Date,
        calendar: Calendar = .current
    ) throws -> SyncDecision {
        guard let institution = liveModel(Institution.self, institutionID) else {
            throw SimpleFINError.transport("This institution is no longer in the local database.")
        }
        rollRequestCounterIfNeeded(institution, now: now, calendar: calendar)
        let settings = try loadOrCreateSettings()

        if institution.dailyRequestCount >= Self.dailyRequestLimit {
            return .budgetExhausted
        }

        if !force, let last = institution.lastSuccessfulFetch,
           let interval = calendar.date(
               byAdding: .hour,
               value: settings.minimumRefreshIntervalHours,
               to: last
           ), now < interval {
            return .throttled(until: interval)
        }

        return .proceed
    }

    /// The smallest number of requests left today across all institutions, so
    /// the UI never overstates the remaining budget. Institutions that share an
    /// Access URL share one budget, so collapse each credential to its highest
    /// request count before taking the minimum.
    public func minimumRemainingBudget(now: Date, calendar: Calendar = .current) throws -> Int {
        let institutions = try modelContext.fetch(FetchDescriptor<Institution>())
        guard !institutions.isEmpty else { return Self.dailyRequestLimit }
        var usedByCredential: [UUID: Int] = [:]
        for institution in institutions {
            rollRequestCounterIfNeeded(institution, now: now, calendar: calendar)
            usedByCredential[institution.credentialID] = max(
                usedByCredential[institution.credentialID] ?? 0,
                institution.dailyRequestCount
            )
        }
        return usedByCredential.values
            .map { max(0, Self.dailyRequestLimit - $0) }
            .min() ?? Self.dailyRequestLimit
    }

    // MARK: - Sync

    public func performSync(
        institutionID: PersistentIdentifier,
        accessURL: URL,
        client: SimpleFINClient,
        now: Date,
        calendar: Calendar = .current
    ) async throws -> SyncOutcome {
        guard let institution = liveModel(Institution.self, institutionID) else {
            throw SimpleFINError.transport("This institution is no longer in the local database.")
        }

        rollRequestCounterIfNeeded(institution, now: now, calendar: calendar)

        let label = institution.name.isEmpty ? "institution" : institution.name
        // Read everything off the row before the first await, then let it go.
        let lastSyncDescription = institution.lastSyncDate.map(Self.iso) ?? "never"
        let candidates = Self.candidateStartDates(
            lastSyncDate: institution.lastSyncDate,
            now: now,
            calendar: calendar
        )
        await cairnLog(.info, "Sync started for \(label). lastSync=\(lastSyncDescription)")

        var lastError: any Error = SimpleFINError.httpStatus(-1)
        for (index, startDate) in candidates.enumerated() {
            let isLast = index == candidates.count - 1
            let windowDays = Int(now.timeIntervalSince(startDate) / 86_400)
            await cairnLog(.info, "Requesting a \(windowDays)-day window (attempt \(index + 1) of \(candidates.count)).")
            // Re-resolve: a previous iteration's network call may have outlived
            // the row, and writing to a deleted model traps.
            guard let live = liveModel(Institution.self, institutionID) else {
                throw SimpleFINError.transport("This institution is no longer in the local database.")
            }
            live.dailyRequestCount += 1

            do {
                let accountSet = try await client.fetchAccounts(
                    accessURL: accessURL,
                    startDate: startDate,
                    includePending: true
                )

                // If the server rejects the range, try a shorter window before
                // giving up, so the app self-heals if the limit differs.
                if let rangeMessage = accountSet.errors.first(where: { Self.isRangeLimitError($0.message) }), !isLast {
                    await cairnLog(.warning, "Range rejected: \(rangeMessage). Retrying with a shorter window.")
                    lastError = SimpleFINError.serverReported(accountSet.errors)
                    continue
                }

                return try await applyAccountSet(
                    accountSet,
                    institutionID: institutionID,
                    accessURL: accessURL,
                    now: now,
                    calendar: calendar
                )
            } catch {
                if Self.isRangeLimitError(error), !isLast {
                    await cairnLog(.warning, "Range rejected: \(Self.describe(error)). Retrying with a shorter window.")
                    lastError = error
                    continue
                }
                let message = Self.describe(error)
                await cairnLog(.error, "Sync failed: \(message)")
                // The fetch can outlive the connection; only write if it is still
                // there.
                if let live = liveModel(Institution.self, institutionID) {
                    live.lastSyncError = message
                    // The very first fetch failed, so the connection still wears
                    // its stand-in name; make sure it is at least readable.
                    if Self.isPlaceholderName(live.name, for: accessURL) {
                        live.name = Self.fallbackName(for: accessURL)
                    }
                    try? modelContext.save()
                }
                throw error
            }
        }

        // Every candidate window was rejected.
        let message = Self.describe(lastError)
        await cairnLog(.error, "Sync exhausted all windows: \(message)")
        if let live = liveModel(Institution.self, institutionID) {
            live.lastSyncError = message
            if Self.isPlaceholderName(live.name, for: accessURL) {
                live.name = Self.fallbackName(for: accessURL)
            }
            try? modelContext.save()
        }
        throw lastError
    }

    /// Applies a successfully fetched account set: connection metadata, account
    /// and transaction upserts, and the sync cursor.
    ///
    /// One SimpleFIN Access URL can expose several connections (for example, a
    /// bridge account with a checking, savings, and brokerage login). Each
    /// connection gets its own `Institution` sharing the owner's credential, so
    /// every bank shows up separately and its accounts stay together.
    func applyAccountSet(
        _ accountSet: SimpleFINAccountSet,
        institutionID: PersistentIdentifier,
        accessURL: URL,
        now: Date,
        calendar: Calendar = .current
    ) async throws -> SyncOutcome {
        guard let owner = liveModel(Institution.self, institutionID) else {
            throw SimpleFINError.transport("This institution is no longer in the local database.")
        }

        var outcome = SyncOutcome()
        let hadServerErrors = !accountSet.errors.isEmpty

        let owners = try institutions(forConnections: accountSet.connections, owner: owner)

        // Never leave a brand-new connection wearing its stand-in name.
        if Self.isPlaceholderName(owner.name, for: accessURL),
           let first = owners.values.first {
            owner.name = first.name.isEmpty ? Self.fallbackName(for: accessURL) : first.name
        }

        // Attach per-connection metadata, clearing stale errors; then apply any
        // errors to the connection they name (or the owner if unspecified).
        for connection in accountSet.connections {
            guard let target = owners[connection.id] else { continue }
            apply(connection, to: target)
            target.lastSyncError = nil
        }
        for error in accountSet.errors {
            let target = error.connectionID.flatMap { owners[$0] } ?? owner
            target.lastSyncError = error.message
        }
        outcome.serverErrors = accountSet.errors.map(\.message)

        // Accounts synced before connections were split out may still sit on the
        // connection-less holder; move them onto their real connection. Accounts
        // already owned by another connection are left untouched.
        for simpleAccount in accountSet.accounts {
            let target = owners[simpleAccount.connectionID] ?? owner
            if let existing = try accountByBankID(simpleAccount.id),
               existing.institution == nil || existing.institution === owner {
                existing.institution = target
            }
        }

        let ruleSnapshots = try loadRuleSnapshots()

        for simpleAccount in accountSet.accounts {
            let target = owners[simpleAccount.connectionID] ?? owner
            let account = try upsertAccount(simpleAccount, institution: target, now: now, outcome: &outcome)
            try reconcileTransactions(
                simpleAccount.transactions,
                account: account,
                rules: ruleSnapshots,
                now: now,
                calendar: calendar,
                outcome: &outcome
            )
            try recordSnapshot(for: account, now: now, calendar: calendar)
        }

        // Only advance the sync cursor when the fetch was clean; otherwise
        // retry the same window next time. A single fetch covers every
        // connection sharing this credential, so mark them all as synced.
        if !hadServerErrors {
            var synced = Set(owners.values.map(\.persistentModelID))
            synced.insert(owner.persistentModelID)
            for sibling in try siblingInstitutions(credentialID: owner.credentialID)
            where synced.contains(sibling.persistentModelID) {
                sibling.lastSyncDate = now
                sibling.lastSuccessfulFetch = now
            }
        }

        try modelContext.save()
        outcome.finishedAt = now
        await cairnLog(
            .info,
            "Sync ok: accounts=\(accountSet.accounts.count) inserted=\(outcome.transactionsInserted) "
                + "updated=\(outcome.transactionsUpdated) serverErrors=\(outcome.serverErrors.count)"
        )
        return outcome
    }

    /// Finds or creates one `Institution` per connection returned by an Access
    /// URL. Each connection gets a child institution that shares the owner's
    /// `credentialID`; the owner itself stays connection-less and acts as the
    /// credential holder (and is hidden in the UI once it has children).
    private func institutions(
        forConnections connections: [SimpleFINConnection],
        owner: Institution
    ) throws -> [String: Institution] {
        let credentialID = owner.credentialID
        let siblings = try siblingInstitutions(credentialID: credentialID)
        var byConnection: [String: Institution] = [:]
        for sibling in siblings where !sibling.bankConnectionID.isEmpty {
            byConnection[sibling.bankConnectionID] = sibling
        }

        var result: [String: Institution] = [:]
        for connection in connections {
            if let existing = byConnection[connection.id] {
                result[connection.id] = existing
            } else {
                let created = Institution(
                    bankConnectionID: connection.id,
                    name: connection.name,
                    credentialID: credentialID
                )
                modelContext.insert(created)
                byConnection[connection.id] = created
                result[connection.id] = created
            }
        }
        return result
    }

    /// One account by its connection-scoped SimpleFIN id, if it exists.
    private func accountByBankID(_ id: String) throws -> Account? {
        var descriptor = FetchDescriptor<Account>(predicate: #Predicate { $0.bankAccountID == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// Every institution that shares one SimpleFIN Access URL.
    private func siblingInstitutions(credentialID: UUID) throws -> [Institution] {
        try modelContext.fetch(
            FetchDescriptor<Institution>(predicate: #Predicate { $0.credentialID == credentialID })
        )
    }

    private func apply(_ connection: SimpleFINConnection, to institution: Institution) {
        institution.name = connection.name
        institution.orgID = connection.organizationID
        institution.orgURL = connection.organizationURL
        if !connection.simpleFINURL.isEmpty {
            institution.sfinURL = connection.simpleFINURL
        }
        institution.bankConnectionID = connection.id
    }

    /// A readable name for an institution when SimpleFIN never returned one.
    public static func fallbackName(for accessURL: URL) -> String {
        if let host = accessURL.host, !host.isEmpty {
            return host
        }
        return "Institution"
    }

    /// Whether a name is still a stand-in rather than the bank's own name: the
    /// Access URL host we knew before the first fetch, the legacy
    /// "Connecting…" label, or nothing at all. Such a name is safe to replace
    /// once SimpleFIN reports the real connection.
    static func isPlaceholderName(_ name: String, for accessURL: URL) -> Bool {
        name.isEmpty || name == "Connecting…" || name == fallbackName(for: accessURL)
    }

    /// Renames any connection still carrying the legacy "Connecting…"
    /// placeholder. A connection only gets its real name from a fetch, so one
    /// whose credential never reached this device (or that was interrupted
    /// mid-connect) would otherwise show "Connecting…" forever. Prefer a sibling
    /// connection's name, then the stored Access URL host.
    public func repairPlaceholderNames() async throws {
        let descriptor = FetchDescriptor<Institution>(
            predicate: #Predicate { $0.name == "Connecting…" }
        )
        let placeholders = try modelContext.fetch(descriptor)
        guard !placeholders.isEmpty else { return }

        for institution in placeholders {
            let siblings = try siblingInstitutions(credentialID: institution.credentialID)
            if let named = siblings.first(where: { !$0.bankConnectionID.isEmpty && !$0.name.isEmpty }) {
                institution.name = named.name
            } else if let url = URL(string: institution.sfinURL), let host = url.host, !host.isEmpty {
                institution.name = host
            } else {
                institution.name = "New connection"
            }
        }
        try modelContext.save()
        await cairnLog(.info, "Renamed \(placeholders.count) placeholder connection(s).")
    }

    /// Windows to try when the server rejects a range, longest first.
    static let backfillFallbackDays = [89, 30, 7]

    /// Start dates to attempt, longest permitted window first. An incremental
    /// sync only needs its overlap window.
    static func candidateStartDates(
        lastSyncDate: Date?,
        now: Date,
        calendar: Calendar = .current
    ) -> [Date] {
        if lastSyncDate != nil {
            return [requestStartDate(lastSyncDate: lastSyncDate, now: now, calendar: calendar)]
        }
        return backfillFallbackDays.map { days in
            calendar.date(byAdding: .day, value: -days, to: now) ?? now
        }
    }

    /// The bridge's range limit has appeared as both an `errlist` message and an
    /// HTTP error, so match on the text rather than a status code.
    static func isRangeLimitError(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("date range")
            || lowered.contains("90 day")
            || lowered.contains("exceeds limit")
    }

    static func isRangeLimitError(_ error: any Error) -> Bool {
        if let simpleError = error as? SimpleFINError,
           case let .serverReported(errors) = simpleError {
            return errors.contains { isRangeLimitError($0.message) }
        }
        return isRangeLimitError(describe(error))
    }

    static func describe(_ error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    // MARK: - Upserts

    private func upsertAccount(
        _ simpleAccount: SimpleFINAccount,
        institution: Institution,
        now: Date,
        outcome: inout SyncOutcome
    ) throws -> Account {
        let accountBankID = simpleAccount.id
        var descriptor = FetchDescriptor<Account>(
            predicate: #Predicate { $0.bankAccountID == accountBankID }
        )
        descriptor.fetchLimit = 1

        // Prefer an account already owned by this connection's institution, so
        // two banks that reuse an account id never steal each other's accounts.
        let account: Account
        if let existing = (institution.accounts ?? []).first(where: { $0.bankAccountID == accountBankID }) {
            account = existing
        } else if let existing = try modelContext.fetch(descriptor).first,
                  existing.institution == nil
                  || existing.institution?.bankConnectionID == institution.bankConnectionID {
            account = existing
        } else {
            account = Account(bankAccountID: simpleAccount.id, name: simpleAccount.name, currency: simpleAccount.currency)
            account.displayOrder = (institution.accounts ?? []).count
            modelContext.insert(account)
        }

        account.name = simpleAccount.name
        account.apply(currency: simpleAccount.currency)
        account.balanceMinorUnits = simpleAccount.balanceMinorUnits
        if let available = simpleAccount.availableBalanceMinorUnits {
            account.availableBalanceMinorUnits = available
            account.hasAvailableBalance = true
        } else {
            account.availableBalanceMinorUnits = simpleAccount.balanceMinorUnits
            account.hasAvailableBalance = false
        }
        account.balanceDate = simpleAccount.balanceDate
        account.lastSyncedAt = now
        account.institution = institution
        applyHoldings(simpleAccount.holdings, to: account)
        // A bank that reports positions is an investment account regardless of
        // what it is named. Only fall back to the name for accounts without
        // positions, and never override a type we already inferred.
        if !simpleAccount.holdings.isEmpty {
            account.accountTypeRaw = AccountType.investment.rawValue
        } else if account.accountTypeRaw == AccountType.other.rawValue {
            account.accountTypeRaw = Self.inferAccountType(from: simpleAccount.name).rawValue
        }
        outcome.accountsUpserted += 1
        return account
    }

    /// Replaces an account's positions with the ones just received. Positions
    /// are matched by their stable id so a sync updates rather than duplicates
    /// them; positions the bank no longer reports are removed.
    private func applyHoldings(_ incoming: [SimpleFINHolding], to account: Account) {
        var existing = Dictionary(
            (account.holdings ?? []).map { ($0.holdingID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for (index, simple) in incoming.enumerated() {
            let holding: Holding
            if let match = existing.removeValue(forKey: simple.id) {
                holding = match
            } else {
                holding = Holding(holdingID: simple.id)
                modelContext.insert(holding)
                holding.account = account
            }

            holding.symbol = simple.symbol
            holding.name = simple.name
            holding.sharesRaw = simple.sharesRaw
            holding.apply(currency: simple.currency)
            holding.marketValueMinorUnits = simple.marketValueMinorUnits
            holding.costBasisMinorUnits = simple.costBasisMinorUnits ?? 0
            holding.hasCostBasis = simple.costBasisMinorUnits != nil
            holding.purchasePriceMinorUnits = simple.purchasePriceMinorUnits ?? 0
            holding.hasPurchasePrice = simple.purchasePriceMinorUnits != nil
            holding.displayOrder = index
        }

        for orphan in existing.values {
            modelContext.delete(orphan)
        }
    }

    /// Best-effort account type from its name, used when SimpleFIN provides no
    /// positions and no type information.
    private static func inferAccountType(from name: String) -> AccountType {
        let lowered = name.lowercased()
        if lowered.contains("credit") || lowered.contains("card") { return .credit }
        if lowered.contains("loan") || lowered.contains("mortgage") { return .loan }
        if isInvestmentName(lowered) { return .investment }
        if lowered.contains("saving") { return .savings }
        if lowered.contains("checking") { return .checking }
        return .other
    }

    /// Names that reliably signal an investment account, including the
    /// retirement plan names the plain "retire" check used to miss (IRA, 401k,
    /// 529, HSA) and common brokerages.
    private static func isInvestmentName(_ lowered: String) -> Bool {
        let markers = [
            "invest", "broker", "retire", "securit", "portfolio", "annuit", "pension",
            "roth", "crypto", "bitcoin", "vanguard", "fidelity", "schwab", "robinhood",
            "merrill", "etrade", "e*trade", "wealthfront", "betterment", "coinbase",
            "kraken", "401", "403", "457", "529",
        ]
        if markers.contains(where: lowered.contains) { return true }

        // Short tokens need word-boundary matching: "ira" would otherwise match
        // inside words like "aspiration".
        let tokens = Set(lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return tokens.contains("ira") || tokens.contains("hsa") || tokens.contains("sep")
    }

    // swiftlint:disable:next function_parameter_count
    private func reconcileTransactions(
        _ incoming: [SimpleFINTransaction],
        account: Account,
        rules: [RuleSnapshot],
        now: Date,
        calendar: Calendar,
        outcome: inout SyncOutcome
    ) throws {
        guard !incoming.isEmpty else {
            try ageOutPending(seenIDs: [], account: account)
            return
        }

        let accountBankID = account.bankAccountID
        var descriptor = FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.accountIDIndex == accountBankID }
        )
        descriptor.relationshipKeyPathsForPrefetching = [\.account]
        let existing = try modelContext.fetch(descriptor)
        var byID = Dictionary(existing.map { ($0.bankTransactionID, $0) }, uniquingKeysWith: { first, _ in first })

        var incomingPendingIDs = Set<String>()
        // Posted transactions first seen in this sync. Only these may supersede a
        // pending charge, so a brand-new pending can't be matched to an old
        // posted transaction that merely has the same amount.
        var newlyPostedIDs = Set<String>()

        for txn in incoming {
            if txn.isPending { incomingPendingIDs.insert(txn.id) }

            if let model = byID[txn.id] {
                let changed = model.payeeDescription != txn.description
                    || model.amountMinorUnits != txn.amountMinorUnits
                    || model.postedDate != txn.postedDate
                    || model.transactedAt != txn.transactedAt
                    || model.isPending != txn.isPending
                model.payeeDescription = txn.description
                model.amountMinorUnits = txn.amountMinorUnits
                model.postedDate = txn.postedDate
                model.transactedAt = txn.transactedAt
                model.isPending = txn.isPending
                model.normalizedMerchant = MerchantNormalizer.normalize(txn.description)
                model.currencyExponent = account.currency.exponent
                model.accountIDIndex = account.bankAccountID
                model.account = account
                if model.isPending {
                    // The bank is still reporting it as pending; clear any
                    // earlier mismatch count so it is not aged out.
                    model.pendingMismatchCount = 0
                }
                if changed {
                    model.modifiedAt = now
                    outcome.transactionsUpdated += 1
                }
                applyRulesIfNeeded(to: model, rules: rules)
            } else {
                let model = LedgerTransaction(
                    bankTransactionID: txn.id,
                    payeeDescription: txn.description,
                    amountMinorUnits: txn.amountMinorUnits
                )
                model.postedDate = txn.postedDate
                model.transactedAt = txn.transactedAt
                model.isPending = txn.isPending
                model.normalizedMerchant = MerchantNormalizer.normalize(txn.description)
                model.currencyExponent = account.currency.exponent
                model.accountIDIndex = account.bankAccountID
                model.account = account
                model.createdAt = now
                model.modifiedAt = now
                modelContext.insert(model)
                byID[txn.id] = model
                if !txn.isPending { newlyPostedIDs.insert(txn.id) }
                applyRulesIfNeeded(to: model, rules: rules)
                outcome.transactionsInserted += 1
            }
        }

        try promotePending(newlyPostedIDs: newlyPostedIDs, byID: byID, now: now)
        try ageOutPending(seenIDs: incomingPendingIDs, account: account, existing: existing)
    }

    /// Links a pending charge to a posted charge the bank just reported under a
    /// different id. Only newly-posted transactions are considered, and each is
    /// consumed at most once, so an older posted transaction with a coincidental
    /// amount match cannot eat a live pending charge. User-owned fields move to
    /// the posted charge so a manual category, note, or tag is preserved.
    private func promotePending(
        newlyPostedIDs: Set<String>,
        byID: [String: LedgerTransaction],
        now: Date
    ) throws {
        guard !newlyPostedIDs.isEmpty else { return }

        let postedCandidates: [(model: LedgerTransaction, candidate: PostedTransactionCandidate)] =
            newlyPostedIDs.compactMap { id in
                guard let model = byID[id], !model.isPending, !model.isDeleted else { return nil }
                return (
                    model,
                    PostedTransactionCandidate(
                        id: id,
                        accountID: model.accountIDIndex,
                        amountMinorUnits: model.amountMinorUnits,
                        description: model.payeeDescription,
                        postedDate: model.postedDate ?? model.transactedAt
                    )
                )
            }
        guard !postedCandidates.isEmpty else { return }

        let pendingModels = byID.values.filter { $0.isPending && !$0.isDeleted }
        var consumedPostedIDs = Set<String>()

        for pending in pendingModels {
            let candidate = PendingTransactionCandidate(
                id: pending.bankTransactionID,
                accountID: pending.accountIDIndex,
                amountMinorUnits: pending.amountMinorUnits,
                description: pending.payeeDescription,
                transactedAt: pending.transactedAt ?? pending.postedDate
            )
            let available = postedCandidates
                .filter { !consumedPostedIDs.contains($0.model.bankTransactionID) }
                .map(\.candidate)
            guard let matchID = TransactionMatching.findMatch(for: candidate, among: available),
                  let posted = byID[matchID] else { continue }

            consumedPostedIDs.insert(matchID)
            adoptUserFields(from: pending, into: posted)
            posted.modifiedAt = now
            modelContext.delete(pending)
        }
    }

    /// Moves user-owned annotations from a pending charge to the posted charge
    /// that supersedes it.
    private func adoptUserFields(from pending: LedgerTransaction, into posted: LedgerTransaction) {
        posted.note = pending.note ?? posted.note
        posted.userCategory = pending.userCategory ?? posted.userCategory
        posted.isTransfer = pending.isTransfer
        posted.isIgnored = pending.isIgnored
        posted.reviewedAt = pending.reviewedAt ?? posted.reviewedAt

        if let pendingTags = pending.tags, !pendingTags.isEmpty {
            var merged = posted.tags ?? []
            let existingNames = Set(merged.map(\.name))
            for tag in pendingTags where !existingNames.contains(tag.name) {
                merged.append(tag)
            }
            posted.tags = merged
        }
    }

    /// Pending transactions that the bank stopped reporting were either posted
    /// under a new id (handled above) or cancelled. Count mismatches and drop
    /// them after a couple of syncs.
    private func ageOutPending(
        seenIDs: Set<String>,
        account: Account,
        existing: [LedgerTransaction]? = nil
    ) throws {
        let pendingModels: [LedgerTransaction]
        if let existing {
            pendingModels = existing.filter { $0.isPending && !seenIDs.contains($0.bankTransactionID) }
        } else {
            let accountBankID = account.bankAccountID
            let descriptor = FetchDescriptor<LedgerTransaction>(
                predicate: #Predicate { $0.accountIDIndex == accountBankID && $0.isPending }
            )
            pendingModels = try modelContext.fetch(descriptor)
        }

        for model in pendingModels where !model.isDeleted {
            model.pendingMismatchCount += 1
            if model.pendingMismatchCount >= Self.stalePendingThreshold {
                modelContext.delete(model)
            }
        }
    }

    private func applyRulesIfNeeded(to transaction: LedgerTransaction, rules: [RuleSnapshot]) {
        guard transaction.userCategory == nil else { return }
        // Never overwrite an on-device model suggestion with a rule.
        guard transaction.autoCategorySource != SuggestionSource.appleIntelligence.rawValue,
              transaction.autoCategorySource != "model" else { return }
        guard !rules.isEmpty else { return }

        let categoryID = RulesEngine.categoryID(
            amountMinorUnits: transaction.amountMinorUnits,
            description: transaction.payeeDescription,
            rules: rules
        )
        if let categoryID, let category = try? category(withUUID: categoryID) {
            transaction.autoCategory = category
            transaction.autoCategorySource = "rule"
            transaction.autoConfidence = 1
        }
    }

    private func category(withUUID uuid: UUID) throws -> Category? {
        var descriptor = FetchDescriptor<Category>(predicate: #Predicate { $0.uuid == uuid })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func loadRuleSnapshots() throws -> [RuleSnapshot] {
        let descriptor = FetchDescriptor<CategorizationRule>(
            predicate: #Predicate { $0.isEnabled == true && $0.assignedCategory != nil }
        )
        let rules = try modelContext.fetch(descriptor)
        return rules.compactMap { rule in
            guard let category = rule.assignedCategory,
                  let field = RuleField(rawValue: rule.fieldRaw),
                  let kind = RuleMatchKind(rawValue: rule.matchKindRaw) else { return nil }
            return RuleSnapshot(
                id: rule.uuid,
                field: field,
                matchKind: kind,
                pattern: rule.pattern,
                minAmountMinorUnits: rule.minAmountMinorUnits,
                maxAmountMinorUnits: rule.maxAmountMinorUnits,
                categoryID: category.uuid,
                priority: rule.priority
            )
        }
    }

    private func recordSnapshot(for account: Account, now: Date, calendar: Calendar) throws {
        let day = calendar.startOfDay(for: now)
        let accountBankID = account.bankAccountID
        let descriptor = FetchDescriptor<BalanceSnapshot>(
            predicate: #Predicate { $0.account?.bankAccountID == accountBankID }
        )
        let snapshots = try modelContext.fetch(descriptor)

        if let today = snapshots.first(where: { calendar.isDate($0.day, inSameDayAs: day) }) {
            today.balanceMinorUnits = account.balanceMinorUnits
        } else {
            let snapshot = BalanceSnapshot(day: day, balanceMinorUnits: account.balanceMinorUnits)
            snapshot.account = account
            modelContext.insert(snapshot)
        }
    }

    // MARK: - Categorization

    public struct RecategorizeOutcome: Sendable, Equatable {
        public var categorized: Int = 0
        /// Transactions the on-device model was asked about.
        public var attempted: Int = 0
        /// Distinct merchants the on-device model was asked about. This is the
        /// number that matters for cost: merchants are deduplicated before the
        /// model is called.
        public var merchantsAsked: Int = 0
        /// On-device model calls made in this pass.
        public var modelCalls: Int = 0
        /// Uncategorized transactions still awaiting the on-device model.
        public var remaining: Int = 0
        public var bySource: [String: Int] = [:]
        /// True when the on-device model refused the request (typically a system
        /// throttle). The caller should stop trying for now; nothing was marked,
        /// so the transactions are retried on a later pass.
        public var throttled: Bool = false

        public init() {}
    }

    /// Re-runs categorization over transactions with no user category, using
    /// rules, merchant memory learned from the person's own corrections, and
    /// deterministic hints for money movement, income, and fees.
    ///
    /// Never overwrites a user choice. A rule or an exact remembered category
    /// may replace an earlier on-device guess; a fuzzy match may not.
    @discardableResult
    public func recategorize(now: Date = .now) throws -> RecategorizeOutcome {
        let transactions = try modelContext.fetch(FetchDescriptor<LedgerTransaction>())
        let fees = try category(named: "Fees")
        let income = try category(named: "Income")
        let counterparties = try knownTransferCounterparties()
        var outcome = RecategorizeOutcome()
        var didChange = clearInvalidModelCategories(in: transactions, now: now)

        // One-time re-evaluation of earlier automatic guesses. This runs before
        // memory is built, so a stale guess that is cleared here cannot be
        // re-learned from its own row in the same pass.
        let settings = try loadOrCreateSettings()
        if settings.categorizationVersion < Self.currentCategorizationVersion {
            if reevaluateStaleCategories(in: transactions, now: now) { didChange = true }
            settings.categorizationVersion = Self.currentCategorizationVersion
            settings.modifiedAt = now
            didChange = true
        }

        // Built from the post-migration rows, so a merchant whose automatic guess
        // was just cleared is not remembered as that guess.
        let rules = try loadRuleSnapshots()
        let memory = try buildMerchantMemory()

        for transaction in transactions {
            guard transaction.userCategory == nil, !transaction.isIgnored else { continue }
            // Money movement is a deterministic outcome. Once a row is recognized
            // as a transfer, merchant memory and fuzzy matches must not pull it
            // back into a spending or income category on a later pass.
            if transaction.countsAsTransfer, !transaction.isTransferUserSet { continue }

            let merchant = Self.merchantName(transaction)
            let suggestion = CategorySuggester.suggest(
                description: transaction.payeeDescription,
                merchant: merchant,
                amountMinorUnits: transaction.amountMinorUnits,
                rules: rules,
                memory: memory
            )

            let isFuzzy = suggestion?.source == .similarMerchant

            // A rule or an exact merchant-history match outranks everything
            // automatic: the person wrote the rule or corrected this merchant.
            if !isFuzzy, let suggestion, let category = try? category(withUUID: suggestion.categoryID) {
                if applySuggestion(
                    suggestion,
                    category: category,
                    to: transaction,
                    now: now,
                    outcome: &outcome
                ) {
                    didChange = true
                }
                continue
            }

            // Deterministic hints. A genuine charge is named and negative; money
            // movement and pay are recognized by their own labels. Fees require
            // an explicit charge word and a debit, so a payroll deposit can never
            // be swept into "Fees" again.
            if TransactionHints.isExplicitFee(
                description: transaction.payeeDescription,
                amountMinorUnits: transaction.amountMinorUnits
            ), let fees {
                transaction.autoCategory = fees
                transaction.autoCategorySource = SuggestionSource.heuristic.rawValue
                transaction.autoConfidence = 0.9
                if !transaction.isTransferUserSet { transaction.isTransfer = false }
                transaction.modifiedAt = now
                outcome.categorized += 1
                outcome.bySource[SuggestionSource.heuristic.rawValue, default: 0] += 1
                didChange = true
                continue
            }

            if !transaction.isTransferUserSet,
               TransactionHints.isInternalTransfer(
                   description: transaction.payeeDescription,
                   merchant: transaction.normalizedMerchant
               ) {
                let kind: TransactionHints.MoneyMovementKind =
                    TransactionHints.isCreditCardPayment(
                        description: transaction.payeeDescription,
                        merchant: transaction.normalizedMerchant
                    ) ? .creditCardPayment : .transfer
                if applyMoneyMovement(kind, to: transaction, now: now) { didChange = true }
                continue
            }

            if TransactionHints.isIncome(
                description: transaction.payeeDescription,
                amountMinorUnits: transaction.amountMinorUnits
            ), let income {
                transaction.autoCategory = income
                transaction.autoCategorySource = SuggestionSource.heuristic.rawValue
                transaction.autoConfidence = 0.85
                if !transaction.isTransferUserSet { transaction.isTransfer = false }
                transaction.modifiedAt = now
                outcome.categorized += 1
                outcome.bySource[SuggestionSource.heuristic.rawValue, default: 0] += 1
                didChange = true
                continue
            }

            // Money sent to another financial institution is movement between
            // the person's own accounts, not spending — even when the generic
            // keywords don't name it.
            if !transaction.isTransferUserSet,
               TransactionHints.isTransferToInstitution(
                   description: transaction.payeeDescription,
                   merchant: transaction.normalizedMerchant,
                   counterparties: counterparties
               ) {
                // Use the specific kind when one applies, so a card payment isn't
                // labeled a plain transfer here while the model path labels it a
                // card payment.
                let kind = TransactionHints.moneyMovement(
                    description: transaction.payeeDescription,
                    merchant: transaction.normalizedMerchant,
                    counterparties: counterparties
                ) ?? .transfer
                if applyMoneyMovement(kind, to: transaction, now: now) { didChange = true }
                continue
            }

            // Only now may a fuzzy match fill in, and only when the row has no
            // stronger label of its own — never over the model's guess, a hint,
            // a rule, or remembered history.
            if isFuzzy, let suggestion, let category = try? category(withUUID: suggestion.categoryID),
               transaction.autoCategory == nil
                   || transaction.autoCategorySource == SuggestionSource.similarMerchant.rawValue {
                if applySuggestion(
                    suggestion,
                    category: category,
                    to: transaction,
                    now: now,
                    outcome: &outcome
                ) {
                    didChange = true
                }
                continue
            }

            // Nothing matches now. Clear a deterministic guess the previous
            // rules assigned, so a stale heuristic category can't linger.
            if transaction.autoCategorySource == SuggestionSource.heuristic.rawValue {
                transaction.autoCategory = nil
                transaction.autoCategorySource = nil
                transaction.autoConfidence = 0
                transaction.modifiedAt = now
                didChange = true
            }
        }

        // Last, match each recognized transfer leg with its counterpart in
        // another account, so a credit that landed as income reads as the same
        // money movement instead of inflating income.
        if pairTransfers(in: transactions, counterparties: counterparties, now: now) {
            didChange = true
        }

        if didChange {
            try modelContext.save()
        }
        return outcome
    }

    /// Re-evaluates the store after the person changed their rules. Rows that a
    /// removed or edited rule had categorized are cleared first so the
    /// deterministic pass can re-decide; user choices, on-device model labels,
    /// and merchant memory are left alone. Returns the pass outcome.
    @discardableResult
    public func applyRules(now: Date = .now) throws -> RecategorizeOutcome {
        let transactions = try modelContext.fetch(FetchDescriptor<LedgerTransaction>())
        var didClear = false
        for transaction in transactions where transaction.userCategory == nil {
            guard transaction.autoCategorySource == SuggestionSource.rule.rawValue else { continue }
            transaction.autoCategory = nil
            transaction.autoCategorySource = nil
            transaction.autoConfidence = 0
            transaction.modifiedAt = now
            didClear = true
        }
        if didClear {
            try modelContext.save()
        }
        return try recategorize(now: now)
    }

    /// Clears on-device model guesses that the current rules would never produce:
    /// "Fees", "Transfers", and "Uncategorized" are decided deterministically, and
    /// a debit can't be "Income". This is how a stale "Fees" label left by an
    /// earlier build gets lifted and recomputed, without touching anything else.
    private func clearInvalidModelCategories(
        in transactions: [LedgerTransaction],
        now: Date
    ) -> Bool {
        var didChange = false
        for transaction in transactions where transaction.userCategory == nil {
            guard isInvalidModelCategory(transaction) else { continue }
            transaction.autoCategory = nil
            transaction.autoCategorySource = nil
            transaction.autoConfidence = 0
            // Let the hints and the model look at it again.
            transaction.autoCategorizeAttemptedAt = nil
            transaction.modifiedAt = now
            didChange = true
        }
        return didChange
    }

    /// Marks a row as money movement. A card or loan payment also points at its
    /// own category, so the row reads "Credit Card Payments" or "Loan Payments"
    /// instead of a generic "Transfer". Returns true when anything changed.
    @discardableResult
    private func applyMoneyMovement(
        _ kind: TransactionHints.MoneyMovementKind,
        to transaction: LedgerTransaction,
        now: Date
    ) -> Bool {
        var target: Category?
        if let name = kind.categoryName {
            target = try? category(named: name)
        }
        var changed = false

        if !transaction.isTransfer {
            transaction.isTransfer = true
            changed = true
        }
        if transaction.autoCategory?.uuid != target?.uuid {
            transaction.autoCategory = target
            changed = true
        }
        let source = target == nil ? nil : SuggestionSource.heuristic.rawValue
        if transaction.autoCategorySource != source {
            transaction.autoCategorySource = source
            changed = true
        }
        let confidence = target == nil ? 0 : 1.0
        if transaction.autoConfidence != confidence {
            transaction.autoConfidence = confidence
            changed = true
        }
        if transaction.autoCategorizeAttemptedAt != nil {
            transaction.autoCategorizeAttemptedAt = nil
            changed = true
        }
        if changed { transaction.modifiedAt = now }
        return changed
    }

    /// Applies a rule, memory, or fuzzy suggestion unless it would rewrite a row
    /// to the answer it already holds, or downgrade the model's own label to the
    /// same category. Returns true when anything changed.
    private func applySuggestion(
        _ suggestion: CategorySuggestion,
        category: Category,
        to transaction: LedgerTransaction,
        now: Date,
        outcome: inout RecategorizeOutcome
    ) -> Bool {
        let isModelSourced = transaction.autoCategorySource == SuggestionSource.appleIntelligence.rawValue
            || transaction.autoCategorySource == "model"
        let sameCategory = transaction.autoCategory?.uuid == category.uuid
        // Already settled on this exact answer; don't rewrite the row on every
        // pass. This keeps learned memory from churning updates.
        if sameCategory, transaction.autoCategorySource == suggestion.source.rawValue {
            return false
        }
        // Keep the model's own label when memory or a fuzzy match merely agrees
        // with it; that is not a downgrade.
        if isModelSourced, sameCategory {
            return false
        }
        transaction.autoCategory = category
        transaction.autoCategorySource = suggestion.source.rawValue
        transaction.autoConfidence = suggestion.confidence
        if !transaction.isTransferUserSet {
            transaction.isTransfer = category.name == "Transfers"
        }
        transaction.modifiedAt = now
        outcome.categorized += 1
        outcome.bySource[suggestion.source.rawValue, default: 0] += 1
        return true
    }

    /// Matches each recognized transfer leg with its counterpart in another
    /// account and marks that counterpart as a transfer too.
    ///
    /// This is what fixes a transfer whose incoming credit was guessed as Income:
    /// the outgoing leg is anchored by its wording or by a card/loan payment, and
    /// the matching credit is pulled back into money movement. Only a counterpart
    /// the person hasn't touched and that has no category, or only a weak Income
    /// guess, is eligible — a row the person categorized, or one a deterministic
    /// hint placed, is never revised.
    @discardableResult
    private func pairTransfers(
        in transactions: [LedgerTransaction],
        counterparties: [String],
        now: Date
    ) -> Bool {
        guard transactions.count > 1 else { return false }

        let legs = transactions.map { transaction -> TransferPairing.Leg<PersistentIdentifier> in
            let isAnchor = transaction.amountMinorUnits != 0
                && (transaction.isTransferUserSet
                    || TransactionHints.moneyMovement(
                        description: transaction.payeeDescription,
                        merchant: transaction.normalizedMerchant,
                        counterparties: counterparties
                    ) != nil)
            let isEligible = transaction.userCategory == nil
                && !transaction.isIgnored
                && !transaction.isPending
                && !transaction.isTransferUserSet
                && !transaction.countsAsTransfer
                && transaction.amountMinorUnits > 0
                && (transaction.autoCategory == nil || isWeakIncomeGuess(transaction))
            return TransferPairing.Leg(
                id: transaction.persistentModelID,
                accountID: transaction.accountIDIndex,
                amountMinorUnits: transaction.amountMinorUnits,
                date: transaction.effectiveDate,
                isAnchor: isAnchor,
                isEligibleCounterpart: isEligible
            )
        }

        let counterpartIDs = TransferPairing.counterpartsToMark(in: legs)
        guard !counterpartIDs.isEmpty else { return false }

        let byID = Dictionary(
            transactions.map { ($0.persistentModelID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var didChange = false
        for id in counterpartIDs {
            guard let transaction = byID[id] else { continue }
            if applyMoneyMovement(.transfer, to: transaction, now: now) {
                didChange = true
            }
        }
        return didChange
    }

    /// An Income label that only automation guessed (the on-device model or
    /// memory learned from it), rather than a deterministic hint or the person's
    /// own choice. Only these may a transfer match revise.
    private func isWeakIncomeGuess(_ transaction: LedgerTransaction) -> Bool {
        guard transaction.autoCategory?.name == "Income" else { return false }
        let source = transaction.autoCategorySource
        return source == SuggestionSource.appleIntelligence.rawValue
            || source == "model"
            || source == SuggestionSource.memory.rawValue
    }

    /// Bumped when categorization logic changes enough to re-examine earlier
    /// automatic guesses once. Version 1 targeted credits mislabeled as spending;
    /// version 2 redid every model spending guess; version 3 redoes every
    /// automatic guess — model *and* learned memory — so the merchant-level
    /// batching, memory, and direction-aware prompt reach rows that were already
    /// decided by an earlier build.
    static let currentCategorizationVersion = 3

    private func isModelSourced(_ transaction: LedgerTransaction) -> Bool {
        let source = transaction.autoCategorySource
        return source == SuggestionSource.appleIntelligence.rawValue || source == "model"
    }

    /// A row whose category came only from automation (an on-device model guess
    /// or memory learned from one), never from the person or a deterministic hint.
    private func isAutomaticSourced(_ transaction: LedgerTransaction) -> Bool {
        guard transaction.userCategory == nil else { return false }
        let source = transaction.autoCategorySource
        return source == SuggestionSource.appleIntelligence.rawValue
            || source == "model"
            || source == SuggestionSource.memory.rawValue
    }

    /// Clears automatic guesses so the current hints, merchant memory, and
    /// direction-aware prompt can redo them. User choices and deterministic
    /// outcomes (fees, income, money movement) are left alone. The "attempted"
    /// stamp is cleared too, so rows the model has never placed are retried once,
    /// instead of being retried on every single run — the old behavior, which let
    /// a merchant the model couldn't place cost a call forever.
    private func reevaluateStaleCategories(
        in transactions: [LedgerTransaction],
        now: Date
    ) -> Bool {
        var didChange = false
        for transaction in transactions where transaction.userCategory == nil {
            if isAutomaticSourced(transaction) {
                transaction.autoCategory = nil
                transaction.autoCategorySource = nil
                transaction.autoConfidence = 0
                transaction.autoCategorizeAttemptedAt = nil
                transaction.modifiedAt = now
                didChange = true
            } else if Self.needsCategory(transaction), transaction.autoCategorizeAttemptedAt != nil {
                // A row an earlier pass tried but never categorized.
                transaction.autoCategorizeAttemptedAt = nil
                transaction.modifiedAt = now
                didChange = true
            }
        }
        return didChange
    }

    private func isInvalidModelCategory(_ transaction: LedgerTransaction) -> Bool {
        guard isModelSourced(transaction), let name = transaction.autoCategory?.name else {
            return false
        }
        if name == "Fees" || name == "Transfers" || name == "Uncategorized" {
            return true
        }
        return name == "Income" && transaction.amountMinorUnits <= 0
    }

    /// Names of the person's own accounts and institutions, so a transfer to one
    /// of them can be recognized even when the description doesn't say
    /// "transfer".
    private func knownTransferCounterparties() throws -> [String] {
        let accounts = try modelContext.fetch(FetchDescriptor<Account>())
        var names: [String] = []
        for account in accounts {
            if !account.name.isEmpty { names.append(account.name) }
            if let custom = account.customDisplayName, !custom.isEmpty { names.append(custom) }
            if let institution = account.institution?.name, !institution.isEmpty {
                names.append(institution)
            }
        }
        return names
    }

    /// Immediately applies a person's category choice to their other, still
    /// automatic rows for the same merchant, so a correction sticks instead of
    /// waiting for the next sync.
    @discardableResult
    public func propagateUserCategory(
        transactionID: PersistentIdentifier,
        now: Date = .now
    ) throws -> Int {
        guard let transaction = liveModel(LedgerTransaction.self, transactionID),
              let category = transaction.userCategory else { return 0 }
        let key = MerchantMemory.key(for: Self.merchantName(transaction))
        guard !key.isEmpty else { return 0 }

        let all = try modelContext.fetch(FetchDescriptor<LedgerTransaction>())
        var changed = 0
        for other in all where other.persistentModelID != transactionID {
            guard other.userCategory == nil, !other.isIgnored else { continue }
            guard MerchantMemory.key(for: Self.merchantName(other)) == key else { continue }
            if other.autoCategory?.uuid == category.uuid,
               other.autoCategorySource == SuggestionSource.memory.rawValue {
                continue
            }
            other.autoCategory = category
            other.autoCategorySource = SuggestionSource.memory.rawValue
            other.autoConfidence = 1
            if !other.isTransferUserSet {
                other.isTransfer = category.name == "Transfers"
            }
            other.modifiedAt = now
            changed += 1
        }
        if changed > 0 {
            try modelContext.save()
        }
        return changed
    }

    static func merchantName(_ transaction: LedgerTransaction) -> String {
        transaction.normalizedMerchant.isEmpty
            ? transaction.payeeDescription
            : transaction.normalizedMerchant
    }

    private func category(named name: String) throws -> Category? {
        var descriptor = FetchDescriptor<Category>(predicate: #Predicate { $0.name == name })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    public struct CategorizationCounts: Sendable, Equatable {
        /// Needs a category and hasn't been tried by the on-device model yet.
        public var pendingModel: Int = 0
        /// Needs a category and the on-device model already tried and failed.
        public var unresolved: Int = 0

        public var total: Int { pendingModel + unresolved }

        public init() {}
    }

    /// How many transactions still need a category, split by whether the
    /// on-device model has already tried them.
    public func categorizationCounts() throws -> CategorizationCounts {
        let transactions = try modelContext.fetch(FetchDescriptor<LedgerTransaction>())
        var counts = CategorizationCounts()
        for transaction in transactions where Self.needsCategory(transaction) {
            if transaction.autoCategorizeAttemptedAt == nil {
                counts.pendingModel += 1
            } else {
                counts.unresolved += 1
            }
        }
        return counts
    }

    /// Total transactions still needing a category.
    public func uncategorizedCount() throws -> Int {
        try categorizationCounts().total
    }

    /// Runs the on-device Apple Intelligence model over a bounded set of
    /// uncategorized *merchants*, not individual transactions. Purely local: it
    /// uses `SystemLanguageModel` and never the Private Cloud Compute model.
    ///
    /// Distinct merchants are asked about once and the answer is applied to every
    /// matching row. This is where the bulk of the savings on a first sync comes
    /// from: thousands of transactions usually carry only a few hundred distinct
    /// merchants, and repeated merchants (salary, rent, subscriptions) appear
    /// dozens of times.
    ///
    /// Each merchant is stamped once the model has actually answered, whether or
    /// not it found a category, so a settled merchant is not re-asked on every
    /// run. A transient failure — the system throttling the model is the common
    /// one — leaves everything unmarked so a later pass retries it.
    @discardableResult
    public func appleIntelligenceCategorizeBatch(
        limit: Int = 0,
        now: Date = .now
    ) async throws -> RecategorizeOutcome {
        var outcome = RecategorizeOutcome()

        // System routing categories are never model targets: money movement is
        // handled by hints, "Fees" is reserved for explicit charges the hints
        // recognize, and "Uncategorized" is the absence of a choice. Card and
        // loan payments are decided deterministically too, so the model never
        // guesses them onto a spending row.
        let categories = try modelContext.fetch(FetchDescriptor<Category>())
            .filter {
                !$0.isArchived
                    && $0.name != "Transfers"
                    && $0.name != "Fees"
                    && $0.name != "Uncategorized"
                    && $0.name != "Credit Card Payments"
                    && $0.name != "Loan Payments"
            }
        guard !categories.isEmpty else { return outcome }

        let all = try modelContext.fetch(FetchDescriptor<LedgerTransaction>())
        let candidates = all
            .filter { Self.needsCategory($0) && $0.autoCategorizeAttemptedAt == nil }
            .sorted { $0.effectiveDate > $1.effectiveDate }

        guard !candidates.isEmpty else { return outcome }
        guard AppleIntelligenceCategorizer.isAvailable else {
            outcome.remaining = candidates.count
            return outcome
        }

        let counterparties = try knownTransferCounterparties()

        // Group candidates by merchant and direction. A merchant that appears as
        // both a charge and a credit (a purchase and its refund) is split so the
        // direction in the prompt stays unambiguous.
        //
        // Only values are kept here, never the rows themselves: this actor
        // suspends at the model calls below, and a sync, disconnect, or delete
        // running in that window can remove the rows. Writing to a deleted
        // SwiftData row traps.
        struct MerchantGroup {
            var keys: [RowKey] = []
            var merchant = ""
            var description = ""
            var isCredit = false
        }

        var groups: [String: MerchantGroup] = [:]
        var order: [String] = []
        for transaction in candidates {
            // Never ask the model about money movement. Mark it a transfer (or a
            // card/loan payment) and move on; this is the guard that stops
            // overdraft transfers and peer-to-peer payments from being guessed
            // into a spending category.
            if !transaction.isTransferUserSet,
               let kind = TransactionHints.moneyMovement(
                   description: transaction.payeeDescription,
                   merchant: transaction.normalizedMerchant,
                   counterparties: counterparties
               ) {
                applyMoneyMovement(kind, to: transaction, now: now)
                transaction.autoCategorizeAttemptedAt = now
                transaction.modifiedAt = now
                outcome.attempted += 1
                continue
            }

            let merchant = Self.merchantName(transaction)
            let direction = transaction.amountMinorUnits > 0 ? "in" : "out"
            let key = "\(MerchantMemory.key(for: merchant))|\(direction)"
            if groups[key] == nil { order.append(key) }
            var group = groups[key] ?? MerchantGroup()
            let isFirst = group.keys.isEmpty
            group.keys.append(RowKey(transaction))
            // The longest description stands in for the merchant, as before.
            if isFirst || transaction.payeeDescription.count > group.description.count {
                group.merchant = merchant
                group.description = transaction.payeeDescription
                group.isCredit = transaction.amountMinorUnits > 0
            }
            groups[key] = group
        }

        let batchSize = limit > 0 ? limit : AppleIntelligenceCategorizer.recommendedMerchantBatchSize
        let selected = order.prefix(max(1, batchSize)).compactMap { groups[$0] }
        guard !selected.isEmpty else {
            outcome.remaining = max(0, candidates.count - outcome.attempted)
            try modelContext.save()
            return outcome
        }

        // One query per merchant group, remembering which categories are legal
        // for its direction (a debit can never be Income). Names, not models, so
        // nothing is held across the model call below.
        var queries: [MerchantQuery] = []
        var allowedByIndex: [Int: [String]] = [:]
        for (index, group) in selected.enumerated() {
            let allowed = (group.isCredit ? categories : categories.filter { $0.name != "Income" })
                .map(\.name)
            guard !allowed.isEmpty else { continue }
            allowedByIndex[index] = allowed
            queries.append(MerchantQuery(
                id: index,
                merchant: group.merchant.isEmpty ? group.description : group.merchant,
                isCredit: group.isCredit
            ))
        }

        // A single model call for the whole batch of merchants.
        var resolved: [Int: String] = [:]
        if !queries.isEmpty {
            outcome.modelCalls += 1
            do {
                resolved = try await AppleIntelligenceCategorizer.classifyBatch(
                    queries: queries,
                    categories: categories.map(\.name)
                )
            } catch {
                await cairnLog(.warning, "On-device model unavailable; pausing categorization for now.")
                outcome.throttled = true
                outcome.remaining = max(0, candidates.count - outcome.attempted)
                try modelContext.save()
                return outcome
            }
        }

        // Apply the batch, re-asking any merchant it did not place cleanly with
        // the fully-constrained single-category schema. Rows are re-resolved from
        // their identifiers after every suspension, so a row deleted mid-pass by
        // a sync, disconnect, or delete is skipped rather than written to.
        for (index, group) in selected.enumerated() {
            var rows = liveTransactions(group.keys)
            guard !rows.isEmpty else { continue }

            guard let allowed = allowedByIndex[index] else {
                for transaction in rows { transaction.autoCategorizeAttemptedAt = now }
                outcome.attempted += rows.count
                continue
            }

            var chosen = resolved[index].flatMap { name in allowed.first { $0 == name } }

            if chosen == nil {
                outcome.modelCalls += 1
                do {
                    let name = try await AppleIntelligenceCategorizer.classify(
                        merchant: group.merchant,
                        description: group.description,
                        isCredit: group.isCredit,
                        categories: allowed
                    )
                    chosen = name.flatMap { candidate in allowed.first { $0 == candidate } }
                    rows = liveTransactions(group.keys)
                } catch {
                    await cairnLog(.warning, "On-device model unavailable; pausing categorization for now.")
                    outcome.throttled = true
                    outcome.remaining = max(0, candidates.count - outcome.attempted)
                    try modelContext.save()
                    return outcome
                }
            }

            guard !rows.isEmpty else { continue }
            // Resolve the category by name at write time: the Category rows were
            // fetched before the awaits above too.
            let target: Category? = chosen.flatMap { name in
                do {
                    return try category(named: name)
                } catch {
                    return nil
                }
            }
            for transaction in rows {
                transaction.autoCategorizeAttemptedAt = now
                if let target {
                    transaction.autoCategory = target
                    transaction.autoCategorySource = SuggestionSource.appleIntelligence.rawValue
                    transaction.autoConfidence = 0.8
                }
                transaction.modifiedAt = now
            }
            outcome.attempted += rows.count
            outcome.merchantsAsked += 1
            if target != nil {
                outcome.categorized += rows.count
                outcome.bySource[SuggestionSource.appleIntelligence.rawValue, default: 0] += rows.count
            }
        }

        // A money-movement row recognized while building the batch should pull
        // its counterpart along right away, so the next pass doesn't have to wait
        // to fix a credit the model placed as income. `all` was fetched before
        // the model calls, so fetch again rather than touch rows that may be gone.
        let live = try modelContext.fetch(FetchDescriptor<LedgerTransaction>())
        _ = pairTransfers(in: live, counterparties: counterparties, now: now)

        outcome.remaining = max(0, candidates.count - outcome.attempted)
        try modelContext.save()
        return outcome
    }

    private static func needsCategory(_ transaction: LedgerTransaction) -> Bool {
        !transaction.countsAsTransfer
            && transaction.userCategory == nil
            && transaction.autoCategory == nil
            && !transaction.isIgnored
            && !transaction.isPending
    }

    /// Resolves a model by asking the store, not the context's cache.
    ///
    /// `self[id, as: T.self]` hands back the copy this context already holds
    /// without checking that the row still exists, so a deletion made anywhere
    /// else — a batch `delete(model:)`, a removed connection, Delete All Data
    /// from the main context — is invisible and the first write traps. Fetching
    /// by identifier is the check that sees those, and it is needed even where
    /// this actor does not suspend in between: the stale copy can already be in
    /// the cache when the call arrives.
    ///
    /// Returns nil when the row is gone; callers skip the write.
    private func liveModel<T: PersistentModel>(_: T.Type, _ id: PersistentIdentifier) -> T? {
        let descriptor = FetchDescriptor<T>(
            predicate: #Predicate { $0.persistentModelID == id }
        )
        return try? modelContext.fetch(descriptor).first
    }

    /// Re-fetches rows from the store after a suspension, dropping any that are
    /// gone.
    ///
    /// `isDeleted` only reflects deletions made in *this* context, so a batch
    /// delete (`delete(model:)`), a Delete All Data, or a deletion made from the
    /// main context — disconnecting Wallet, removing a connection — would slip
    /// through and writing to the row would trap. Asking the store is the only
    /// reliable check.
    private func liveTransactions(_ keys: [RowKey]) -> [LedgerTransaction] {
        guard !keys.isEmpty else { return [] }
        let identifiers = keys.map(\.bankTransactionID)
        let descriptor = FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { identifiers.contains($0.bankTransactionID) }
        )
        guard let rows = try? modelContext.fetch(descriptor) else { return [] }
        let wanted = Set(keys)
        return rows.filter {
            wanted.contains(RowKey(bankTransactionID: $0.bankTransactionID, accountIDIndex: $0.accountIDIndex))
        }
    }

    /// Builds merchant memory.
    ///
    /// The person's own corrections always win for a merchant. For merchants they
    /// have never corrected, an earlier automatic decision is remembered too, so a
    /// repeat sync never re-asks the model about a merchant it already placed —
    /// which is what keeps incremental syncs nearly free. A categorization version
    /// bump clears those automatic rows first, so a remembered guess can always be
    /// revised by a later, better build.
    private func buildMerchantMemory() throws -> MerchantMemory {
        // Only rows carrying a category can say anything about how the person
        // categorizes; the rest contribute nothing but the cost of materializing
        // them, and on a long ledger that is most of the store.
        let descriptor = FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.userCategory != nil || $0.autoCategory != nil }
        )
        let transactions = try modelContext.fetch(descriptor)
        var userKeys = Set<String>()
        var userSamples: [MemorySample] = []
        var automaticSamples: [MemorySample] = []

        for transaction in transactions {
            let merchant = Self.merchantName(transaction)
            guard !merchant.isEmpty else { continue }
            if let category = transaction.userCategory {
                userSamples.append(MemorySample(merchant: merchant, categoryID: category.uuid))
                userKeys.insert(MerchantMemory.key(for: merchant))
            } else if isAutomaticSourced(transaction),
                      let category = transaction.autoCategory,
                      !transaction.countsAsTransfer {
                automaticSamples.append(MemorySample(merchant: merchant, categoryID: category.uuid))
            }
        }

        let automaticOnly = automaticSamples.filter { !userKeys.contains($0.merchantKey) }
        return MerchantMemory(samples: userSamples + automaticOnly)
    }

    // MARK: - Categories

    /// Seeds a small, sensible default set once, so categorization works before
    /// the user creates anything. New built-in categories are added to existing
    /// installs through `categorySeedVersion`, exactly once, without resurrecting
    /// categories the person deleted.
    public func seedDefaultCategoriesIfNeeded(now: Date = .now) throws {
        let settings = try loadOrCreateSettings()
        let existing = try modelContext.fetch(FetchDescriptor<Category>())
        let existingNames = Set(
            existing.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )

        let defaults: [(String, String, String)] = [
            ("Income", "arrow.down.circle.fill", "#34C759"),
            ("Groceries", "cart.fill", "#30B0C7"),
            ("Dining", "fork.knife", "#FF9F0A"),
            ("Transport", "car.fill", "#5E5CE6"),
            ("Housing", "house.fill", "#8E8E93"),
            ("Utilities", "bolt.fill", "#FFD60A"),
            ("Shopping", "bag.fill", "#FF375F"),
            ("Health", "heart.fill", "#FF2D55"),
            ("Entertainment", "play.circle.fill", "#BF5AF2"),
            ("Travel", "airplane", "#64D2FF"),
            ("Fees", "percent", "#A2845E"),
            ("Transfers", "arrow.left.arrow.right", "#32ADE6"),
            ("Uncategorized", "questionmark.circle", "#8E8E93"),
        ]

        // Categories added after the first generation, given to existing installs
        // once. Money movement keeps its own labels instead of a generic Transfer.
        let paymentDefaults: [(String, String, String)] = [
            ("Credit Card Payments", "creditcard.fill", "#0A84FF"),
            ("Loan Payments", "building.columns.fill", "#5AC8FA"),
        ]
        let currentSeedVersion = 2

        var didChange = false

        if !settings.hasSeededDefaultCategories {
            for (index, item) in defaults.enumerated() where !existingNames.contains(item.0.lowercased()) {
                let category = Category(
                    name: item.0,
                    symbolName: item.1,
                    colorHex: item.2,
                    sortOrder: index,
                    isSystem: item.0 == "Uncategorized" || item.0 == "Transfers"
                )
                modelContext.insert(category)
            }
            settings.hasSeededDefaultCategories = true
            didChange = true
        }

        if settings.categorySeedVersion < currentSeedVersion {
            for (offset, item) in paymentDefaults.enumerated()
            where !existingNames.contains(item.0.lowercased()) {
                let category = Category(
                    name: item.0,
                    symbolName: item.1,
                    colorHex: item.2,
                    sortOrder: defaults.count + offset
                )
                modelContext.insert(category)
            }
            settings.categorySeedVersion = currentSeedVersion
            didChange = true
        }

        if didChange {
            settings.modifiedAt = now
            try modelContext.save()
        }
    }

    /// Collapses duplicate categories that can appear when two devices each seed
    /// the default set before iCloud delivers the other's records. Every
    /// transaction and rule pointing at a duplicate is repointed at the surviving
    /// category, then the duplicate is deleted. Idempotent and safe to run often.
    @discardableResult
    public func deduplicateCategories() throws -> Int {
        let all = try modelContext.fetch(FetchDescriptor<Category>())
        var groups: [String: [Category]] = [:]
        for category in all {
            let key = category.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            groups[key, default: []].append(category)
        }

        var removed = 0
        for group in groups.values where group.count > 1 {
            guard let canonical = group.max(by: { !isPreferred($0, over: $1) }) else { continue }
            for duplicate in group where duplicate.persistentModelID != canonical.persistentModelID {
                for transaction in duplicate.userTransactions ?? [] {
                    transaction.userCategory = canonical
                }
                for transaction in duplicate.autoTransactions ?? [] {
                    transaction.autoCategory = canonical
                }
                for rule in duplicate.rules ?? [] {
                    rule.assignedCategory = canonical
                }
                modelContext.delete(duplicate)
                removed += 1
            }
        }
        if removed > 0 { try modelContext.save() }
        return removed
    }

    /// Prefers, in order: a system category, the one more records already point
    /// at, then the oldest. Deterministic so every device keeps the same row.
    private func isPreferred(_ lhs: Category, over rhs: Category) -> Bool {
        if lhs.isSystem != rhs.isSystem { return lhs.isSystem }
        let lhsReferences = referenceCount(lhs)
        let rhsReferences = referenceCount(rhs)
        if lhsReferences != rhsReferences { return lhsReferences > rhsReferences }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.uuid.uuidString < rhs.uuid.uuidString
    }

    private func referenceCount(_ category: Category) -> Int {
        (category.userTransactions?.count ?? 0)
            + (category.autoTransactions?.count ?? 0)
            + (category.rules?.count ?? 0)
    }

    // MARK: - Import

    public struct ImportOutcome: Sendable, Equatable {
        public var inserted: Int = 0
        public var duplicatesSkipped: Int = 0

        public init() {}
    }

    private struct ImportCandidate {
        let amountMinorUnits: Int64
        let date: Date
        let merchant: String
    }

    /// Inserts imported rows into an account, skipping likely duplicates.
    /// Used by CSV import for accounts SimpleFIN can't reach (Apple Card,
    /// Apple Savings, cash, property, loans).
    public func importTransactions(
        _ imports: [ImportedTransaction],
        intoAccountID: PersistentIdentifier,
        now: Date = .now
    ) throws -> ImportOutcome {
        guard let account = liveModel(Account.self, intoAccountID) else {
            throw SimpleFINError.transport("The account no longer exists.")
        }

        let accountBankID = account.bankAccountID
        let existing = try modelContext.fetch(
            FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.accountIDIndex == accountBankID })
        )
        var candidates = existing.map { transaction in
            ImportCandidate(
                amountMinorUnits: transaction.amountMinorUnits,
                date: transaction.effectiveDate,
                merchant: transaction.normalizedMerchant.isEmpty
                    ? MerchantNormalizer.normalize(transaction.payeeDescription)
                    : transaction.normalizedMerchant
            )
        }

        let rules = try loadRuleSnapshots()
        var outcome = ImportOutcome()

        for item in imports.sorted(by: { $0.date < $1.date }) {
            let normalized = MerchantNormalizer.normalize(item.merchant)
            if isLikelyDuplicate(item, normalized: normalized, among: candidates) {
                outcome.duplicatesSkipped += 1
                continue
            }

            let model = LedgerTransaction(
                bankTransactionID: Self.importIdentifier(for: item, normalized: normalized),
                payeeDescription: item.description,
                amountMinorUnits: item.amountMinorUnits
            )
            model.postedDate = item.date
            model.isPending = false
            model.normalizedMerchant = normalized
            model.isImported = true
            model.currencyExponent = account.currency.exponent
            model.accountIDIndex = account.bankAccountID
            model.account = account
            model.createdAt = now
            model.modifiedAt = now
            modelContext.insert(model)
            applyRulesIfNeeded(to: model, rules: rules)

            candidates.append(
                ImportCandidate(amountMinorUnits: item.amountMinorUnits, date: item.date, merchant: normalized)
            )
            outcome.inserted += 1
        }

        if account.isManual {
            try recomputeManualBalance(account: account)
        }

        try modelContext.save()
        return outcome
    }

    private func isLikelyDuplicate(
        _ item: ImportedTransaction,
        normalized: String,
        among candidates: [ImportCandidate]
    ) -> Bool {
        let window = 3 * 86_400.0
        for candidate in candidates {
            guard candidate.amountMinorUnits == item.amountMinorUnits else { continue }
            guard abs(candidate.date.timeIntervalSince(item.date)) <= window else { continue }
            if candidate.merchant == normalized { return true }
            if TextSimilarity.ratio(candidate.merchant, normalized) >= 0.6 { return true }
        }
        return false
    }

    /// Recomputes a manual account's balance from its opening balance and all of
    /// its transactions.
    private func recomputeManualBalance(account: Account) throws {
        let accountBankID = account.bankAccountID
        let transactions = try modelContext.fetch(
            FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.accountIDIndex == accountBankID })
        )
        let sum = transactions.reduce(Int64(0)) { MinorUnits.addClamped($0, $1.amountMinorUnits) }
        account.balanceMinorUnits = MinorUnits.addClamped(account.startingBalanceMinorUnits, sum)
        account.balanceDate = .now
    }

    /// A deterministic id so re-importing the same file doesn't create new rows
    /// even before the content-level duplicate check runs.
    private static func importIdentifier(for item: ImportedTransaction, normalized: String) -> String {
        let day = Int(item.date.timeIntervalSince1970 / 86_400)
        let key = "\(day)|\(item.amountMinorUnits)|\(normalized.lowercased())"
        return "import-\(stableHash(key))"
    }

    private static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    // MARK: - Export

    public func exportRows() throws -> [TransactionExportRow] {
        let descriptor = FetchDescriptor<LedgerTransaction>()
        let transactions = try modelContext.fetch(descriptor)

        return transactions.map { txn in
            let account = txn.account
            let currency = account?.currency ?? .usd
            return TransactionExportRow(
                institution: account?.institution?.name ?? "",
                account: account?.displayName ?? "",
                date: txn.effectiveDate,
                amount: MinorUnits.string(txn.amountMinorUnits, exponent: currency.exponent),
                currency: currency.isCustom ? (currency.customAbbreviation ?? currency.code) : currency.code,
                description: txn.payeeDescription,
                category: txn.effectiveCategory?.name,
                isPending: txn.isPending,
                isTransfer: txn.isTransfer,
                isIgnored: txn.isIgnored,
                note: txn.note,
                tags: (txn.tags ?? []).map(\.name).sorted(),
                transactionID: txn.bankTransactionID
            )
        }
    }

    public func exportCSV() throws -> String {
        Exporters.csv(rows: try exportRows())
    }

    public func exportJSON() throws -> Data {
        try Exporters.json(rows: try exportRows())
    }

    // MARK: - Data management

    public func markOnboardingComplete(useCloudKit: Bool, now: Date = .now) throws {
        let settings = try loadOrCreateSettings()
        settings.onboardingComplete = true
        settings.useCloudKit = useCloudKit
        settings.modifiedAt = now
        try modelContext.save()
    }

    public func setAppLock(enabled: Bool, now: Date = .now) throws {
        let settings = try loadOrCreateSettings()
        settings.appLockEnabled = enabled
        settings.modifiedAt = now
        try modelContext.save()
    }

    public func setHomeCurrency(_ code: String, now: Date = .now) throws {
        let settings = try loadOrCreateSettings()
        settings.homeCurrencyCode = code
        settings.modifiedAt = now
        try modelContext.save()
    }

    /// Removes every locally stored object. Used by "Delete All Data".
    /// Children are removed before the models they point at so batch deletes
    /// never trip a relationship constraint.
    public func deleteAllData() throws {
        try modelContext.delete(model: LedgerTransaction.self)
        try modelContext.delete(model: BalanceSnapshot.self)
        try modelContext.delete(model: Holding.self)
        try modelContext.delete(model: CategorizationRule.self)
        try modelContext.delete(model: Tag.self)
        try modelContext.delete(model: Category.self)
        try modelContext.delete(model: Account.self)
        try modelContext.delete(model: Institution.self)
        try modelContext.delete(model: AppSettings.self)
        try modelContext.save()
    }
}
