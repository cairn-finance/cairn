import SwiftUI
import SwiftData
import CairnCore

struct TransactionsView: View {
    @Query(sort: [SortDescriptor(\LedgerTransaction.postedDate, order: .reverse)])
    private var allTransactions: [LedgerTransaction]

    @State private var searchText = ""
    @State private var showPendingOnly = false

    var body: some View {
        List {
            if filtered.isEmpty {
                Section {
                    Text(allTransactions.isEmpty
                         ? "No transactions yet. Sync to fetch recent activity."
                         : "No transactions match your search.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            } else {
                ForEach(filtered) { transaction in
                    NavigationLink {
                        TransactionDetailView(transaction: transaction)
                    } label: {
                        TransactionRow(transaction: transaction)
                    }
                }
            }
        }
        .cairnListStyle()
        .navigationTitle("Transactions")
        .searchable(text: $searchText, prompt: "Search descriptions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showPendingOnly.toggle()
                } label: {
                    Label("Pending", systemImage: showPendingOnly ? "clock.fill" : "clock")
                }
                .tint(showPendingOnly ? Color.accentColor : nil)
            }
        }
    }

    private var filtered: [LedgerTransaction] {
        var result = allTransactions
        if showPendingOnly {
            result = result.filter(\.isPending)
        }
        if !searchText.isEmpty {
            result = result.filter {
                $0.payeeDescription.localizedStandardContains(searchText)
                    || ($0.account?.displayName.localizedStandardContains(searchText) ?? false)
                    || ($0.effectiveCategory?.name.localizedStandardContains(searchText) ?? false)
            }
        }
        // Pending transactions have no posted date, so sort by the effective
        // date to keep them at the top instead of the bottom.
        return result.sorted { $0.effectiveDate > $1.effectiveDate }
    }
}
