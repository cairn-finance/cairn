import SwiftUI
import CairnCore

private struct ParticipantDraft: Identifiable {
    var id: UUID
    var name: String
    var isMe: Bool
    var amount: String
}

struct SharedExpenseEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let existing: SharedExpenseInput?
    let hasPayments: Bool
    @State private var id: UUID
    @State private var title: String
    @State private var date: Date
    @State private var amount: String
    @State private var currency: Currency
    @State private var people: [ParticipantDraft]
    @State private var payerID: UUID
    @State private var splitEqually: Bool
    @State private var note: String
    @State private var bankLink: TrackingBankLink?
    @State private var showingBankPicker = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var titleFocused: Bool

    init(existing: SharedExpenseInput? = nil, hasPayments: Bool = false, prefill: SharedExpenseInput? = nil) {
        self.existing = existing
        self.hasPayments = hasPayments
        let seed = existing ?? prefill
        let currency = seed?.currency ?? .usd
        let people = seed?.participants ?? [
            ExpenseParticipant(name: String(localized: "You"), isMe: true), ExpenseParticipant(name: "")
        ]
        _id = State(initialValue: seed?.uuid ?? UUID())
        _title = State(initialValue: seed?.title ?? "")
        _date = State(initialValue: seed?.date ?? .now)
        _amount = State(initialValue: seed.map { MinorUnits.string($0.totalMinorUnits, exponent: currency.exponent) } ?? "")
        _currency = State(initialValue: currency)
        _people = State(initialValue: people.map {
            ParticipantDraft(id: $0.id, name: $0.name, isMe: $0.isMe,
                             amount: seed == nil ? "" : MinorUnits.string($0.shareMinorUnits, exponent: currency.exponent))
        })
        _payerID = State(initialValue: seed?.payerID ?? people[0].id)
        let equal = seed.flatMap { try? SharedExpenseCalculator.equalShares(total: $0.totalMinorUnits, count: people.count) }
        _splitEqually = State(initialValue: seed == nil || equal == people.map(\.shareMinorUnits))
        _note = State(initialValue: seed?.note ?? "")
        _bankLink = State(initialValue: seed?.bankLink)
    }

    private var total: Int64? { PersonalTrackingAmount.parse(amount, currency: currency) }
    private var paidByMe: Bool { people.first { $0.id == payerID }?.isMe == true }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CairnTheme.Spacing.l) {
                    TrackingFormSection(title: "Expense") {
                        TextField("Description", text: $title).focused($titleFocused)
                        TrackingAmountField("Total amount", text: $amount)
                        TrackingCurrencyPicker(currency: $currency).disabled(hasPayments || bankLink != nil)
                    }
                    TrackingFormSection(title: "Shares") {
                        Picker("Paid by", selection: $payerID) {
                            ForEach(people) { person in
                                Text(person.name.isEmpty ? String(localized: "Unnamed person") : person.name).tag(person.id)
                            }
                        }
                        .disabled(hasPayments)
                        Toggle("Split equally", isOn: $splitEqually)
                        Divider()
                        ForEach($people) { $person in
                            VStack(alignment: .leading, spacing: CairnTheme.Spacing.s) {
                                HStack(spacing: CairnTheme.Spacing.m) {
                                    if person.isMe {
                                        Text(person.name).font(.body.weight(.medium))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    } else {
                                        TextField("Person's name", text: $person.name)
                                    }
                                    if splitEqually {
                                        Text(equalAmount(for: person.id)).font(.subheadline.weight(.semibold)).monospacedDigit()
                                    }
                                    if !person.isMe, people.count > 2 {
                                        Button("Remove person", systemImage: "minus.circle", role: .destructive) {
                                            remove(person.id)
                                        }
                                        .labelStyle(.iconOnly).buttonStyle(.plain).frame(minWidth: 44, minHeight: 44)
                                    }
                                }
                                if !splitEqually { TrackingAmountField("Share amount", text: $person.amount) }
                            }
                            if person.id != people.last?.id { Divider() }
                        }
                        Button("Add person", systemImage: "person.badge.plus") {
                            people.append(ParticipantDraft(id: UUID(), name: "", isMe: false, amount: ""))
                        }
                        .disabled(people.count >= 20)
                    }
                    TrackingFormSection(title: "Details") {
                        DatePicker("Date", selection: $date, displayedComponents: .date)
                        TextField("Note (optional)", text: $note, axis: .vertical).lineLimit(2...5)
                    }
                    TrackingFormSection(title: "Optional attachment") {
                        if let bankLink {
                            TrackingBankReference(link: bankLink).font(.subheadline)
                            Button("Remove attachment", role: .destructive) { self.bankLink = nil }
                        } else if paidByMe {
                            Button("Attach expense transaction", systemImage: "link") { showingBankPicker = true }
                                .disabled((total ?? 0) <= 0)
                        } else {
                            FootnoteText("You can attach your repayment when you record it.")
                        }
                        FootnoteText("You can save without a bank transaction. Attachments are references only.")
                    }
                    if let errorMessage {
                        Card { Label(errorMessage, systemImage: "exclamationmark.triangle").font(.footnote)
                            .foregroundStyle(CairnTheme.negative) }
                    }
                }
                .cairnScreen(maxWidth: 560)
            }
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("trackingEditorScroll")
            .cairnCanvas()
            .navigationTitle(existing == nil ? "Add shared expense" : "Edit shared expense")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(isSaving).accessibilityIdentifier("saveSharedExpense")
                }
            }
            .sheet(isPresented: $showingBankPicker) {
                TrackingBankPicker(currency: currency, amount: -(total ?? 0), excludingID: id) { bankLink = $0 }
                    .cairnLockCover()
            }
            .task { if existing == nil { titleFocused = true } }
        }
        .interactiveDismissDisabled(isSaving)
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 620)
        #endif
    }

    private func equalAmount(for id: UUID) -> String {
        guard let total, let index = people.firstIndex(where: { $0.id == id }),
              let shares = try? SharedExpenseCalculator.equalShares(total: total, count: people.count) else { return "—" }
        return Money(minorUnits: shares[index], currency: currency).formatted()
    }

    private func remove(_ id: UUID) {
        people.removeAll { $0.id == id }
        if payerID == id, let me = people.first(where: \.isMe) { payerID = me.id }
    }

    private func save() {
        guard !isSaving else { return }
        do {
            guard let total, total > 0 else { throw PersonalTrackingError.invalidAmount }
            let amounts = try splitEqually
                ? SharedExpenseCalculator.equalShares(total: total, count: people.count)
                : people.map { person in
                    guard let value = PersonalTrackingAmount.parse(person.amount, currency: currency) else {
                        throw PersonalTrackingError.invalidAmount
                    }
                    return value
                }
            let participants = zip(people, amounts).map { person, share in
                ExpenseParticipant(id: person.id, name: person.name.trimmingCharacters(in: .whitespacesAndNewlines),
                                   shareMinorUnits: share, isMe: person.isMe)
            }
            let input = SharedExpenseInput(
                uuid: id, title: title, date: date, totalMinorUnits: total, currency: currency,
                participants: participants, payerID: payerID, note: note, bankLink: bankLink,
                isArchived: existing?.isArchived ?? false
            )
            try SharedExpenseCalculator.validate(input)
            isSaving = true
            Task {
                defer { isSaving = false }
                do { try await model.engine.saveSharedExpense(input); dismiss() }
                catch { errorMessage = error.localizedDescription }
            }
        } catch { errorMessage = error.localizedDescription }
    }
}

