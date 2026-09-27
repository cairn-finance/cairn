import SwiftUI
import SwiftData
import CairnCore

/// A tappable list behind an Insights card: either one category in one
/// month, or everything still waiting for a category.
struct InsightFilteredListView: View {
    enum Scope: Hashable {
        case category(name: String, month: Date)
        case budgetCategory(name: String, month: Date, currencyCode: String, timeZoneIdentifier: String)
        case needingCategory
    }

    @Query(sort: [SortDescriptor(\LedgerTransaction.postedDate, order: .reverse)])
    private var allTransactions: [LedgerTransaction]

    let title: String
    let emptyMessage: LocalizedStringKey
    let currency: Currency
    let scope: Scope

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.l) {
                if filtered.isEmpty {
                    EmptyStateView(systemImage: "checkmark.circle", title: "Nothing here", message: emptyMessage)
                } else {
                    summary
                    TransactionDayList(rows: filtered.map { $0.rowValue() })
                }
            }
            .cairnScreen()
        }
        .cairnCanvas()
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private var summary: some View {
        switch scope {
        case let .category(_, month), let .budgetCategory(_, month, _, _):
            Card {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Spent in \(month.formatted(.dateTime.month(.wide)))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        AmountText(money: Money(minorUnits: totalSpent, currency: currency), font: .cairnDisplay)
                    }
                    Spacer()
                    Text("^[\(filtered.count) transaction](inflect: true)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        case .needingCategory:
            Card {
                HStack(spacing: 12) {
                    SettingsIcon(systemImage: "sparkles", tint: CairnTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("^[\(filtered.count) transaction](inflect: true) to review")
                            .font(.headline)
                        Text("Pick a category and Cairn remembers it for that merchant.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
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
        case let .budgetCategory(name, month, currencyCode, timeZoneIdentifier):
            var calendar = Calendar.current
            if let timeZone = TimeZone(identifier: timeZoneIdentifier) { calendar.timeZone = timeZone }
            let interval = calendar.dateInterval(of: .month, for: month)
            return allTransactions.filter { transaction in
                guard transaction.effectiveCategory?.name == name,
                      transaction.account?.currency.code == currencyCode,
                      !transaction.countsAsTransfer,
                      !transaction.isIgnored,
                      !transaction.isPending,
                      let interval else { return false }
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
        switch scope {
        case .budgetCategory:
            return filtered.filter { !$0.countsAsTransfer && !$0.isIgnored && !$0.isPending }
                .reduce(Int64(0)) { total, transaction in
                    let delta = transaction.amountMinorUnits < 0
                        ? MinorUnits.absClamped(transaction.amountMinorUnits)
                        : -transaction.amountMinorUnits
                    return MinorUnits.addClamped(total, delta)
                }
        case .category, .needingCategory:
            return filtered
                .filter { $0.amountMinorUnits < 0 && !$0.countsAsTransfer }
                .reduce(Int64(0)) { MinorUnits.addClamped($0, MinorUnits.absClamped($1.amountMinorUnits)) }
        }
    }
}
