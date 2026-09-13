import SwiftUI
import CairnCore

struct AccountRow: View {
    let account: Account

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(CairnTheme.color(hex: "#30B0C7").opacity(0.18))
                Image(systemName: "building.columns.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CairnTheme.color(hex: "#30B0C7"))
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(account.currency.displayLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            AmountText(money: account.balance, font: .body.weight(.semibold))
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 2)
    }
}

struct TransactionRow: View {
    let transaction: LedgerTransaction

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                categoryIcon

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
        .padding(.vertical, 2)
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            if transaction.isPending {
                Text("Pending")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .fixedSize()
            }
            Text(transaction.effectiveDate, format: .dateTime.month(.abbreviated).day().year())
                .font(.caption)
                .foregroundStyle(.secondary)
            if let category = transaction.effectiveCategory {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(category.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if transaction.isTransfer {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("Transfer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var categoryIcon: some View {
        let category = transaction.effectiveCategory
        let hex = category?.colorHex ?? "#8E8E93"
        return ZStack {
            Circle().fill(CairnTheme.color(hex: hex).opacity(0.18))
            Image(systemName: category?.symbolName ?? "circle.dashed")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CairnTheme.color(hex: hex))
        }
        .frame(width: 32, height: 32)
    }
}
