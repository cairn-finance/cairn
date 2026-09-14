import SwiftUI
import CairnCore

/// One account inside an institution card.
struct AccountRow: View {
    let account: Account
    var showsChevron: Bool = true

    var body: some View {
        HStack(spacing: CairnTheme.Spacing.m) {
            AccountGlyph(account: account, size: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
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

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
    }

    /// "Checking", "Manual · Cash", or the currency when the type is unknown,
    /// so the line under the name always says something useful.
    private var subtitle: String {
        var parts: [String] = []
        if account.isManual { parts.append("Manual") }
        if account.accountType != .other { parts.append(account.accountType.displayName) }
        if account.accountType == .other || account.currency.code != "USD" || account.currency.isCustom {
            parts.append(account.currency.displayLabel)
        }
        return parts.joined(separator: " · ")
    }
}

/// One transaction in any list. The merchant leads; category and account sit
/// underneath in a quiet line; the amount is neutral for spending and green
/// for money in, so income is visible without the list turning into a
/// rainbow.
struct TransactionRow: View {
    let transaction: LedgerTransaction
    /// Show the account name under the merchant (hide inside account detail).
    var showsAccount: Bool = true
    var showsChevron: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: CairnTheme.Spacing.m) {
            CategoryBadge(
                symbolName: transaction.countsAsTransfer && transaction.effectiveCategory == nil
                    ? "arrow.left.arrow.right"
                    : transaction.effectiveCategory?.symbolName,
                hex: transaction.effectiveCategory?.colorHex ?? (transaction.countsAsTransfer ? "#32ADE6" : nil),
                size: 40
            )
            .opacity(transaction.isIgnored ? 0.5 : 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.payeeDescription.isEmpty ? "No description" : transaction.payeeDescription)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .strikethrough(transaction.isIgnored, color: .secondary)
                    .foregroundStyle(transaction.isIgnored ? .secondary : .primary)

                HStack(spacing: 5) {
                    if transaction.isPending {
                        StatusPill(text: "Pending", systemImage: "clock", tint: CairnTheme.warning)
                    }
                    if let label = categoryLabel {
                        Text(label)
                    }
                    if showsAccount, let accountName = transaction.account?.displayName {
                        if categoryLabel != nil {
                            Text("·").foregroundStyle(.tertiary)
                        }
                        Text(accountName)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            AmountText(
                money: transaction.amount,
                showSign: true,
                font: .body.weight(.semibold),
                colorOverride: amountColor
            )
            .fixedSize(horizontal: true, vertical: false)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
    }

    private var amountColor: Color? {
        if transaction.isIgnored { return .secondary }
        if transaction.countsAsTransfer { return .secondary }
        return transaction.amount.isNegative ? nil : CairnTheme.positive
    }

    /// The category, or "Transfer" when the row is money movement and has no
    /// category of its own.
    private var categoryLabel: String? {
        if let category = transaction.effectiveCategory {
            return category.name
        }
        return transaction.countsAsTransfer ? "Transfer" : "Uncategorized"
    }
}

/// A vertical stack of rows inside a card, separated by hairlines that stop
/// short of the leading glyph, like a well-set table.
struct RowGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .cardSurface()
    }
}

/// A hairline that lines up with row text rather than the glyph.
struct RowDivider: View {
    var leadingInset: CGFloat = 68

    var body: some View {
        Rectangle()
            .fill(CairnTheme.hairline)
            .frame(height: 1)
            .padding(.leading, leadingInset)
    }
}
