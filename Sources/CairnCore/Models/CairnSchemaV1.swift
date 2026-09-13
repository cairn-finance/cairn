import Foundation
import SwiftData

/// Schema version 1. All persistent models live inside this `VersionedSchema`
/// so that future changes can be expressed as explicit migration stages.
///
/// CloudKit compatibility rules obeyed here:
/// - No `@Attribute(.unique)` / `#Unique`.
/// - Every scalar has a default value; relationships are optional.
/// - Every relationship has an inverse, declared on one side.
/// - Financial content is marked `@Attribute(.allowsCloudEncryption)`.
public enum CairnSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            Institution.self,
            Account.self,
            LedgerTransaction.self,
            Category.self,
            Tag.self,
            CategorizationRule.self,
            BalanceSnapshot.self,
            AppSettings.self,
        ]
    }

    /// A single SimpleFIN connection (one set of login credentials at one
    /// financial institution). Institutions can live at different SimpleFIN
    /// servers, so each stores its own credential identifier.
    @Model
    public final class Institution {
        public var bankConnectionID: String = ""
        @Attribute(.allowsCloudEncryption) public var name: String = ""
        public var orgID: String = ""
        public var orgURL: String?
        public var sfinURL: String = ""
        public var credentialID: UUID = UUID()
        public var isActive: Bool = true
        public var lastSyncDate: Date?
        public var lastSyncError: String?
        public var createdAt: Date = Date.now

        // Per-institution SimpleFIN request budget. Each institution has its own
        // Access URL (its own SimpleFIN account and daily limit), so the budget
        // must not be shared between banks.
        public var lastSuccessfulFetch: Date?
        public var dailyRequestCount: Int = 0
        public var dailyRequestDate: Date?

        @Relationship(deleteRule: .cascade, inverse: \Account.institution)
        public var accounts: [Account]?

        public init(
            bankConnectionID: String = "",
            name: String = "",
            orgID: String = "",
            orgURL: String? = nil,
            sfinURL: String = "",
            credentialID: UUID = UUID()
        ) {
            self.bankConnectionID = bankConnectionID
            self.name = name
            self.orgID = orgID
            self.orgURL = orgURL
            self.sfinURL = sfinURL
            self.credentialID = credentialID
        }
    }

    /// A bank account. Balance is held as integer minor units in the account's
    /// currency; it is never summed across currencies.
    @Model
    public final class Account {
        public var bankAccountID: String = ""
        @Attribute(.allowsCloudEncryption) public var name: String = ""
        @Attribute(.allowsCloudEncryption) public var customDisplayName: String?
        public var currencyCode: String = "USD"
        public var currencyExponent: Int = 2
        public var isCustomCurrency: Bool = false
        public var customCurrencyName: String?
        public var customCurrencyAbbreviation: String?

        @Attribute(.allowsCloudEncryption) public var balanceMinorUnits: Int64 = 0
        @Attribute(.allowsCloudEncryption) public var availableBalanceMinorUnits: Int64 = 0
        public var hasAvailableBalance: Bool = false
        public var balanceDate: Date?

        public var isHidden: Bool = false
        public var includeInNetWorth: Bool = true
        public var displayOrder: Int = 0
        public var lastSyncedAt: Date?

        /// Where the account's data comes from. Manual accounts are for
        /// institutions SimpleFIN can't reach (Apple Card, Apple Savings, cash,
        /// property, loans) and receive imported transactions.
        public var sourceRaw: String = AccountSource.simpleFIN.rawValue
        public var accountTypeRaw: String = AccountType.other.rawValue
        @Attribute(.allowsCloudEncryption) public var startingBalanceMinorUnits: Int64 = 0

        public var institution: Institution?

        @Relationship(deleteRule: .cascade, inverse: \LedgerTransaction.account)
        public var transactions: [LedgerTransaction]?

        @Relationship(deleteRule: .cascade, inverse: \BalanceSnapshot.account)
        public var snapshots: [BalanceSnapshot]?

        public init(
            bankAccountID: String = "",
            name: String = "",
            currency: Currency = .usd
        ) {
            self.bankAccountID = bankAccountID
            self.name = name
            apply(currency: currency)
        }

        public var currency: Currency {
            Currency(
                code: currencyCode,
                exponent: currencyExponent,
                isCustom: isCustomCurrency,
                customName: customCurrencyName,
                customAbbreviation: customCurrencyAbbreviation
            )
        }

        public func apply(currency: Currency) {
            currencyCode = currency.code
            currencyExponent = currency.exponent
            isCustomCurrency = currency.isCustom
            customCurrencyName = currency.customName
            customCurrencyAbbreviation = currency.customAbbreviation
        }

        /// The name a person should see: their override when present.
        public var displayName: String {
            if let customDisplayName, !customDisplayName.isEmpty { return customDisplayName }
            return name
        }

        public var source: AccountSource { AccountSource(rawValue: sourceRaw) ?? .simpleFIN }
        public var accountType: AccountType { AccountType(rawValue: accountTypeRaw) ?? .other }
        public var isManual: Bool { source == .manual }

        public var balance: Money {
            Money(minorUnits: balanceMinorUnits, currency: currency)
        }

        public var availableBalance: Money {
            Money(minorUnits: availableBalanceMinorUnits, currency: currency)
        }
    }

    /// A bank transaction, split into bank-owned, automation-owned, and
    /// user-owned fields so sync and categorization can never clobber a manual
    /// choice. Effective category is `userCategory ?? autoCategory`.
    @Model
    public final class LedgerTransaction {
        public var bankTransactionID: String = ""

        // Bank-owned: overwritten on every sync.
        @Attribute(.allowsCloudEncryption) public var payeeDescription: String = ""
        @Attribute(.allowsCloudEncryption) public var amountMinorUnits: Int64 = 0
        public var postedDate: Date?
        public var transactedAt: Date?
        public var isPending: Bool = false
        public var currencyExponent: Int = 2

        /// Number of consecutive syncs where a pending charge disappeared
        /// without a matching posted transaction.
        public var pendingMismatchCount: Int = 0

        // Automation-owned: only the rules engine / on-device model writes these.
        // Inverses are declared on `Category`.
        public var autoCategory: Category?
        public var autoCategorySource: String?
        public var autoConfidence: Double = 0

        // User-owned: no automation ever writes these.
        @Attribute(.allowsCloudEncryption) public var note: String?
        public var userCategory: Category?
        public var isTransfer: Bool = false
        public var isIgnored: Bool = false
        public var reviewedAt: Date?

        public var modifiedAt: Date = Date.now
        public var modifiedByDeviceID: String = ""
        public var createdAt: Date = Date.now

        /// Lowercased merchant name used for grouping, recurring detection, and
        /// import de-duplication.
        public var normalizedMerchant: String = ""
        /// True when the transaction was added by a CSV import rather than a sync.
        public var isImported: Bool = false

        public var account: Account?

        /// Inverse declared on `Tag.transactions`.
        public var tags: [Tag]?

        #Index<LedgerTransaction>(
            [\.accountIDIndex],
            [\.bankTransactionID],
            [\.postedDate]
        )

        /// A stored, non-encrypted mirror of the owning account's bank id, used
        /// for indexing and predicates (encrypted fields cannot be indexed).
        public var accountIDIndex: String = ""

        public init(
            bankTransactionID: String = "",
            payeeDescription: String = "",
            amountMinorUnits: Int64 = 0
        ) {
            self.bankTransactionID = bankTransactionID
            self.payeeDescription = payeeDescription
            self.amountMinorUnits = amountMinorUnits
        }

        public var effectiveCategory: Category? {
            userCategory ?? autoCategory
        }

        public var isCategorizedByUser: Bool {
            userCategory != nil
        }

        public var amount: Money {
            if let account {
                // Use the account's full currency so custom (non-ISO) currencies
                // keep their name and abbreviation instead of showing the URL.
                return Money(minorUnits: amountMinorUnits, currency: account.currency)
            }
            return Money(
                minorUnits: amountMinorUnits,
                currency: Currency(code: "USD", exponent: currencyExponent)
            )
        }

        /// The date used for ordering and history math.
        public var effectiveDate: Date {
            postedDate ?? transactedAt ?? createdAt
        }
    }

    /// A user-defined spending category. Flat for now; `parent`/`children` are
    /// reserved for nested categories.
    @Model
    public final class Category {
        /// Stable, sync-safe identity used by the rules engine and exporters,
        /// which operate on value snapshots rather than model objects.
        public var uuid: UUID = UUID()
        @Attribute(.allowsCloudEncryption) public var name: String = ""
        public var symbolName: String = "tag"
        public var colorHex: String = "#8E8E93"
        public var sortOrder: Int = 0
        public var isArchived: Bool = false
        public var isSystem: Bool = false
        public var createdAt: Date = Date.now

        @Relationship(inverse: \Category.parent)
        public var children: [Category]?

        public var parent: Category?

        @Relationship(inverse: \LedgerTransaction.userCategory)
        public var userTransactions: [LedgerTransaction]?

        @Relationship(inverse: \LedgerTransaction.autoCategory)
        public var autoTransactions: [LedgerTransaction]?

        @Relationship(inverse: \CategorizationRule.assignedCategory)
        public var rules: [CategorizationRule]?

        #Index<Category>([\.sortOrder])

        public init(
            name: String = "",
            symbolName: String = "tag",
            colorHex: String = "#8E8E93",
            sortOrder: Int = 0,
            isSystem: Bool = false,
            uuid: UUID = UUID()
        ) {
            self.name = name
            self.symbolName = symbolName
            self.colorHex = colorHex
            self.sortOrder = sortOrder
            self.isSystem = isSystem
            self.uuid = uuid
        }
    }

    @Model
    public final class Tag {
        @Attribute(.allowsCloudEncryption) public var name: String = ""
        public var colorHex: String = "#8E8E93"
        public var createdAt: Date = Date.now

        @Relationship(inverse: \LedgerTransaction.tags)
        public var transactions: [LedgerTransaction]?

        public init(name: String = "", colorHex: String = "#8E8E93") {
            self.name = name
            self.colorHex = colorHex
        }
    }

    /// A local, on-device categorization rule. Value-type snapshots are fed to
    /// the pure rules engine.
    @Model
    public final class CategorizationRule {
        @Attribute(.allowsCloudEncryption) public var name: String = ""
        public var uuid: UUID = UUID()
        public var fieldRaw: String = RuleField.payee.rawValue
        public var matchKindRaw: String = RuleMatchKind.contains.rawValue
        @Attribute(.allowsCloudEncryption) public var pattern: String = ""
        public var minAmountMinorUnits: Int64?
        public var maxAmountMinorUnits: Int64?
        public var priority: Int = 0
        public var isEnabled: Bool = true
        public var createdAt: Date = Date.now

        /// Inverse declared on `Category.rules`.
        public var assignedCategory: Category?

        public init(
            name: String = "",
            field: RuleField = .payee,
            matchKind: RuleMatchKind = .contains,
            pattern: String = "",
            assignedCategory: Category? = nil,
            priority: Int = 0,
            uuid: UUID = UUID()
        ) {
            self.name = name
            self.fieldRaw = field.rawValue
            self.matchKindRaw = matchKind.rawValue
            self.pattern = pattern
            self.assignedCategory = assignedCategory
            self.priority = priority
            self.uuid = uuid
        }
    }

    /// A cached net-worth data point. History can also be reconstructed from
    /// transactions; snapshots act as anchors and speed up charts.
    @Model
    public final class BalanceSnapshot {
        public var day: Date = Date.now
        @Attribute(.allowsCloudEncryption) public var balanceMinorUnits: Int64 = 0
        public var account: Account?

        public init(day: Date = Date.now, balanceMinorUnits: Int64 = 0) {
            self.day = day
            self.balanceMinorUnits = balanceMinorUnits
        }
    }

    /// A singleton settings row that also syncs, so every device shares the
    /// SimpleFIN rate budget and refresh bookkeeping.
    @Model
    public final class AppSettings {
        public var key: String = "default"
        public var useCloudKit: Bool = false
        public var onboardingComplete: Bool = false
        public var appLockEnabled: Bool = false
        public var homeCurrencyCode: String = "USD"
        // Superseded by the per-institution counters on `Institution`; retained
        // so the schema does not need a destructive change.
        public var lastSuccessfulFetch: Date?
        public var dailyRequestCount: Int = 0
        public var dailyRequestDate: Date?
        public var minimumRefreshIntervalHours: Int = 6
        public var hasSeededDefaultCategories: Bool = false
        public var createdByDeviceID: String = ""
        public var modifiedAt: Date = Date.now

        public init() {}
    }
}