struct SharedPaymentEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let expense: SharedExpenseInput
    let balance: SharedExpenseBalance
    @State private var id = UUID()
    @State private var amount: String
    @State private var date = Date.now
    @State private var note = ""
    @State private var bankLink: TrackingBankLink?
    @State private var showingBankPicker = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(expense: SharedExpenseInput, balance: SharedExpenseBalance) {
        self.expense = expense
        self.balance = balance
        _amount = State(initialValue: MinorUnits.string(balance.outstandingMinorUnits, exponent: expense.currency.exponent))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CairnTheme.Spacing.l) {
                    HStack(spacing: CairnTheme.Spacing.m) {
                        TrackingSymbol(name: balance.owedToMe ? "arrow.down.left" : "arrow.up.right")
                        VStack(alignment: .leading, spacing: CairnTheme.Spacing.xs) {
                            Text(balance.name).font(.title3.weight(.semibold))
                            Text(balance.owedToMe ? "Payment received" : "Your repayment")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, CairnTheme.Spacing.xs)
                    TrackingFormSection(title: "Repayment") {
                        TrackingAmountField("Payment amount", text: $amount)
                        DatePicker("Date", selection: $date, in: ...Date.now, displayedComponents: .date)
                        TextField("Note (optional)", text: $note, axis: .vertical).lineLimit(2...5)
                    }
                    TrackingFormSection(title: "Optional attachment") {
                        if let bankLink {
                            TrackingBankReference(link: bankLink).font(.subheadline)
                            Button("Remove attachment", role: .destructive) { self.bankLink = nil }
                        } else {
                            Button("Attach payment transaction", systemImage: "link") { showingBankPicker = true }
                                .disabled((PersonalTrackingAmount.parse(amount, currency: expense.currency) ?? 0) <= 0)
                        }
                        FootnoteText("Cash and other repayments can be recorded without a bank transaction.")
                    }
                    if let errorMessage {
                        Card { Label(errorMessage, systemImage: "exclamationmark.triangle").font(.footnote)
                            .foregroundStyle(CairnTheme.negative) }
                    }
                }
                .cairnScreen(maxWidth: 560)
            }
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("trackingEditorScroll")
            .cairnCanvas()
            .navigationTitle("Record repayment")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(isSaving) }
            }
            .sheet(isPresented: $showingBankPicker) {
                let parsed = PersonalTrackingAmount.parse(amount, currency: expense.currency) ?? 0
                TrackingBankPicker(
                    currency: expense.currency, amount: balance.owedToMe ? parsed : -parsed, excludingID: id
                ) { bankLink = $0 }.cairnLockCover()
            }
        }
        .interactiveDismissDisabled(isSaving)
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 520)
        #endif
    }

    private func save() {
        guard !isSaving else { return }
        guard let parsed = PersonalTrackingAmount.parse(amount, currency: expense.currency), parsed > 0 else {
            errorMessage = PersonalTrackingError.invalidAmount.localizedDescription
            return
        }
        isSaving = true
        let input = SharedPaymentInput(
            uuid: id, expenseID: expense.uuid, participantID: balance.participantID,
            amountMinorUnits: parsed, date: date, note: note, bankLink: bankLink
        )
        Task {
            defer { isSaving = false }
            do { try await model.engine.addSharedPayment(input); dismiss() }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
