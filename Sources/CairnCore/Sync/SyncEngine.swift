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
    public static let initialBackfillDays = 365
    public static let syncOverlapDays = 7
    public static let stalePendingThreshold = 2

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
    /// the UI never overstates the remaining budget.
    public func minimumRemainingBudget(now: Date, calendar: Calendar = .current) throws -> Int {
        let institutions = try modelContext.fetch(FetchDescriptor<Institution>())
        guard !institutions.isEmpty else { return Self.dailyRequestLimit }
        var minimum = Self.dailyRequestLimit
        for institution in institutions {
            rollRequestCounterIfNeeded(institution, now: now, calendar: calendar)
            minimum = min(minimum, max(0, Self.dailyRequestLimit - institution.dailyRequestCount))
        }
        return minimum
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

        let startDate: Date
        if let lastSync = institution.lastSyncDate,
           let overlap = calendar.date(byAdding: .day, value: -Self.syncOverlapDays, to: lastSync) {
            startDate = overlap
        } else {
            startDate = calendar.date(byAdding: .day, value: -Self.initialBackfillDays, to: now) ?? now
        }

        do {
            let accountSet = try await client.fetchAccounts(
                accessURL: accessURL,
                startDate: startDate,
                includePending: true
            )

            var outcome = SyncOutcome()
            if let firstError = accountSet.errors.first {
                outcome.serverErrors = accountSet.errors.map(\.message)
                institution.lastSyncError = firstError.message
            } else {
                institution.lastSyncError = nil
            }

            // Update connection metadata.
            if let connection = accountSet.connections.first(where: { $0.id == institution.bankConnectionID })
                ?? accountSet.connections.first {
                institution.name = connection.name
                institution.orgID = connection.organizationID
                institution.orgURL = connection.organizationURL
                if !connection.simpleFINURL.isEmpty {
                    institution.sfinURL = connection.simpleFINURL
                }
                institution.bankConnectionID = connection.id
            }

            let ruleSnapshots = try loadRuleSnapshots()

            for simpleAccount in accountSet.accounts {
                let account = try upsertAccount(simpleAccount, institution: institution, now: now, outcome: &outcome)
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

            institution.lastSyncDate = now
            institution.lastSuccessfulFetch = now
            institution.dailyRequestCount += 1

            try modelContext.save()
            outcome.finishedAt = now
            return outcome
        } catch {
            institution.lastSyncError = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            institution.dailyRequestCount += 1
            try? modelContext.save()
            throw error
        }
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

        let account: Account
        if let existing = try modelContext.fetch(descriptor).first {
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
        guard transaction.autoCategorySource != "model" else { return }
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