// MARK: - Short names

public typealias Institution = CairnSchemaV1.Institution
public typealias Account = CairnSchemaV1.Account
public typealias LedgerTransaction = CairnSchemaV1.LedgerTransaction
public typealias Category = CairnSchemaV1.Category
public typealias Tag = CairnSchemaV1.Tag
public typealias CategorizationRule = CairnSchemaV1.CategorizationRule
public typealias BalanceSnapshot = CairnSchemaV1.BalanceSnapshot
public typealias AppSettings = CairnSchemaV1.AppSettings

/// How a rule inspects a transaction.
public enum RuleField: String, Sendable, CaseIterable, Codable {
    case payee
    case amount

    public var displayName: String {
        switch self {
        case .payee: "Description"
        case .amount: "Amount"
        }
    }
}

/// How a rule's pattern is compared.
public enum RuleMatchKind: String, Sendable, CaseIterable, Codable {
    case contains
    case beginsWith
    case endsWith
    case equals
    case regularExpression

    public var displayName: String {
        switch self {
        case .contains: "Contains"
        case .beginsWith: "Begins With"
        case .endsWith: "Ends With"
        case .equals: "Equals"
        case .regularExpression: "Regular Expression"
        }
    }
}

/// Where an account's data comes from.
public enum AccountSource: String, Sendable, CaseIterable, Codable {
    /// Synced from SimpleFIN.
    case simpleFIN = "simplefin"
    /// Created by the user and filled by CSV import or manual entry.
    case manual

    public var displayName: String {
        switch self {
        case .simpleFIN: "SimpleFIN"
        case .manual: "Manual"
        }
    }
}

/// The kind of account, used for grouping and net-worth classification.
public enum AccountType: String, Sendable, CaseIterable, Codable {
    case checking
    case savings
    case credit
    case investment
    case loan
    case cash
    case other

    public var displayName: String {
        switch self {
        case .checking: "Checking"
        case .savings: "Savings"
        case .credit: "Credit Card"
        case .investment: "Investment"
        case .loan: "Loan"
        case .cash: "Cash"
        case .other: "Other"
        }
    }

    /// Liabilities reduce net worth.
    public var isLiability: Bool {
        self == .credit || self == .loan
    }
}
