import SwiftUI
import CairnCore

/// Creates a manual account for something SimpleFIN can't reach — Apple Card,
/// Apple Savings, cash, property, or a loan.
struct ManualAccountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var type: AccountType = .other
    @State private var currencyCode = "USD"
    @State private var openingBalance = ""
    @State private var errorMessage: String?

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    TextField("Name", text: $name)
                    Picker("Type", selection: $type) {
                        ForEach(AccountType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    TextField("Currency", text: $currencyCode)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                }

                Section("Opening Balance") {
                    TextField("0.00", text: $openingBalance)
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                    Text("For a credit card or loan, enter what you currently owe as a negative number.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(CairnTheme.negative)
                }
            }
            .navigationTitle("New Manual Account")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(trimmedName.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 380)
        #endif
    }

    private func create() {
        let code = currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty else {
            errorMessage = "Enter a currency code such as USD."
            return
        }
        let currency = Currency(code: code, exponent: Currency.defaultExponent(forISOCode: code))
        let trimmedBalance = openingBalance.trimmingCharacters(in: .whitespacesAndNewlines)
        let balance = trimmedBalance.isEmpty ? 0 : (MinorUnits.parse(trimmedBalance, exponent: currency.exponent) ?? 0)

        model.createManualAccount(
            name: trimmedName,
            type: type,
            openingBalanceMinorUnits: balance,
            currency: currency
        )
        dismiss()
    }
}
