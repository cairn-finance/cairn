import SwiftUI
import SwiftData
import CairnCore

/// A focused queue for transactions that have not been fully reviewed.
struct ReviewInboxView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LedgerTransaction.modifiedAt, order: .reverse)
    private var transactions: [LedgerTransaction]

    @State private var undo: (PersistentIdentifier, Date?)?

    private var items: [ReviewInboxItem] {
        ReviewInboxItem.items(from: transactions.map { $0.rowValue() })
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CairnTheme.Spacing.l) {
                if items.isEmpty {
                    EmptyStateView(
                        systemImage: "checkmark.circle",
                        title: "Inbox clear",
                        message: "New, uncategorized, or changed transactions will appear here."
                    )
                } else {
                    Text("Review each item, assign a category when needed, then mark it reviewed.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ForEach(items) { item in
                        itemCard(item)
                    }
                }
            }
            .cairnScreen(maxWidth: 720)
            .padding(.bottom, CairnTheme.Spacing.xl)
        }
        .cairnScrollEdge()
        .cairnCanvas()
        .navigationTitle("Review Inbox")
        .toolbar {
            if !items.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Mark All Reviewed", systemImage: "checkmark.circle") {
                        markAllReviewed()
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if undo != nil {
                Button("Undo", systemImage: "arrow.uturn.backward") { undoLast() }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 20)
            }
        }
    }

    private func itemCard(_ item: ReviewInboxItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationLink {
                TransactionDetailLoader(persistentID: item.row.persistentID)
            } label: {
                TransactionValueRow(row: item.row, showsAccount: true)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                ForEach(item.reasons, id: \.self) { reason in
                    Label(reason.title, systemImage: reason.systemImage)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(reason == .uncategorized ? CairnTheme.warning : .secondary)
                }
                Spacer()
                Button("Reviewed", systemImage: "checkmark") {
                    markReviewed(item)
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
            }
            .padding(14)
        }
        .background(CairnTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(CairnTheme.outline))
    }

    private func markReviewed(_ item: ReviewInboxItem) {
        guard let id = item.row.persistentID,
              let transaction = modelContext.model(for: id) as? LedgerTransaction else { return }
        undo = (id, transaction.reviewedAt)
        let now = Date.now
        transaction.reviewedAt = now
        transaction.modifiedAt = now
        try? modelContext.save()
    }

    private func markAllReviewed() {
        for item in items {
            guard let id = item.row.persistentID,
                  let transaction = modelContext.model(for: id) as? LedgerTransaction else { continue }
            let now = Date.now
            transaction.reviewedAt = now
            transaction.modifiedAt = now
        }
        try? modelContext.save()
    }

    private func undoLast() {
        guard let undo,
              let transaction = modelContext.model(for: undo.0) as? LedgerTransaction else { return }
        transaction.reviewedAt = undo.1
        transaction.modifiedAt = .now
        try? modelContext.save()
        self.undo = nil
    }
}
