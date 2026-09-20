import Foundation
import SwiftData

/// The active Activity/list filter, expressed as values so it can drive a
/// SwiftData predicate and a pure, testable refinement over row snapshots.
///
/// `Sendable` and `Equatable`: a `.task(id:)` can react to changes, and the
/// identity string namespaces list diffing so switching filters never reuses a
/// row identity from the previous result set.
public struct TransactionFilter: Sendable, Equatable {
    public enum Quick: String, Sendable, CaseIterable, Identifiable {
        case all, spending, income, pending, uncategorized

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .all: "All"
            case .spending: "Spending"
            case .income: "Income"
            case .pending: "Pending"
            case .uncategorized: "Needs category"
            }
        }

        public var systemImage: String? {
            switch self {
            case .all: nil
            case .spending: "arrow.up.right"
            case .income: "arrow.down.left"
            case .pending: "clock"
            case .uncategorized: "questionmark.circle"
            }
        }
    }

    public var quick: Quick
    public var categoryID: PersistentIdentifier?
    public var accountID: PersistentIdentifier?
    public var tagID: PersistentIdentifier?
    public var searchText: String

    public init(
        quick: Quick = .all,
        categoryID: PersistentIdentifier? = nil,
        accountID: PersistentIdentifier? = nil,
        tagID: PersistentIdentifier? = nil,
        searchText: String = ""
    ) {
        self.quick = quick
        self.categoryID = categoryID
        self.accountID = accountID
        self.tagID = tagID
        self.searchText = searchText
    }

    /// The search term with surrounding whitespace removed. Spaces-only input
    /// must not issue a query that matches everything.
    public var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isActive: Bool {
        quick != .all || categoryID != nil || accountID != nil || tagID != nil || !trimmedSearch.isEmpty
    }

    /// A stable name for the current filter universe. The list uses it to
    /// namespace row identities so a diff never carries a row across filters.
    public var namespace: String {
        let parts: [String] = [
            quick.rawValue,
            categoryID.map(String.init(describing:)) ?? "-",
            accountID.map(String.init(describing:)) ?? "-",
            tagID.map(String.init(describing:)) ?? "-",
            trimmedSearch,
        ]
        return parts.joined(separator: "|")
    }
}

/// Builds bounded, predicate-driven fetches for transaction lists.
///
/// The predicate carries everything the database can cheaply and reliably
/// evaluate: the pending partition, the quick filter's sign, and the explicit
/// category and account relationships. The remaining filters (the built-in
/// money-movement exclusion, tag membership, and free-text search) are applied
/// by ``TransactionRefinement`` to the row snapshots as pages are fetched. That
/// split exists because a single `#Predicate` literal combining all of them
/// exceeds the Swift type-checker's expression budget; see
/// `docs/performance-scaling.md`.
public enum TransactionFetch {
    public static func descriptor(
        filter: TransactionFilter,
        pending: Bool? = nil,
        limit: Int? = nil,
        offset: Int? = nil,
        sortOrder: SortOrder = .reverse
    ) -> FetchDescriptor<LedgerTransaction> {
        var descriptor = FetchDescriptor<LedgerTransaction>(
            predicate: predicate(filter: filter, pending: pending),
            sortBy: [SortDescriptor(\LedgerTransaction.postedDate, order: sortOrder)]
        )
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset
        return descriptor
    }

    public static func countDescriptor(filter: TransactionFilter) -> FetchDescriptor<LedgerTransaction> {
        FetchDescriptor<LedgerTransaction>(predicate: predicate(filter: filter, pending: nil))
    }

    /// The request signature that should trigger a reload. Changes only when a
    /// value that alters the query changes, so text typed and deleted back to
    /// the same string does not re-query.
    public static func signature(filter: TransactionFilter) -> String {
        filter.namespace
    }

