import SwiftUI
import SwiftData
import CairnCore

/// A simple, tappable list behind an Insights card: either one category in one
/// month, or everything still waiting for a category.
struct InsightFilteredListView: View {
    enum Scope: Hashable {
        case category(name: String, month: Date)
        case needingCategory
    }

    @Query(sort: [SortDescriptor(\LedgerTransaction.postedDate, order: .reverse)])
    private var allTransactions: [LedgerTransaction]

    let title: String
    let emptyMessage: String
    let currency: Currency
    let scope: Scope

    var body: some View {
        List {
            if filtered.isEmpty {
                Section {
                    Text(emptyMessage)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            } else {
                Section {
                    ForEach(filtered) { transaction in
                        NavigationLink {
                            TransactionDetailView(transaction: transaction)
                        } label: {
                            TransactionRow(transaction: transaction)
                        }
                    }
                } header: {
                    header
                }
            }
        }
        .cairnListStyle()
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private var header: some View {
        switch scope {
        case .category:
            HStack {
                Text("Total")
                Spacer()
                AmountText(
                    money: Money(minorUnits: -totalSpent, currency: currency),
                    font: .caption.weight(.semibold),
                    colorOverride: CairnTheme.negative
                )
            }
        case .needingCategory:
            Text("\(filtered.count) transaction\(filtered.count == 1 ? "" : "s")")
        }
    }

    private var filtered: [LedgerTransaction] {
        switch scope {
        case let .category(name, month):
            let interval = Calendar.current.dateInterval(of: .month, for: month)
            return allTransactions.filter { transaction in
                let categoryName = transaction.effectiveCategory?.name
                    ?? InsightsCalculator.uncategorizedName
                guard categoryName == name else { return false }
                guard let interval else { return true }
                return interval.contains(transaction.effectiveDate)
            }
        case .needingCategory:
            return allTransactions.filter { transaction in
                transaction.userCategory == nil
                    && transaction.autoCategory == nil
                    && !transaction.isIgnored
                    && !transaction.countsAsTransfer
                    && !transaction.isPending
            }
        }
    }

    private var totalSpent: Int64 {
        filtered
            .filter { $0.amountMinorUnits < 0 && !$0.countsAsTransfer }
            .reduce(Int64(0)) { $0 + abs($1.amountMinorUnits) }
    }
}
