import SwiftUI
import SwiftData
import CairnCore

struct TransactionsView: View {
    @Query(sort: [SortDescriptor(\LedgerTransaction.postedDate, order: .reverse)])
    private var allTransactions: [LedgerTransaction]
    @Query(sort: [SortDescriptor(\CairnSchemaV1.Category.sortOrder)])
    private var categories: [CairnSchemaV1.Category]
    @Query(sort: [SortDescriptor(\Account.displayOrder)])
    private var accounts: [Account]

    @State private var searchText = ""
    @State private var showPendingOnly = false
    @State private var categoryFilter: CairnSchemaV1.Category?
    @State private var accountFilter: Account?

    var body: some View {
        List {
            if filtered.isEmpty {
                Section {
                    Text(emptyMessage)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            } else {
                ForEach(grouped, id: \.month) { group in
                    Section {
                        ForEach(group.transactions) { transaction in
                            NavigationLink {
                                TransactionDetailView(transaction: transaction)
                            } label: {
                                TransactionRow(transaction: transaction)
                            }
                        }
                    } header: {
                        monthHeader(group)
                    }
                }
            }
        }
        .cairnListStyle()
        .navigationTitle("Transactions")
        .searchable(text: $searchText, prompt: "Search descriptions, notes, tags")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showPendingOnly.toggle()
                } label: {
                    Label("Pending", systemImage: showPendingOnly ? "clock.fill" : "clock")
                }
                .tint(showPendingOnly ? Color.accentColor : nil)
            }
            ToolbarItem(placement: .primaryAction) {
                filtersMenu
            }
        }
    }

    private var filtersMenu: some View {
        Menu {
            Picker("Category", selection: $categoryFilter) {
                Text("All Categories").tag(CairnSchemaV1.Category?.none)
                ForEach(categories) { category in
                    Label(category.name, systemImage: category.symbolName).tag(CairnSchemaV1.Category?.some(category))
                }
            }
            Picker("Account", selection: $accountFilter) {
                Text("All Accounts").tag(Account?.none)
                ForEach(accounts) { account in
                    Text(account.displayName).tag(Account?.some(account))
                }
            }
            if hasFilters {
                Divider()
                Button("Clear Filters", systemImage: "xmark.circle") {
                    categoryFilter = nil
                    accountFilter = nil
                }
            }
        } label: {
            Label(
                "Filter",
                systemImage: hasFilters
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
    }

    private var hasFilters: Bool {
        categoryFilter != nil || accountFilter != nil
    }

    private var emptyMessage: String {
        if allTransactions.isEmpty {
            return "No transactions yet. Sync to fetch recent activity."
        }
        if showPendingOnly || hasFilters || !searchText.isEmpty {
            return "No transactions match the current filters."
        }
        return "No transactions yet."
    }

    private struct MonthGroup {
        let month: Date
        let transactions: [LedgerTransaction]
    }

    private var grouped: [MonthGroup] {
        let calendar = Calendar.current
        let byMonth = Dictionary(grouping: filtered) { transaction in
            calendar.dateInterval(of: .month, for: transaction.effectiveDate)?.start
                ?? transaction.effectiveDate
        }
        return byMonth
            .map { MonthGroup(month: $0.key, transactions: $0.value.sorted { $0.effectiveDate > $1.effectiveDate }) }
            .sorted { $0.month > $1.month }
    }

    @ViewBuilder
    private func monthHeader(_ group: MonthGroup) -> some View {
        let summary = monthSummary(group.transactions)
        HStack(spacing: 6) {
            Text(group.month, format: .dateTime.month(.wide).year())
            Spacer()
            if summary.spent > 0 {
                Text("Spent")
                    .foregroundStyle(.secondary)
                AmountText(
                    money: Money(
                        minorUnits: -summary.spent,
                        currency: group.transactions.first?.account?.currency ?? .usd
                    ),
                    font: .caption.weight(.semibold),
                    colorOverride: CairnTheme.negative
                )
            }
        }
    }

    private func monthSummary(_ transactions: [LedgerTransaction]) -> (spent: Int64, received: Int64) {
        var spent: Int64 = 0
        var received: Int64 = 0
        for transaction in transactions where !transaction.isTransfer && !transaction.isIgnored {
            if transaction.amountMinorUnits < 0 {
                spent += abs(transaction.amountMinorUnits)
            } else {
                received += transaction.amountMinorUnits
            }
        }
        return (spent, received)
    }

    private var filtered: [LedgerTransaction] {
        var result = allTransactions
        if showPendingOnly {
            result = result.filter(\.isPending)
        }
        if let categoryFilter {
            result = result.filter { $0.effectiveCategory?.persistentModelID == categoryFilter.persistentModelID }
        }
        if let accountFilter {
            result = result.filter { $0.account?.persistentModelID == accountFilter.persistentModelID }
        }
        if !searchText.isEmpty {
            result = result.filter { transaction in
                transaction.payeeDescription.localizedStandardContains(searchText)
                    || (transaction.account?.displayName.localizedStandardContains(searchText) ?? false)
                    || (transaction.effectiveCategory?.name.localizedStandardContains(searchText) ?? false)
                    || (transaction.note?.localizedStandardContains(searchText) ?? false)
                    || (transaction.tags ?? []).contains {
                        $0.name.localizedStandardContains(searchText)
                    }
            }
        }
        // Pending transactions have no posted date, so sort by the effective
        // date to keep them at the top instead of the bottom.
        return result.sorted { $0.effectiveDate > $1.effectiveDate }
    }
}
