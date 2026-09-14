import Foundation
import SwiftData

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
        guard let institution = self[institutionID, as: Institution.self] else {
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
        guard let institution = self[institutionID, as: Institution.self] else {
            throw SimpleFINError.transport("This institution is no longer in the local database.")
        }

        rollRequestCounterIfNeeded(institution, now: now, calendar: calendar)

        let label = institution.name.isEmpty ? "institution" : institution.name
        await cairnLog(
            .info,
            "Sync started for \(label). lastSync=\(institution.lastSyncDate.map(Self.iso) ?? "never")"
        )

        let candidates = Self.candidateStartDates(
            lastSyncDate: institution.lastSyncDate,
            now: now,
            calendar: calendar
        )

        var lastError: any Error = SimpleFINError.httpStatus(-1)
        for (index, startDate) in candidates.enumerated() {
            let isLast = index == candidates.count - 1
            let windowDays = Int(now.timeIntervalSince(startDate) / 86_400)
            await cairnLog(.info, "Requesting a \(windowDays)-day window (attempt \(index + 1) of \(candidates.count)).")
            institution.dailyRequestCount += 1

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
                    institutionID: institution.persistentModelID,
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
                institution.lastSyncError = message
                // A brand-new connection is inserted as "Connecting…". If the
                // very first fetch fails, replace that placeholder.
                if institution.name.isEmpty || institution.name == "Connecting…" {
                    institution.name = Self.fallbackName(for: accessURL)
                }
                try? modelContext.save()
                throw error
            }
        }

        // Every candidate window was rejected.
        let message = Self.describe(lastError)
        await cairnLog(.error, "Sync exhausted all windows: \(message)")
        institution.lastSyncError = message
        try? modelContext.save()
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
        guard let owner = self[institutionID, as: Institution.self] else {
            throw SimpleFINError.transport("This institution is no longer in the local database.")
        }

        var outcome = SyncOutcome()
        let hadServerErrors = !accountSet.errors.isEmpty

        let owners = try institutions(forConnections: accountSet.connections, owner: owner)

        // Never leave a brand-new connection labeled "Connecting…".
        if owner.name.isEmpty || owner.name == "Connecting…",
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
    static func fallbackName(for accessURL: URL) -> String {
        if let host = accessURL.host, !host.isEmpty {
            return host
        }
        return "Institution"
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
        if account.accountTypeRaw == AccountType.other.rawValue {
            account.accountTypeRaw = Self.inferAccountType(from: simpleAccount.name).rawValue
        }
        outcome.accountsUpserted += 1
        return account
    }

    /// Best-effort account type from its name, used when SimpleFIN provides no
    /// type information.
    private static func inferAccountType(from name: String) -> AccountType {
        let lowered = name.lowercased()
        if lowered.contains("credit") || lowered.contains("card") { return .credit }
        if lowered.contains("saving") { return .savings }
        if lowered.contains("checking") { return .checking }
        if lowered.contains("invest") || lowered.contains("brokerage") || lowered.contains("retire") {
            return .investment
        }
        if lowered.contains("loan") || lowered.contains("mortgage") { return .loan }
        return .other
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
        /// Uncategorized transactions still awaiting the on-device model.
        public var remaining: Int = 0
        public var bySource: [String: Int] = [:]

        public init() {}
    }

    /// Re-runs categorization over transactions with no user category, using
    /// rules, merchant memory learned from the person's own corrections, and
    /// deterministic hints for money movement and fees.
    ///
    /// Never overwrites a user choice. A rule or an exact remembered category
    /// may replace an earlier on-device guess; a fuzzy match may not.
    @discardableResult
    public func recategorize(now: Date = .now) throws -> RecategorizeOutcome {
        let rules = try loadRuleSnapshots()
        let memory = try buildMerchantMemory()
        let transactions = try modelContext.fetch(FetchDescriptor<LedgerTransaction>())
        let fees = try category(named: "Fees")
        var outcome = RecategorizeOutcome()
        var didChange = false

        for transaction in transactions {
            guard transaction.userCategory == nil, !transaction.isIgnored else { continue }

            let merchant = Self.merchantName(transaction)
            let suggestion = CategorySuggester.suggest(
                description: transaction.payeeDescription,
                merchant: merchant,
                amountMinorUnits: transaction.amountMinorUnits,
                rules: rules,
                memory: memory
            )

            let isModelSourced = transaction.autoCategorySource == SuggestionSource.appleIntelligence.rawValue
                || transaction.autoCategorySource == "model"
            if isModelSourced, suggestion?.source == .similarMerchant {
                // Keep the model's guess rather than downgrade it to a fuzzy match.
                continue
            }

            if let suggestion, let category = try? category(withUUID: suggestion.categoryID) {
                transaction.autoCategory = category
                transaction.autoCategorySource = suggestion.source.rawValue
                transaction.autoConfidence = suggestion.confidence
                if !transaction.isTransferUserSet {
                    transaction.isTransfer = category.name == "Transfers"
                }
                transaction.modifiedAt = now
                outcome.categorized += 1
                outcome.bySource[suggestion.source.rawValue, default: 0] += 1
                didChange = true
                continue
            }

            // No rule or history: apply deterministic hints.
            if TransactionHints.isExplicitFee(description: transaction.payeeDescription), let fees {
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
                if !transaction.isTransfer || transaction.autoCategory != nil {
                    transaction.isTransfer = true
                    transaction.autoCategory = nil
                    transaction.autoCategorySource = nil
                    transaction.autoConfidence = 0
                    transaction.modifiedAt = now
                    didChange = true
                }
                continue
            }
        }

        if didChange {
            try modelContext.save()
        }
        return outcome
    }

    /// Immediately applies a person's category choice to their other, still
    /// automatic rows for the same merchant, so a correction sticks instead of
    /// waiting for the next sync.
    @discardableResult
    public func propagateUserCategory(
        transactionID: PersistentIdentifier,
        now: Date = .now
    ) throws -> Int {
        guard let transaction = self[transactionID, as: LedgerTransaction.self],
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

    /// Runs the on-device Apple Intelligence model over a bounded batch of
    /// uncategorized transactions. Purely local: it uses `SystemLanguageModel`
    /// and never the Private Cloud Compute model.
    ///
    /// Every transaction it looks at is stamped so later automatic runs don't
    /// retry it, whether or not a category was found.
    @discardableResult
    public func appleIntelligenceCategorizeBatch(
        limit: Int = 12,
        now: Date = .now
    ) async throws -> RecategorizeOutcome {
        var outcome = RecategorizeOutcome()

        let categories = try modelContext.fetch(FetchDescriptor<Category>())
            .filter {
                !$0.isArchived
                    && $0.name != "Income"
                    && $0.name != "Transfers"
                    && $0.name != "Fees"
            }
        guard !categories.isEmpty else { return outcome }
        let names = categories.map(\.name)

        let all = try modelContext.fetch(FetchDescriptor<LedgerTransaction>())
        let candidates = all
            .filter { Self.needsCategory($0) && $0.autoCategorizeAttemptedAt == nil }
            .sorted { $0.effectiveDate > $1.effectiveDate }

        guard !candidates.isEmpty else { return outcome }
        guard AppleIntelligenceCategorizer.isAvailable else {
            outcome.remaining = candidates.count
            return outcome
        }

        for transaction in candidates.prefix(limit) {
            let merchant = Self.merchantName(transaction)

            // Never ask the model about money movement. Mark it a transfer and
            // move on; this is the guard that stops overdraft transfers and
            // peer-to-peer payments from being guessed into a spending category.
            if TransactionHints.isInternalTransfer(
                description: transaction.payeeDescription,
                merchant: transaction.normalizedMerchant
            ), !transaction.isTransferUserSet {
                transaction.isTransfer = true
                transaction.autoCategory = nil
                transaction.autoCategorySource = nil
                transaction.autoConfidence = 0
                transaction.autoCategorizeAttemptedAt = now
                transaction.modifiedAt = now
                outcome.attempted += 1
                continue
            }

            transaction.autoCategorizeAttemptedAt = now
            outcome.attempted += 1

            if let name = try? await AppleIntelligenceCategorizer.classify(
                merchant: merchant,
                description: transaction.payeeDescription,
                categories: names
            ), let category = categories.first(where: { $0.name == name }) {
                transaction.autoCategory = category
                transaction.autoCategorySource = SuggestionSource.appleIntelligence.rawValue
                transaction.autoConfidence = 0.8
                transaction.modifiedAt = now
                outcome.categorized += 1
                outcome.bySource[SuggestionSource.appleIntelligence.rawValue, default: 0] += 1
            }
        }

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

    /// Builds merchant memory from transactions the person categorized.
    private func buildMerchantMemory() throws -> MerchantMemory {
        let transactions = try modelContext.fetch(FetchDescriptor<LedgerTransaction>())
        let samples = transactions.compactMap { transaction -> MemorySample? in
            guard let category = transaction.userCategory else { return nil }
            let merchant = Self.merchantName(transaction)
            guard !merchant.isEmpty else { return nil }
            return MemorySample(merchant: merchant, categoryID: category.uuid)
        }
        return MerchantMemory(samples: samples)
    }

    // MARK: - Categories

    /// Seeds a small, sensible default set once, so categorization works before
    /// the user creates anything.
    public func seedDefaultCategoriesIfNeeded(now: Date = .now) throws {
        let settings = try loadOrCreateSettings()
        guard !settings.hasSeededDefaultCategories else { return }

        // A second device could reach this point before iCloud has delivered the
        // first device's categories. If any category already exists, mark the
        // seed as done instead of inserting a duplicate set.
        let existingCategories = try modelContext.fetchCount(FetchDescriptor<Category>())
        guard existingCategories == 0 else {
            settings.hasSeededDefaultCategories = true
            settings.modifiedAt = now
            try modelContext.save()
            return
        }

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

        for (index, item) in defaults.enumerated() {
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
        settings.modifiedAt = now
        try modelContext.save()
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
        guard let account = self[intoAccountID, as: Account.self] else {
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
        let sum = transactions.reduce(Int64(0)) { $0 + $1.amountMinorUnits }
        account.balanceMinorUnits = account.startingBalanceMinorUnits + sum
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
        try modelContext.delete(model: CategorizationRule.self)
        try modelContext.delete(model: Tag.self)
        try modelContext.delete(model: Category.self)
        try modelContext.delete(model: Account.self)
        try modelContext.delete(model: Institution.self)
        try modelContext.delete(model: AppSettings.self)
        try modelContext.save()
    }
}
