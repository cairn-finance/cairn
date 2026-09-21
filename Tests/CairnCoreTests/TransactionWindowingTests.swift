import Foundation
import SwiftData
import Testing
@testable import CairnCore

@Suite("List windowing")
struct ListWindowTests {
    @Test("Starts at the initial page and grows one page at a time")
    func expandsByPage() {
        var window = ListWindow()
        #expect(window.limit == 60)
        #expect(window.canExpand(total: 200))
        window.expand(total: 200)
        #expect(window.limit == 120)
        window.expand(total: 200)
        #expect(window.limit == 180)
    }

    @Test("Never grows past the total and stops expanding at the end")
    func clampsToTotal() {
        var window = ListWindow(initialLimit: 60)
        window.expand(total: 70)
        #expect(window.limit == 70)
        #expect(window.canExpand(total: 70) == false)
        #expect(window.effectiveLimit(total: 70) == 70)
    }

    @Test("Reset returns to the initial page for a new filter universe")
    func resets() {
        var window = ListWindow()
        window.expand(total: 500)
        window.reset()
        #expect(window.limit == ListWindow.initialLimit)
    }

    @Test("An empty result set yields a zero effective limit")
    func emptyTotal() {
        let window = ListWindow()
        #expect(window.effectiveLimit(total: 0) == 0)
    }
}

@Suite("Search debounce policy")
struct SearchDebounceTests {
    @Test("Whitespace-only search is treated as no search")
    func normalizesWhitespace() {
        #expect(SearchDebounce.normalize("   ") == "")
        #expect(SearchDebounce.normalize("\n\t ") == "")
        #expect(SearchDebounce.normalize("  coffee  ") == "coffee")
        #expect(SearchDebounce.normalize("coffee shop") == "coffee shop")
    }

    @Test("The debounce interval is a short, non-zero pause")
    func intervalIsSane() {
        #expect(SearchDebounce.interval > .zero)
        #expect(SearchDebounce.interval <= .milliseconds(500))
    }

    @Test("The query namespace changes when any filter part changes")
    func namespaceChanges() {
        let base = TransactionFilter()
        var searched = base
        searched.searchText = "coffee"
        #expect(base.namespace != searched.namespace)

        var quick = base
        quick.quick = .spending
        #expect(base.namespace != quick.namespace)

        // Same values produce the same namespace, so returning to a filter does
        // not force a needless reload.
        #expect(base.namespace == TransactionFilter().namespace)
    }
}

@Suite("Transaction section building")
struct TransactionSectionBuilderTests {
    private static func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Self.calendar().date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }

    private func row(
        id: String,
        date: Date,
        amount: Int64,
        transfer: Bool = false,
        ignored: Bool = false,
        category: String? = nil
    ) -> TransactionRowValue {
        TransactionRowValue(
            id: id,
            persistentID: nil,
            payeeDescription: "Merchant \(id)",
            amountMinorUnits: amount,
            currency: .usd,
            effectiveDate: date,
            isPending: false,
            isIgnored: ignored,
            isTransfer: transfer,
            countsAsTransfer: transfer,
            categoryName: category,
            categorySymbolName: nil,
            categoryColorHex: nil,
            accountName: "Checking",
            tagNames: []
        )
    }

    @Test("Groups rows by month then day, newest first, with totals")
    func groupsAndTotals() {
        let rows = [
            row(id: "a", date: date(2026, 2, 10), amount: -1_000),
            row(id: "b", date: date(2026, 2, 10), amount: 500),
            row(id: "c", date: date(2026, 2, 3), amount: -2_000, transfer: true),
            row(id: "d", date: date(2026, 1, 20), amount: -3_000),
            row(id: "e", date: date(2026, 2, 10), amount: -4_000, ignored: true),
        ]
        let months = TransactionSectionBuilder.months(from: rows, calendar: Self.calendar())
        #expect(months.count == 2)
        #expect(months[0].month == date(2026, 2, 1))
        #expect(months[1].month == date(2026, 1, 1))

        // February: only the -1_000 counts; the transfer and ignored rows do not.
        #expect(months[0].spentMinorUnits == 1_000)
        #expect(months[0].days.count == 2)
        #expect(months[0].days[0].day == date(2026, 2, 10))
        #expect(months[0].days[0].rows.count == 3)
        #expect(months[0].days[0].spentMinorUnits == 1_000)
        #expect(months[0].days[0].rows.first?.id == "a")
        #expect(months[1].spentMinorUnits == 3_000)
    }

    @Test("A single value per row is emitted, identity is the stable composite id")
    func stableIdentity() {
        let rows = [
            row(id: "A1/T1", date: date(2026, 2, 10), amount: -100),
            row(id: "A1/T2", date: date(2026, 2, 10), amount: -200),
        ]
        let months = TransactionSectionBuilder.months(from: rows, calendar: Self.calendar())
        let ids = months[0].days[0].rows.map(\.id)
        #expect(ids == ["A1/T1", "A1/T2"] || ids == ["A1/T2", "A1/T1"])
        #expect(Set(ids).count == 2)
    }
}

