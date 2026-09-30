import SwiftUI
import SwiftData
import CairnCore

/// All transactions for one normalized merchant, with currency-separated spend
/// totals for the current week, month, and year.
struct MerchantDetailView: View {
    @Environment(AppModel.self) private var model

    let merchantKey: String
    let merchantName: String

    @State private var feed: TransactionsFeed?
    @State private var summary: MerchantSpendSummary?
    @State private var summaryFailed = false

    private var transactionFilter: TransactionFilter {
        TransactionFilter(merchantKey: merchantKey)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.l) {
                spendingSummary
                ScreenSectionHeader(
                    "Transactions",
                    subtitle: "All transactions at \(merchantName)."
                )
                if let feed {
                    if feed.rows.isEmpty {
                        EmptyStateView(
                            systemImage: "storefront",
                            title: "No merchant transactions",
                            message: "Transactions for this merchant will appear here."
                        )
                    } else {
                        TransactionDayList(
                            sections: feed.sections,
                            showsMonthHeaders: true,
                            showsSpendingTotals: false,
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
        .cairnScrollEdge()
        .cairnCanvas()
        .navigationTitle(merchantName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: transactionFilter.namespace) {
            if let feed {
                feed.filter = transactionFilter
            } else {
                feed = TransactionsFeed(container: model.container, filter: transactionFilter)
            }
            await reloadSummary()
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: ModelContext.didSave) {
                guard !Task.isCancelled else { return }
                await reloadSummary()
            }
        }
        .refreshable {
            feed?.reload()
            await reloadSummary()
        }
    }

    private var spendingSummary: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader("Total spent", subtitle: "Totals are grouped by currency.")
                if summaryFailed {
                    Text("Spending totals are unavailable. Pull to retry.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let summary {
                    MerchantSpendPeriodRow(title: "This week", amounts: summary.week)
                    RowDivider()
                    MerchantSpendPeriodRow(title: "This month", amounts: summary.month)
                    RowDivider()
                    MerchantSpendPeriodRow(title: "This year", amounts: summary.year)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func reloadSummary() async {
        summaryFailed = false
        let container = model.container
        let fetcher = await Task.detached(priority: .utility) {
            MerchantSpendFetcher(modelContainer: container)
        }.value
        do {
            let result = try await fetcher.summary(for: merchantKey)
            guard !Task.isCancelled else { return }
            summary = result
        } catch {
            guard !Task.isCancelled else { return }
            summary = nil
            summaryFailed = true
        }
    }
}

private struct MerchantSpendPeriodRow: View {
    let title: LocalizedStringKey
    let amounts: [FinancialWidgetAmount]

    var body: some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 12)
            if amounts.isEmpty {
                Text("No spending")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(amounts) { amount in
                        HStack(spacing: 8) {
                            Text(amount.currency.displayLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            AmountText(
                                money: Money(minorUnits: amount.amountMinorUnits, currency: amount.currency),
                                font: .footnote.weight(.semibold)
                            )
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
