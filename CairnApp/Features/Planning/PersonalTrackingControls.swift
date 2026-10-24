import SwiftUI
import SwiftData
import CairnCore

extension View {
    /// Phone editors need a fixed navigation header while the keyboard resizes the form.
    func trackingEditor<Editor: View>(
        isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Editor
    ) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented, content: content)
        #endif
    }

    func trackingEditor<Item: Identifiable, Editor: View>(
        item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Editor
    ) -> some View {
        #if os(iOS)
        fullScreenCover(item: item, content: content)
        #else
        sheet(item: item, content: content)
        #endif
    }
}

struct TrackingAmountField: View {
    let title: LocalizedStringKey
    @Binding var text: String

    init(_ title: LocalizedStringKey, text: Binding<String>) {
        self.title = title
        _text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CairnTheme.Spacing.s) {
            Text(title).font(.subheadline.weight(.semibold))
            TextField("0.00", text: $text)
                .font(.title3.weight(.semibold).monospacedDigit())
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(title)
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
        }
    }
}

/// Uses the same card anatomy as Cairn's category-budget editor.
struct TrackingFormSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.m) {
                Text(title).font(.headline)
                content
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}

struct TrackingSymbol: View {
    let name: String
    var size: CGFloat = 42

    var body: some View {
        Image(systemName: name)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(CairnTheme.accent)
            .frame(width: size, height: size)
            .background(CairnTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: CairnTheme.tileRadius))
            .accessibilityHidden(true)
    }
}

struct TrackingDetailRow: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: CairnTheme.Spacing.m) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: CairnTheme.Spacing.s)
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

struct TrackingCurrencyPicker: View {
    @Query private var accounts: [Account]
    @Binding var currency: Currency
    @State private var enteringCode = false

    private var currencies: [Currency] {
        var seen = Set<Currency>()
        return (accounts.map(\.currency) + [currency] + ["USD", "EUR", "GBP", "CAD", "AUD", "INR", "JPY"].map {
            Currency.simpleFIN($0)
        }).filter { seen.insert($0).inserted }.sorted { $0.stableIdentifier < $1.stableIdentifier }
    }

    var body: some View {
        Picker("Currency", selection: Binding(
            get: { enteringCode ? "other" : currency.stableIdentifier },
            set: { selection in
                enteringCode = selection == "other"
                if let selected = currencies.first(where: { $0.stableIdentifier == selection }) { currency = selected }
            }
        )) {
            ForEach(currencies, id: \.self) { value in
                Text(value.displayLabel).tag(value.stableIdentifier)
            }
            Text("Other currency").tag("other")
        }
        if enteringCode {
            TextField("Currency code", text: Binding(
                get: { currency.code },
                set: {
                    let code = $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                    currency = Currency(code: code, exponent: Currency.defaultExponent(forISOCode: code))
                }
            ))
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.characters)
            #endif
        }
    }
}

/// Exact matches are bounded before display; the write path revalidates the
/// selected reference. Attaching evidence never edits bank-owned fields.
struct TrackingBankPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var transactions: [LedgerTransaction]
    @Query private var expenses: [SharedExpense]
    @Query private var payments: [SharedExpensePayment]
    let currency: Currency
    let excludingID: UUID
    let onSelect: (TrackingBankLink) -> Void

    init(currency: Currency, amount: Int64, excludingID: UUID, onSelect: @escaping (TrackingBankLink) -> Void) {
        self.currency = currency
        self.excludingID = excludingID
        self.onSelect = onSelect
        var descriptor = FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.amountMinorUnits == amount && !$0.isPending },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 100
        _transactions = Query(descriptor)
    }

    private var candidates: [LedgerTransaction] {
        let used = Set(expenses.filter { $0.uuid != excludingID }.compactMap { try? $0.input.bankLink }
            + payments.filter { $0.uuid != excludingID }.compactMap { try? $0.input.bankLink })
        return transactions.filter {
            $0.account != nil && $0.amount.currency == currency
                && !used.contains(TrackingBankLink(accountIDIndex: $0.accountIDIndex, bankTransactionID: $0.bankTransactionID))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CairnTheme.Spacing.l) {
                    ScreenSectionHeader("Matching transactions")
                    if candidates.isEmpty {
                        EmptyStateView(
                            systemImage: "link", title: "No matching transactions",
                            message: "You can save without an attachment."
                        )
                    } else {
                        RowGroup {
                            ForEach(candidates) { transaction in
                                Button {
                                    onSelect(TrackingBankLink(
                                        accountIDIndex: transaction.accountIDIndex,
                                        bankTransactionID: transaction.bankTransactionID
                                    ))
                                    dismiss()
                                } label: { TransactionRow(transaction: transaction) }
                                .buttonStyle(.plain)
                                if transaction.id != candidates.last?.id { RowDivider() }
                            }
                        }
                    }
                    FootnoteText("Shows up to 100 recent transactions matching the amount and direction.")
                }
                .cairnScreen(maxWidth: 560)
            }
            .cairnCanvas()
            .navigationTitle("Attach transaction")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 540)
        #endif
    }
}

