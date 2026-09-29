import SwiftUI
import CairnCore

struct BudgetExpenseSmoothingEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let accountIDIndex: String
    let bankTransactionID: String
    let purchaseDescription: String
    let purchaseDate: Date
    let purchaseAmountMinorUnits: Int64
    let currency: Currency
    let timeZoneIdentifier: String
    let existingPlan: BudgetSmoothingPlan?

    @State private var name: String
    @State private var firstBudgetMonth: Date
    @State private var durationMonths: Int
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(
        transaction: LedgerTransaction,
        existingPlan: BudgetSmoothingPlan?,
        timeZoneIdentifier: String
    ) {
        self.accountIDIndex = transaction.accountIDIndex
        self.bankTransactionID = transaction.bankTransactionID
        self.purchaseDescription = transaction.displayDescription
        self.purchaseDate = transaction.effectiveDate
        self.purchaseAmountMinorUnits = MinorUnits.absClamped(transaction.amountMinorUnits)
        self.currency = transaction.amount.currency
        self.timeZoneIdentifier = timeZoneIdentifier
        self.existingPlan = existingPlan

        let timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        let existingMonth = existingPlan.flatMap {
            BudgetCalculator.startOfMonth($0.startMonthKey, timeZone: timeZone)
        }
        let initialName = existingPlan?.name
            ?? (transaction.displayDescription.isEmpty ? "Purchase" : transaction.displayDescription)
        _name = State(
            initialValue: String(initialName.prefix(BudgetExpenseSmoothingCalculator.maximumNameLength))
        )
        _firstBudgetMonth = State(initialValue: existingMonth ?? transaction.effectiveDate)
        _durationMonths = State(
            initialValue: min(
                BudgetExpenseSmoothingCalculator.maximumMonths,
                max(
                    BudgetExpenseSmoothingCalculator.minimumMonths,
                    existingPlan?.durationMonths ?? 12
                )
            )
        )
    }

    private var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? .current
    }

    private var earliestStartDate: Date {
        let purchaseMonth = BudgetCalculator.monthKey(for: purchaseDate, timeZone: timeZone)
        return BudgetCalculator.startOfMonth(purchaseMonth, timeZone: timeZone) ?? purchaseDate
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var monthlyEstimate: Int64 {
        purchaseAmountMinorUnits / Int64(max(1, durationMonths))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Purchase") {
                    LabeledContent("Transaction", value: purchaseDescription.isEmpty ? "Purchase" : purchaseDescription)
                    LabeledContent("Posted amount") {
                        AmountText(
                            money: Money(minorUnits: purchaseAmountMinorUnits, currency: currency),
                            font: .subheadline.weight(.semibold)
                        )
                    }
                }

                Section("Budget schedule") {
                    TextField("Name", text: $name, prompt: Text("Mattress from Costco"))
                        .onChange(of: name) { _, updated in
                            if updated.count > BudgetExpenseSmoothingCalculator.maximumNameLength {
                                name = String(updated.prefix(BudgetExpenseSmoothingCalculator.maximumNameLength))
                            }
                        }
                    DatePicker(
                        "First budget month",
                        selection: $firstBudgetMonth,
                        in: earliestStartDate...,
                        displayedComponents: .date
                    )
                    Stepper(value: $durationMonths, in: 2...60) {
                        Text("Spread over \(durationMonths) months")
                    }
                }

                Section {
                    Text(
                        "About \(Money(minorUnits: monthlyEstimate, currency: currency).formatted()) will count in each month. Any rounding remainder goes to the earliest months."
                    )
                    Text("This changes budget totals only. The posted transaction and account balance keep the full amount.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(CairnTheme.negative)
                    }
                }

                if existingPlan != nil {
                    Section {
                        Button("Remove schedule", role: .destructive) { remove() }
                            .disabled(isSaving)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existingPlan == nil ? "Spread Expense" : "Edit Schedule")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(trimmedName.isEmpty || isSaving)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 420)
        #endif
    }

    private func save() {
        guard !isSaving, !trimmedName.isEmpty else { return }
        isSaving = true
        let input = BudgetExpenseSmoothingInput(
            accountIDIndex: accountIDIndex,
            bankTransactionID: bankTransactionID,
            name: trimmedName,
            startMonthKey: BudgetCalculator.monthKey(for: firstBudgetMonth, timeZone: timeZone),
            durationMonths: durationMonths,
            timeZoneIdentifier: timeZone.identifier
        )
        Task {
            if await model.saveBudgetExpenseSmoothing(input) {
                dismiss()
            } else {
                errorMessage = model.banner ?? "The schedule could not be saved."
            }
            isSaving = false
        }
    }

    private func remove() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            if await model.removeBudgetExpenseSmoothing(
                accountIDIndex: accountIDIndex,
                bankTransactionID: bankTransactionID
            ) {
                dismiss()
            } else {
                errorMessage = model.banner ?? "The schedule could not be removed."
            }
            isSaving = false
        }
    }
}
