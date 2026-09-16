import SwiftUI
import CairnCore

/// Transactions grouped by day, newest first, each day as one card. Shared by
/// Activity, account detail, and the Insights drill-downs so every list of
/// transactions in the app reads the same way.
struct TransactionDayList: View {
    let transactions: [LedgerTransaction]
    var showsAccount: Bool = true
    /// Pin a month banner above the days that belong to it.
    var showsMonthHeaders: Bool = false

    private struct DayGroup: Identifiable {
        let day: Date
        let transactions: [LedgerTransaction]
        var id: Date { day }
    }

    private struct MonthGroup: Identifiable {
        let month: Date
        let days: [DayGroup]
        var id: Date { month }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: CairnTheme.Spacing.l, pinnedViews: showsMonthHeaders ? [.sectionHeaders] : []) {
            ForEach(months) { month in
                Section {
                    ForEach(month.days) { day in
                        dayCard(day)
                    }
                } header: {
                    if showsMonthHeaders {
                        monthHeader(month)
                    }
                }
            }
        }
    }

    private func dayCard(_ group: DayGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: group.day.cairnDayLabel, trailing: dayTotal(group))
            RowGroup {
                ForEach(Array(group.transactions.enumerated()), id: \.element.persistentModelID) { index, transaction in
                    NavigationLink {
                        TransactionDetailView(transaction: transaction)
                    } label: {
                        TransactionRow(transaction: transaction, showsAccount: showsAccount)
                    }
                    .buttonStyle(.plain)
                    if index < group.transactions.count - 1 {
                        RowDivider(leadingInset: 66)
                    }
                }
            }
        }
    }

    private func monthHeader(_ group: MonthGroup) -> some View {
        let summary = monthSummary(group)
        let currency = group.days.first?.transactions.first?.account?.currency ?? .usd
        return HStack(alignment: .firstTextBaseline) {
            Text(group.month, format: .dateTime.month(.wide).year())
                .font(.title3.weight(.semibold))
            Spacer()
            if summary.spent > 0 {
                HStack(spacing: 4) {
                    Text("Spent")
                        .foregroundStyle(.secondary)
                    AmountText(
                        money: Money(minorUnits: summary.spent, currency: currency),
                        font: .footnote.weight(.semibold)
                    )
                }
                .font(.footnote)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(CairnTheme.canvas.opacity(0.96))
    }

    private func dayTotal(_ group: DayGroup) -> String? {
        let currency = group.transactions.first?.account?.currency ?? .usd
        let spent = group.transactions
            .filter { $0.amountMinorUnits < 0 && !$0.countsAsTransfer && !$0.isIgnored }
            .reduce(Int64(0)) { MinorUnits.addClamped($0, MinorUnits.absClamped($1.amountMinorUnits)) }
        guard spent > 0 else { return nil }
        return Money(minorUnits: spent, currency: currency).formatted()
    }

    private func monthSummary(_ group: MonthGroup) -> (spent: Int64, received: Int64) {
        var spent: Int64 = 0
        var received: Int64 = 0
        for transaction in group.days.flatMap(\.transactions) where !transaction.countsAsTransfer && !transaction.isIgnored {
            if transaction.amountMinorUnits < 0 {
                spent += abs(transaction.amountMinorUnits)
            } else {
                received += transaction.amountMinorUnits
            }
        }
        return (spent, received)
    }

    private var months: [MonthGroup] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: transactions) { calendar.startOfDay(for: $0.effectiveDate) }
        let days = byDay
            .map { DayGroup(day: $0.key, transactions: $0.value.sorted { $0.effectiveDate > $1.effectiveDate }) }
            .sorted { $0.day > $1.day }
        let byMonth = Dictionary(grouping: days) {
            calendar.dateInterval(of: .month, for: $0.day)?.start ?? $0.day
        }
        return byMonth
            .map { MonthGroup(month: $0.key, days: $0.value.sorted { $0.day > $1.day }) }
            .sorted { $0.month > $1.month }
    }
}
