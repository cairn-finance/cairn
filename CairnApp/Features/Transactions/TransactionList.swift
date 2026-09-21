import SwiftUI
import SwiftData
import CairnCore

/// Transactions grouped by day, newest first, each day as one card. Shared by
/// Activity, account detail, and the Insights drill-downs so every list of
/// transactions in the app reads the same way.
///
/// The list draws from precomputed ``TransactionMonthSection`` values: the
/// grouping and totals are done once, and each element is keyed by the row's
/// stable composite id and emits exactly one view (divider included), so
/// SwiftUI never has to build views to gather identities.
struct TransactionDayList: View {
    let sections: [TransactionMonthSection]
    var showsAccount: Bool = true
    /// Pin a month banner above the days that belong to it.
    var showsMonthHeaders: Bool = false
    /// Called when the final row appears, so a windowed list can load more.
    var onReachEnd: (() -> Void)?
    /// Offered on each row's context menu when set. Used for manual editing;
    /// synced lists leave these nil so their rows stay read-only.
    var onEdit: ((TransactionRowValue) -> Void)?
    var onDelete: ((TransactionRowValue) -> Void)?

    init(
        sections: [TransactionMonthSection],
        showsAccount: Bool = true,
        showsMonthHeaders: Bool = false,
        onReachEnd: (() -> Void)? = nil,
        onEdit: ((TransactionRowValue) -> Void)? = nil,
        onDelete: ((TransactionRowValue) -> Void)? = nil
    ) {
        self.sections = sections
        self.showsAccount = showsAccount
        self.showsMonthHeaders = showsMonthHeaders
        self.onReachEnd = onReachEnd
        self.onEdit = onEdit
        self.onDelete = onDelete
    }

    init(
        rows: [TransactionRowValue],
        showsAccount: Bool = true,
        showsMonthHeaders: Bool = false,
        onReachEnd: (() -> Void)? = nil,
        onEdit: ((TransactionRowValue) -> Void)? = nil,
        onDelete: ((TransactionRowValue) -> Void)? = nil
    ) {
        self.init(
            sections: TransactionSectionBuilder.months(from: rows),
            showsAccount: showsAccount,
            showsMonthHeaders: showsMonthHeaders,
            onReachEnd: onReachEnd,
            onEdit: onEdit,
            onDelete: onDelete
        )
    }

    var body: some View {
        LazyVStack(
            alignment: .leading,
            spacing: CairnTheme.Spacing.l,
            pinnedViews: showsMonthHeaders ? [.sectionHeaders] : []
        ) {
            ForEach(sections) { month in
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

    private func dayCard(_ day: TransactionDaySection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: day.day.cairnDayLabel, trailing: dayTotal(day))
            RowGroup {
                ForEach(day.rows) { row in
                    TransactionRowEntry(
                        row: row,
                        showsAccount: showsAccount,
                        showsDivider: row.id != day.rows.last?.id,
                        isLastOverall: row.id == lastRowID,
                        onEdit: onEdit,
                        onDelete: onDelete,
                        onReachEnd: onReachEnd
                    )
                }
            }
        }
    }

    private var lastRowID: String? {
        sections.last?.days.last?.rows.last?.id
    }

    private func monthHeader(_ month: TransactionMonthSection) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(month.month, format: .dateTime.month(.wide).year())
                .font(.title3.weight(.semibold))
            Spacer()
            if month.spentMinorUnits > 0 {
                HStack(spacing: 4) {
                    Text("Spent")
                        .foregroundStyle(.secondary)
                    AmountText(
                        money: Money(minorUnits: month.spentMinorUnits, currency: month.currency),
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

    private func dayTotal(_ day: TransactionDaySection) -> String? {
        guard day.spentMinorUnits > 0 else { return nil }
        return Money(minorUnits: day.spentMinorUnits, currency: day.currency).formatted()
    }
}

/// One row plus its divider, emitted as a single view so `ForEach` never has to
/// build two elements (and so the last-row observation has one home).
private struct TransactionRowEntry: View {
    let row: TransactionRowValue
    let showsAccount: Bool
    let showsDivider: Bool
    let isLastOverall: Bool
    let onEdit: ((TransactionRowValue) -> Void)?
    let onDelete: ((TransactionRowValue) -> Void)?
    let onReachEnd: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            NavigationLink {
                TransactionDetailLoader(persistentID: row.persistentID)
            } label: {
                TransactionValueRow(row: row, showsAccount: showsAccount)
            }
            .buttonStyle(.plain)
            .modifier(TransactionValueContextMenu(row: row, onEdit: onEdit, onDelete: onDelete))

            if showsDivider {
                RowDivider(leadingInset: 66)
            }
        }
        .onAppear {
            if isLastOverall { onReachEnd?() }
        }
    }
}

/// Loads a transaction's model only when its detail screen is pushed, so the
/// list can carry value snapshots without holding every model.
struct TransactionDetailLoader: View {
    @Environment(\.modelContext) private var modelContext

    let persistentID: PersistentIdentifier?

    var body: some View {
        if let persistentID, let model = modelContext.model(for: persistentID) as? LedgerTransaction {
            TransactionDetailView(transaction: model)
        } else {
            ContentUnavailableView(
                "Transaction unavailable",
                systemImage: "questionmark.circle",
                description: Text("It may have been removed.")
            )
        }
    }
}

/// Attaches an edit/delete context menu only when the list is editable, so
/// read-only (synced) rows never show an empty menu.
private struct TransactionValueContextMenu: ViewModifier {
    let row: TransactionRowValue
    let onEdit: ((TransactionRowValue) -> Void)?
    let onDelete: ((TransactionRowValue) -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if onEdit != nil || onDelete != nil {
            content.contextMenu {
                if let onEdit {
                    Button("Edit…", systemImage: "pencil") { onEdit(row) }
                }
                if let onDelete {
                    Button("Delete…", systemImage: "trash", role: .destructive) { onDelete(row) }
                }
            }
        } else {
            content
        }
    }
}