@Suite("Transaction query predicates")
@MainActor
struct TransactionFetchTests {
    private func makeStore() throws -> ModelContainer {
        try ModelContainerFactory.make(mode: .local, inMemory: true).container
    }

    private struct Seeded {
        let container: ModelContainer
        let accountA: Account
        let accountB: Account
        let groceries: CairnCore.Category
        let transfers: CairnCore.Category
        let tag: CairnCore.Tag
    }

    private func seed() throws -> Seeded {
        let container = try makeStore()
        let context = container.mainContext
        let accountA = Account(bankAccountID: "A1", name: "Checking")
        let accountB = Account(bankAccountID: "B1", name: "Savings")
        context.insert(accountA)
        context.insert(accountB)
        let groceries = Category(name: "Groceries")
        let transfers = Category(name: "Transfers")
        context.insert(groceries)
        context.insert(transfers)
        let tag = Tag(name: "trip")
        context.insert(tag)

        // 40 posted transactions alternating sign on account A, one pending.
        for index in 0..<40 {
            let transaction = LedgerTransaction(
                bankTransactionID: "A-\(index)",
                payeeDescription: index == 7 ? "Coffee Roasters" : "Merchant \(index)",
                amountMinorUnits: index % 2 == 0 ? -100 - Int64(index) : 100 + Int64(index)
            )
            transaction.account = accountA
            transaction.accountIDIndex = "A1"
            transaction.postedDate = Date(timeIntervalSince1970: Double(index) * 86_400)
            if index % 4 == 0 { transaction.userCategory = groceries }
            if index % 10 == 0 { transaction.userCategory = transfers }
            if index % 5 == 0 { transaction.tags = [tag] }
            context.insert(transaction)
        }
        // A pending row with no posted date.
        let pending = LedgerTransaction(bankTransactionID: "A-pending", payeeDescription: "Pending Charge", amountMinorUnits: -50)
        pending.account = accountA
        pending.accountIDIndex = "A1"
        pending.isPending = true
        pending.transactedAt = Date(timeIntervalSince1970: 10_000_000)
        context.insert(pending)

        // One row on account B.
        let other = LedgerTransaction(bankTransactionID: "B-1", payeeDescription: "Other", amountMinorUnits: -999)
        other.account = accountB
        other.accountIDIndex = "B1"
        other.postedDate = Date(timeIntervalSince1970: 1_000)
        context.insert(other)
        try context.save()
        return Seeded(
            container: container, accountA: accountA, accountB: accountB,
            groceries: groceries, transfers: transfers, tag: tag
        )
    }

    private func ids(
        _ container: ModelContainer,
        filter: TransactionFilter,
        pending: Bool? = nil,
        limit: Int? = nil
    ) throws -> [String] {
        try container.mainContext
            .fetch(TransactionFetch.descriptor(filter: filter, pending: pending, limit: limit))
            .map(\.bankTransactionID)
    }

    /// The SQL predicate followed by the snapshot refinement, which is what the
    /// windowed feed does page by page.
    private func refined(_ container: ModelContainer, filter: TransactionFilter, pending: Bool? = nil) throws -> [String] {
        try container.mainContext
            .fetch(TransactionFetch.descriptor(filter: filter, pending: pending))
            .filter { TransactionRefinement.matches($0.rowValue(), filter: filter) }
            .map(\.bankTransactionID)
    }

    @Test("Pending rows are fetched separately from posted rows")
    func pendingPartition() throws {
        let seeded = try seed()
        let pending = try ids(seeded.container, filter: TransactionFilter(), pending: true)
        #expect(pending == ["A-pending"])
        let posted = try ids(seeded.container, filter: TransactionFilter(), pending: false)
        #expect(posted.count == 41)
        #expect(!posted.contains("A-pending"))
    }