struct TrackingBankReference: View {
    @Query private var transactions: [LedgerTransaction]

    init(link: TrackingBankLink) {
        let accountID = link.accountIDIndex
        let transactionID = link.bankTransactionID
        var descriptor = FetchDescriptor<LedgerTransaction>(predicate: #Predicate {
            $0.accountIDIndex == accountID && $0.bankTransactionID == transactionID
        })
        descriptor.fetchLimit = 1
        _transactions = Query(descriptor)
    }

    var body: some View {
        if let transaction = transactions.first {
            NavigationLink {
                TransactionDetailView(transaction: transaction)
            } label: {
                Label(transaction.displayDescription, systemImage: "link")
            }
        } else {
            Label("Attached transaction is no longer available", systemImage: "link.badge.plus")
                .foregroundStyle(.secondary)
        }
    }
}

struct PersonalTrackingEntryPoints: View {
    @Query private var expenses: [SharedExpense]
    @Query private var payments: [SharedExpensePayment]
    @Query private var funds: [SinkingFund]
    @Query private var entries: [SinkingFundEntry]
    @State private var availableWidth: CGFloat = 0

    private var layout: AnyLayout {
        let spacing = CairnTheme.Spacing.l
        if availableWidth >= 680 + spacing {
            return AnyLayout(HStackLayout(alignment: .top, spacing: spacing))
        }
        return AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
    }

    var body: some View {
        // Both navigation actions stay in the accessibility tree while Home scrolls.
        layout {
            NavigationLink { SharedExpensesView() } label: {
                Card {
                    HStack(spacing: CairnTheme.Spacing.m) {
                        TrackingSymbol(name: "person.2")
                        VStack(alignment: .leading, spacing: CairnTheme.Spacing.xs) {
                            Text("Shared expenses").font(.headline)
                            if sharedCurrencies.isEmpty {
                                Text("Keep track of who owes what").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(sharedCurrencies, id: \.self) { currency in
                                Text(sharedSummary(currency)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.pressableCard)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Shared expenses")
            .accessibilityValue(sharedCurrencies.map { sharedSummary($0) }.joined(separator: "; "))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("sharedExpensesEntry")
            NavigationLink { SinkingFundsView() } label: {
                Card {
                    HStack(spacing: CairnTheme.Spacing.m) {
                        TrackingSymbol(name: "tray.and.arrow.down")
                        VStack(alignment: .leading, spacing: CairnTheme.Spacing.xs) {
                            Text("Sinking funds").font(.headline)
                            if fundCurrencies.isEmpty {
                                Text("Set money aside for what's ahead").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(fundCurrencies, id: \.self) { currency in
                                Text(fundSummary(currency)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.pressableCard)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Sinking funds")
            .accessibilityValue(fundCurrencies.map { fundSummary($0) }.joined(separator: "; "))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("sinkingFundsEntry")
        }
        .accessibilityElement(children: .contain)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
    }

    private var sharedCurrencies: [Currency] {
        Set(expenses.filter { !$0.isArchived }.compactMap { try? $0.input.currency })
            .sorted { $0.stableIdentifier < $1.stableIdentifier }
    }

    private var fundCurrencies: [Currency] {
        Set(funds.filter { $0.stateRaw != "archived" }.compactMap { try? $0.input.currency })
            .sorted { $0.stableIdentifier < $1.stableIdentifier }
    }

    private func sharedSummary(_ currency: Currency) -> String {
        var owed: Int64 = 0
        var owe: Int64 = 0
        for expense in expenses where !expense.isArchived {
            guard let input = try? expense.input, input.currency == currency else { continue }
            guard let history = try? payments.filter({ $0.expenseID == input.uuid }).map({ try $0.input }),
                  let balances = try? SharedExpenseCalculator.balances(for: input, payments: history) else {
                return String(localized: "Shared expense totals unavailable")
            }
            for balance in balances {
                if balance.owedToMe { owed = MinorUnits.addClamped(owed, balance.outstandingMinorUnits) }
                else { owe = MinorUnits.addClamped(owe, balance.outstandingMinorUnits) }
            }
        }
        let received = Money(minorUnits: owed, currency: currency).formatted()
        let payable = Money(minorUnits: owe, currency: currency).formatted()
        return String(localized: "Owed to you: \(received) · You owe: \(payable)")
    }

    private func fundSummary(_ currency: Currency) -> String {
        var funded: Int64 = 0
        for fund in funds where fund.stateRaw != "archived" {
            guard let input = try? fund.input, input.currency == currency else { continue }
            guard let history = try? entries.filter({ $0.fundID == input.uuid }).map({ try $0.input }),
                  let summary = try? SinkingFundCalculator.summary(for: input, entries: history) else {
                return String(localized: "Fund totals unavailable")
            }
            funded = MinorUnits.addClamped(funded, summary.fundedMinorUnits)
        }
        let amount = Money(minorUnits: funded, currency: currency).formatted()
        return String(localized: "Allocated: \(amount)")
    }
}
