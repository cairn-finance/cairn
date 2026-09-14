import SwiftUI
import CairnCore

struct AccountRow: View {
    let account: Account

    var body: some View {
        HStack(spacing: CairnTheme.Spacing.m) {
            CategoryBadge(symbolName: "building.columns.fill", hex: "#1F93AC", size: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(account.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(account.isManual ? "Manual" : account.currency.displayLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            AmountText(
                money: account.balance,
                font: .body.weight(.semibold),
                colorOverride: account.balance.isNegative ? CairnTheme.negative : nil
            )
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 2)
    }
}

struct TransactionRow: View {
    let transaction: LedgerTransaction

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: CairnTheme.Spacing.m) {
                CategoryBadge(
                    symbolName: transaction.effectiveCategory?.symbolName,
                    hex: transaction.effectiveCategory?.colorHex,
                    size: 32
                )

                Text(transaction.payeeDescription.isEmpty ? "No description" : transaction.payeeDescription)
                    .font(.body)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                AmountText(money: transaction.amount, showSign: true, font: .body.weight(.medium))
                    .fixedSize(horizontal: true, vertical: false)
            }

            metadata
                .padding(.leading, 44)
        }
        .padding(.vertical, 3)
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            if transaction.isPending {
                Text("Pending")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .fixedSize()
            }
            Text(transaction.effectiveDate, format: .dateTime.month(.abbreviated).day().year())
                .font(.caption)
                .foregroundStyle(.secondary)
            if let label = categoryLabel {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The category, or "Transfer" when the row is money movement and has no
    /// category of its own.
    private var categoryLabel: String? {
        if let category = transaction.effectiveCategory {
            return category.name
        }
        return transaction.isTransfer ? "Transfer" : nil
    }
}