    @Test("Quick filters match the in-Swift semantics")
    func quickFilters() throws {
        let seeded = try seed()
        var spending = TransactionFilter()
        spending.quick = .spending
        // 20 even-index A rows are negative; indices 0, 10, 20, and 30 are
        // Transfers, and account B contributes one more negative row.
        let spendingIDs = try refined(seeded.container, filter: spending, pending: false)
        #expect(spendingIDs.count == 17)
        #expect(!spendingIDs.contains("A-0"))
        #expect(!spendingIDs.contains("A-10"))
        #expect(spendingIDs.contains("B-1"))

        var income = TransactionFilter()
        income.quick = .income
        #expect(try refined(seeded.container, filter: income, pending: false).count == 20)

        var uncategorized = TransactionFilter()
        uncategorized.quick = .uncategorized
        // Neither user nor auto category set, and not a transfer. Multiples of 4
        // and of 10 are categorized, leaving 28 rows on account A plus B-1.
        #expect(try refined(seeded.container, filter: uncategorized, pending: false).count == 29)

        var pending = TransactionFilter()
        pending.quick = .pending
        #expect(try ids(seeded.container, filter: pending).count == 1)
    }

    @Test("Category and tag refinement use relationships")
    func relationshipFilters() throws {
        let seeded = try seed()
        var byCategory = TransactionFilter()
        byCategory.categoryID = seeded.groceries.persistentModelID
        // index%4==0 sets Groceries, then index%10==0 overwrites some with
        // Transfers. Indices 0 and 20 are in both, leaving 8 Groceries rows.
        let categoryIDs = try refined(seeded.container, filter: byCategory, pending: false)
        #expect(categoryIDs.count == 8)
        #expect(categoryIDs.contains("A-4"))
        #expect(!categoryIDs.contains("A-0"))

        var byTag = TransactionFilter()
        byTag.tagID = seeded.tag.persistentModelID
        #expect(try refined(seeded.container, filter: byTag, pending: false).count == 8)
        // A row without the tag is excluded.
        #expect(!(try refined(seeded.container, filter: byTag, pending: false)).contains("A-1"))
    }

    @Test("Search matches payee, note, category, account, and tag")
    func searchFilter() throws {
        let seeded = try seed()
        var byPayee = TransactionFilter()
        byPayee.searchText = "Coffee"
        #expect(try refined(seeded.container, filter: byPayee, pending: false) == ["A-7"])

        var byAccount = TransactionFilter()
        byAccount.searchText = "Savings"
        #expect(try refined(seeded.container, filter: byAccount, pending: false) == ["B-1"])

        var byCategory = TransactionFilter()
        byCategory.searchText = "Transfers"
        #expect(try refined(seeded.container, filter: byCategory, pending: false).count == 4)

        var byTag = TransactionFilter()
        byTag.searchText = "trip"
        #expect(try refined(seeded.container, filter: byTag, pending: false).count == 8)

        var blank = TransactionFilter()
        blank.searchText = "   "
        #expect(try refined(seeded.container, filter: blank, pending: false).count == 41)
    }

    @Test("Search special characters do not change the meaning")
    func searchSpecialCharacters() throws {
        let seeded = try seed()
        var filter = TransactionFilter()
        filter.searchText = "%_\"'"
        // No merchant contains those characters, and none are treated as
        // wildcards, so the result is empty rather than everything.
        #expect(try refined(seeded.container, filter: filter, pending: false).isEmpty)
    }

    @Test("fetchCount bounds the SQL predicate without materializing rows")
    func countMatchesFetch() throws {
        let seeded = try seed()
        var filter = TransactionFilter()
        filter.quick = .spending
        // The SQL predicate applies the sign only; the transfer exclusion runs
        // during refinement. 20 negative rows on account A, one on account B,
        // and the pending charge.
        let counted = try seeded.container.mainContext.fetchCount(TransactionFetch.countDescriptor(filter: filter))
        #expect(counted == 22)
    }

    @Test("A limit bounds the fetched window")
    func limitBoundsWindow() throws {
        let seeded = try seed()
        let window = try ids(seeded.container, filter: TransactionFilter(), pending: false, limit: 10)
        #expect(window.count == 10)
        // Sorted by posted date descending, so the newest posted rows lead.
        #expect(window.first == "A-39")
    }

    @Test("rowValue snapshots display fields without holding the model")
    func rowValueMapping() throws {
        let seeded = try seed()
        let grocery = try #require(
            try seeded.container.mainContext.fetch(
                FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.bankTransactionID == "A-4" })
            ).first
        )
        let value = grocery.rowValue()
        #expect(value.payeeDescription == "Merchant 4")
        #expect(value.categoryName == "Groceries")
        #expect(value.accountName == "Checking")
        #expect(value.isIgnored == false)
        #expect(value.needsCategory == false)
        #expect(value.amount.minorUnits == -104)
    }
}
