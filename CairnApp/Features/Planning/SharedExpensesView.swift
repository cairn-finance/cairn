import SwiftUI
import SwiftData
import CairnCore

struct SharedExpensesView: View {
    @Query(sort: \SharedExpense.date, order: .reverse) private var expenses: [SharedExpense]
    @Query private var payments: [SharedExpensePayment]
    @Query(filter: #Predicate<LedgerTransaction> { $0.settlementID != nil && $0.settlementRoleRaw == "expense" })
    private var linkedExpenses: [LedgerTransaction]
    @State private var showingAdd = false
    @State private var showsArchived = false

    private var visibleExpenses: [SharedExpense] { expenses.filter { showsArchived || !$0.isArchived } }
    private var currencies: [Currency] {
        Set(expenses.filter { !$0.isArchived }.compactMap { try? $0.input.currency })
            .sorted { $0.stableIdentifier < $1.stableIdentifier }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.xl) {
                if expenses.isEmpty && linkedExpenses.isEmpty {
                    EmptyStateView(
                        systemImage: "person.2", title: "Share the cost. Keep the record.",
                        message: "Add a shared expense, choose the split, and record repayments as they happen.",
                        actionTitle: "Add shared expense"
                    ) { showingAdd = true }
                } else {
                    ForEach(currencies, id: \.self) { currency in summaryCard(currency) }
                    if expenses.contains(where: { (try? $0.input) == nil }) {
                        FootnoteText("Some records could not be read. Totals may be incomplete.")
                    }
                    if !visibleExpenses.isEmpty {
                        VStack(alignment: .leading, spacing: CairnTheme.Spacing.s) {
                            ScreenSectionHeader("Expenses")
                            RowGroup {
                                ForEach(visibleExpenses) { expense in
                                    NavigationLink { SharedExpenseDetail(expenseID: expense.uuid) } label: {
                                        expenseRow(expense)
                                    }
                                    .buttonStyle(.plain)
                                    if expense.uuid != visibleExpenses.last?.uuid { RowDivider() }
                                }
                            }
                        }
                    }
                    if !linkedExpenses.isEmpty {
                        VStack(alignment: .leading, spacing: CairnTheme.Spacing.s) {
                            SectionLabel(title: "Bank-linked reimbursements")
                            RowGroup {
                                ForEach(linkedExpenses) { transaction in
                                    NavigationLink { TransactionDetailView(transaction: transaction) } label: {
                                        TransactionRow(transaction: transaction, showsChevron: true)
                                    }
                                    .buttonStyle(.plain)
                                    if transaction.id != linkedExpenses.last?.id { RowDivider() }
                                }
                            }
                        }
                    }
                    FootnoteText("Personal records only. Shared balances are separate from account spending.")
                }
            }
            .cairnScreen()
        }
        .cairnScrollEdge()
        .cairnCanvas()
        .navigationTitle("Shared expenses")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add shared expense", systemImage: "plus") { showingAdd = true }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu { Toggle("Show archived expenses", isOn: $showsArchived) } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Shared expense options")
            }
        }
        .sheet(isPresented: $showingAdd) { SharedExpenseEditor().cairnLockCover() }
    }

    @ViewBuilder
    private func summaryCard(_ currency: Currency) -> some View {
        if let totals = totals(currency) {
            HeroCard {
                VStack(alignment: .leading, spacing: CairnTheme.Spacing.l) {
                    HStack {
                        Text("Owed to you").font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.75))
                        Spacer()
                        Text(currency.displayLabel).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.65))
                    }
                    AmountText(money: Money(minorUnits: totals.owed, currency: currency), font: .cairnHero,
                               colorOverride: .white, deemphasizeFraction: true)
                    Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
                    HStack {
                        Text("You owe").font(.subheadline).foregroundStyle(.white.opacity(0.7))
                        Spacer()
                        AmountText(money: Money(minorUnits: totals.owe, currency: currency),
                                   font: .headline, colorOverride: .white)
                    }
                }
            }
        } else { FootnoteText("Shared expense totals unavailable") }
    }

    private func totals(_ currency: Currency) -> (owed: Int64, owe: Int64)? {
        var owed: Int64 = 0
        var owe: Int64 = 0
        for expense in expenses where !expense.isArchived {
            guard let input = try? expense.input, input.currency == currency else { continue }
            guard let values = try? payments.filter({ $0.expenseID == input.uuid }).map({ try $0.input }),
                  let balances = try? SharedExpenseCalculator.balances(for: input, payments: values) else { return nil }
            for balance in balances {
                if balance.owedToMe { owed = MinorUnits.addClamped(owed, balance.outstandingMinorUnits) }
                else { owe = MinorUnits.addClamped(owe, balance.outstandingMinorUnits) }
            }
        }
        return (owed, owe)
    }

    private func expenseRow(_ expense: SharedExpense) -> some View {
        HStack(spacing: CairnTheme.Spacing.m) {
            TrackingSymbol(name: "person.2")
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.xs) {
                Text(expense.title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                Text(expense.date, format: .dateTime.month().day()).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let input = try? expense.input,
               let values = try? payments.filter({ $0.expenseID == input.uuid }).map({ try $0.input }),
               let balances = try? SharedExpenseCalculator.balances(for: input, payments: values) {
                let outstanding = balances.reduce(Int64(0)) { MinorUnits.addClamped($0, $1.outstandingMinorUnits) }
                VStack(alignment: .trailing, spacing: CairnTheme.Spacing.xs) {
                    AmountText(money: Money(minorUnits: outstanding, currency: input.currency), font: .body.weight(.semibold))
                    Text(expense.isArchived ? "Archived" : outstanding == 0 ? "Settled"
                         : balances.first?.owedToMe == true ? "Owed to you" : "You owe")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(CairnTheme.warning)
                    .accessibilityLabel("Record unavailable")
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14).padding(.vertical, 14).contentShape(Rectangle())
    }
}

struct SharedExpenseDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Query private var expenses: [SharedExpense]
    @Query(sort: \SharedExpensePayment.date, order: .reverse) private var allPayments: [SharedExpensePayment]
    let expenseID: UUID
    @State private var showingEdit = false
    @State private var paymentTarget: SharedExpenseBalance?
    @State private var attachingPayment: SharedPaymentInput?
    @State private var showingDelete = false
    @State private var deletingPayment: UUID?
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(expenseID: UUID) {
        self.expenseID = expenseID
        _expenses = Query(filter: #Predicate { $0.uuid == expenseID })
    }

    private var payments: [SharedExpensePayment] { allPayments.filter { $0.expenseID == expenseID } }

    var body: some View {
        Group {
            if let expense = expenses.first, let input = try? expense.input { detail(input) }
            else { ContentUnavailableView("Expense unavailable", systemImage: "person.2") }
        }
        .navigationTitle("Shared expense")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("Couldn't save changes", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
        .confirmationDialog("Delete this shared expense?", isPresented: $showingDelete) {
            Button("Delete expense", role: .destructive) {
                perform { try await model.engine.deleteSharedExpense(expenseID); dismiss() }
            }
        } message: { Text("Its repayment history will also be removed. Account transactions are kept.") }
        .confirmationDialog("Delete this repayment?", isPresented: Binding(
            get: { deletingPayment != nil }, set: { if !$0 { deletingPayment = nil } }
        )) {
            Button("Delete repayment", role: .destructive) {
                if let id = deletingPayment { perform { try await model.engine.deleteSharedPayment(id) } }
                deletingPayment = nil
            }
        }
    }

    private func detail(_ input: SharedExpenseInput) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.xl) {
                Card(padding: 20) {
                    VStack(alignment: .leading, spacing: CairnTheme.Spacing.l) {
                        HStack(spacing: CairnTheme.Spacing.m) {
                            TrackingSymbol(name: "person.2", size: 52)
                            VStack(alignment: .leading, spacing: CairnTheme.Spacing.xs) {
                                Text(input.title).font(.title3.weight(.semibold))
                                Text(input.date, format: .dateTime.weekday(.wide).month(.wide).day())
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        AmountText(money: Money(minorUnits: input.totalMinorUnits, currency: input.currency),
                                   font: .cairnHero, deemphasizeFraction: true)
                        HStack {
                            Text("Paid by").foregroundStyle(.secondary)
                            Text(input.participants.first { $0.id == input.payerID }?.name ?? "").fontWeight(.medium)
                            Spacer()
                            if input.isArchived { StatusPill(text: "Archived", tint: .secondary) }
                        }
                        .font(.footnote)
                        if !input.note.isEmpty { Text(input.note).font(.subheadline).foregroundStyle(.secondary) }
                    }
                }
                balanceSection(input)
                Card {
                    VStack(alignment: .leading, spacing: CairnTheme.Spacing.m) {
                        CardHeader("Shares")
                        ForEach(input.participants) { person in
                            HStack {
                                Text(person.name).font(.subheadline)
                                Spacer()
                                AmountText(money: Money(minorUnits: person.shareMinorUnits, currency: input.currency),
                                           font: .subheadline.weight(.semibold))
                            }
                            if person.id != input.participants.last?.id { Divider() }
                        }
                    }
                }
                historySection(input)
                if let link = input.bankLink {
                    Card {
                        VStack(alignment: .leading, spacing: CairnTheme.Spacing.m) {
                            CardHeader("Attached expense transaction")
                            TrackingBankReference(link: link).font(.subheadline)
                        }
                    }
                }
                FootnoteText("Shared balances are personal records. Account spending and balances stay separate.")
            }
            .cairnScreen()
        }
        .cairnScrollEdge().cairnCanvas()
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("Edit") { showingEdit = true }.disabled(isSaving) }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(input.isArchived ? "Restore expense" : "Archive expense", systemImage: "archivebox") {
                        var updated = input
                        updated.isArchived.toggle()
                        perform { try await model.engine.saveSharedExpense(updated) }
                    }
                    Button("Delete expense", systemImage: "trash", role: .destructive) { showingDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .disabled(isSaving).accessibilityLabel("Shared expense options")
            }
        }
        .sheet(isPresented: $showingEdit) {
            SharedExpenseEditor(existing: input, hasPayments: !payments.isEmpty).cairnLockCover()
        }
        .sheet(item: $paymentTarget) { balance in
            SharedPaymentEditor(expense: input, balance: balance).cairnLockCover()
        }
        .sheet(item: $attachingPayment) { payment in
            let paidByMe = input.participants.first { $0.id == input.payerID }?.isMe == true
            TrackingBankPicker(currency: input.currency,
                               amount: paidByMe ? payment.amountMinorUnits : -payment.amountMinorUnits,
                               excludingID: payment.uuid) { link in
                perform { try await model.engine.attachSharedPayment(payment.uuid, to: link) }
            }
            .cairnLockCover()
        }
    }

    @ViewBuilder
    private func balanceSection(_ input: SharedExpenseInput) -> some View {
        if let values = try? payments.map({ try $0.input }),
           let balances = try? SharedExpenseCalculator.balances(for: input, payments: values) {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.s) {
                SectionLabel(title: "Outstanding")
                RowGroup {
                    ForEach(balances) { balance in
                        VStack(alignment: .leading, spacing: CairnTheme.Spacing.m) {
                            HStack(spacing: CairnTheme.Spacing.m) {
                                VStack(alignment: .leading, spacing: CairnTheme.Spacing.xs) {
                                    Text(balance.name).font(.body.weight(.medium))
                                    Text(balance.owedToMe ? "Owes you" : "You owe").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                AmountText(money: Money(minorUnits: balance.outstandingMinorUnits, currency: input.currency),
                                           font: .title3.weight(.semibold))
                            }
                            if balance.outstandingMinorUnits > 0, !input.isArchived {
                                Button { paymentTarget = balance } label: {
                                    Label("Record payment", systemImage: "plus")
                                }
                                .buttonStyle(.glass).controlSize(.regular)
                                .accessibilityHint(balance.owedToMe ? "Record received payment" : "Record your payment")
                            }
                        }
                        .padding(CairnTheme.Spacing.l)
                        if balance.id != balances.last?.id { RowDivider() }
                    }
                }
            }
        } else { FootnoteText("Repayment totals unavailable. Review this expense's shares and payments.") }
    }

    private func historySection(_ input: SharedExpenseInput) -> some View {
        VStack(alignment: .leading, spacing: CairnTheme.Spacing.s) {
            SectionLabel(title: "Repayment history")
            if payments.isEmpty {
                Card { Text("No repayments recorded").font(.subheadline).foregroundStyle(.secondary) }
            } else {
                RowGroup {
                    ForEach(payments) { payment in
                        VStack(alignment: .leading, spacing: CairnTheme.Spacing.s) {
                            HStack(spacing: CairnTheme.Spacing.m) {
                                TrackingSymbol(
                                    name: input.participants.first { $0.id == input.payerID }?.isMe == true
                                        ? "arrow.down.left" : "arrow.up.right", size: 36
                                )
                                VStack(alignment: .leading, spacing: CairnTheme.Spacing.xs) {
                                    Text(input.participants.first { $0.id == payment.participantID }?.name ?? "")
                                        .font(.body.weight(.medium))
                                    Text(payment.date, format: .dateTime.month().day().year())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                AmountText(money: Money(minorUnits: payment.amountMinorUnits, currency: input.currency),
                                           font: .body.weight(.semibold))
                                Menu {
                                    if (try? payment.input.bankLink) == nil {
                                        Button("Attach transaction", systemImage: "link") {
                                            attachingPayment = try? payment.input
                                        }
                                    } else {
                                        Button("Remove attachment", systemImage: "link.badge.plus") {
                                            perform { try await model.engine.attachSharedPayment(payment.uuid, to: nil) }
                                        }
                                    }
                                    Button("Delete repayment", systemImage: "trash", role: .destructive) {
                                        deletingPayment = payment.uuid
                                    }
                                } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
                                .buttonStyle(.plain).accessibilityLabel("Repayment options").disabled(isSaving)
                            }
                            if !payment.note.isEmpty { Text(payment.note).font(.subheadline).foregroundStyle(.secondary) }
                            if let link = try? payment.input.bankLink { TrackingBankReference(link: link).font(.caption) }
                        }
                        .padding(CairnTheme.Spacing.l)
                        if payment.uuid != payments.last?.uuid { RowDivider() }
                    }
                }
            }
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do { try await operation() } catch { errorMessage = error.localizedDescription }
        }
    }
}