    /// The SQL-level predicate. Deliberately small so the macro type-checks; the
    /// rest of the filtering runs over snapshots in ``TransactionRefinement``.
    private static func predicate(filter: TransactionFilter, pending: Bool?) -> Predicate<LedgerTransaction> {
        let accountID = filter.accountID
        let spendOnly = filter.quick == .spending
        let incomeOnly = filter.quick == .income
        let pendingOnly = filter.quick == .pending
        let onlyPosted = pending == false
        let onlyPending = pending == true

        return #Predicate<LedgerTransaction> { transaction in
            (!onlyPosted || !transaction.isPending)
                && (!onlyPending || transaction.isPending)
                && (!pendingOnly || transaction.isPending)
                && (!spendOnly || transaction.amountMinorUnits < 0)
                && (!incomeOnly || transaction.amountMinorUnits > 0)
                && (accountID == nil || transaction.account?.persistentModelID == accountID)
        }
    }
}

/// The filters that run over immutable row snapshots rather than in SQL.
///
/// Pure and `Sendable`, so it is unit-tested directly and can run on the actor
/// that assembled the snapshots. Order and totals are unaffected: refinement
/// only decides inclusion.
public enum TransactionRefinement {
    /// Whether a row survives the active filter. The SQL predicate has already
    /// applied the sign and relationship parts; this adds the money-movement
    /// exclusion, the tag match, and the free-text search.
    public static func matches(_ row: TransactionRowValue, filter: TransactionFilter) -> Bool {
        switch filter.quick {
        case .all, .pending:
            break
        case .spending, .income:
            if row.countsAsTransfer { return false }
        case .uncategorized:
            if !row.needsCategory { return false }
        }

        if let categoryID = filter.categoryID, row.categoryID != categoryID {
            return false
        }

        if let tagID = filter.tagID, !row.tagIDs.contains(tagID) {
            return false
        }

        let search = filter.trimmedSearch
        if !search.isEmpty, !matches(search, row: row) {
            return false
        }
        return true
    }

    /// Case- and diacritic-insensitive match over every field the person can
    /// search: merchant, note, category, account, and tags.
    public static func matches(_ search: String, row: TransactionRowValue) -> Bool {
        row.payeeDescription.localizedStandardContains(search)
            || (row.note?.localizedStandardContains(search) ?? false)
            || (row.categoryName?.localizedStandardContains(search) ?? false)
            || (row.accountName?.localizedStandardContains(search) ?? false)
            || row.tagNames.contains { $0.localizedStandardContains(search) }
    }
}

/// How many rows a windowed list keeps loaded and how it grows as the reader
/// scrolls toward the end.
///
/// The window starts small so opening Activity never materializes a long
/// ledger; each step loads one more page at the bottom, which leaves the
/// already-visible rows' positions unchanged (their identities and order do not
/// move), so the viewport stays anchored.
public struct ListWindow: Sendable, Equatable {
    public static let initialLimit = 60
    public static let pageSize = 60

    public private(set) var limit: Int

    public init(initialLimit: Int = ListWindow.initialLimit) {
        self.limit = max(1, initialLimit)
    }

    public func canExpand(total: Int) -> Bool {
        limit < total
    }

    /// The limit after loading one more page, never past the total.
    public func nextLimit(total: Int) -> Int {
        min(max(0, total), limit + Self.pageSize)
    }

    public mutating func expand(total: Int) {
        limit = nextLimit(total: total)
    }

    /// Loads one more page when the total is not known up front (a filtered
    /// result set is scanned until the window fills).
    public mutating func advance() {
        limit += Self.pageSize
    }

    public mutating func reset() {
        limit = Self.initialLimit
    }

    /// The limit that may actually be sent to the fetch.
    public func effectiveLimit(total: Int) -> Int {
        min(limit, max(0, total))
    }
}

/// Tunables for debounced search. Kept as a value so the policy is testable and
/// the same delay is used wherever a search field triggers a query.
public enum SearchDebounce {
    /// How long typing must pause before the predicate is rebuilt.
    public static let interval = Duration.milliseconds(250)

    /// Normalizes a raw search field value; an all-whitespace string means "no
    /// search" rather than a match-everything query.
    public static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
