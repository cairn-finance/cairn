import Foundation
import SwiftUI
import CairnCore

/// Shows the transactions behind one budget category without materializing the
/// whole ledger in a SwiftUI query. The bounded feed also keeps a category tap
/// from rebuilding a large graph of SwiftData relationships on the main actor.
struct BudgetCategoryTransactionsView: View {
    @Environment(AppModel.self) private var model

    let categoryName: String
    let currency: Currency
    let month: Date
    let timeZoneIdentifier: String

    @State private var feed: TransactionsFeed?

    private var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? .current
    }

    private var monthInterval: DateInterval? {
        guard let start = BudgetCalculator.startOfMonth(
            BudgetCalculator.monthKey(for: month, timeZone: timeZone),
            timeZone: timeZone
        ) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
        return DateInterval(start: start, end: end)
    }

    private var transactionFilter: TransactionFilter {
        TransactionFilter(
            categoryName: categoryName,
            currencyIdentifier: currency.stableIdentifier,
            startDate: monthInterval?.start,
            endDate: monthInterval?.end
        )
    }

    private var monthLabel: String {
        monthInterval?.start.formatted(.dateTime.month(.wide).year())
            ?? month.formatted(.dateTime.month(.wide).year())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.l) {
                if let feed {
                    if feed.rows.isEmpty {
                        EmptyStateView(
                            systemImage: "checkmark.circle",
                            title: "Nothing here",
                            message: "No transactions in this category for this month."
                        )
                    } else {
                        ScreenSectionHeader(
                            "Transactions",
                            subtitle: "Transactions in \(monthLabel)."
                        )
                        TransactionDayList(
                            sections: feed.sections,
                            onReachEnd: { feed.loadMore() }
                        )
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
            }
            .cairnScreen()
        }
        .cairnCanvas()
        .navigationTitle(categoryName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: transactionFilter.namespace) {
            guard feed == nil else { return }
            feed = TransactionsFeed(container: model.container, filter: transactionFilter)
        }
    }
}
