import SwiftUI
import CairnCore

/// Creates a manual account for something SimpleFIN can't reach — Apple Card,
/// Apple Savings, cash, property, or a loan.
struct ManualAccountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// The type a caller wants preselected, e.g. Investments adds an
    /// investment account.
    var initialType: AccountType = .checking
    /// Called with the created account, so a caller can continue a flow.
    var onCreated: ((Account) -> Void)?

    @State private var name = ""
    @State private var type: AccountType = .checking
    @State private var currencyCode = "USD"
    @State private var openingBalance = ""
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    init(initialType: AccountType = .checking, onCreated: ((Account) -> Void)? = nil) {
        self.initialType = initialType
        self.onCreated = onCreated
        _type = State(initialValue: initialType)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private let typeColumns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Apple Card, Cash, Mortgage…"))
                        .focused($nameFocused)
                    LazyVGrid(columns: typeColumns, spacing: 8) {
                        ForEach(AccountType.allCases, id: \.self) { candidate in
                            typeChip(candidate)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Account")
                }

                Section {
                    HStack {
                        TextField("0.00", text: $openingBalance)
                            .font(.title3.weight(.semibold).monospacedDigit())
                            #if os(iOS)
                            .keyboardType(.numbersAndPunctuation)
                            #endif
                        TextField("USD", text: $currencyCode)
                            .frame(width: 64)
                            .multilineTextAlignment(.trailing)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.characters)
                            #endif
                    }
                } header: {
                    Text("Opening balance")
                } footer: {
                    Text(type.isLiability
                         ? "Enter what you currently owe as a negative number, e.g. -1250.00."
                         : "The balance right now. You can import transactions afterwards.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(CairnTheme.negative)
                    }
                }
            }
            .formStyle(.grouped)
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
            .onAppear { nameFocused = true }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 420)
        #endif
    }

    private func typeChip(_ candidate: AccountType) -> some View {
        let selected = candidate == type
        let style = glyph(for: candidate)
        return Button {
            withAnimation(CairnTheme.Motion.quick) { type = candidate }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: style.symbol)
                    .font(.caption.weight(.semibold))
                Text(candidate.displayName)
                    .font(.footnote.weight(selected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .foregroundStyle(selected ? Color.white : style.tint)
            .background(selected ? style.tint : style.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func glyph(for candidate: AccountType) -> AccountGlyphStyle {
        let probe = Account(name: "", currency: .usd)
        probe.accountTypeRaw = candidate.rawValue
        probe.sourceRaw = AccountSource.manual.rawValue
        return AccountGlyphStyle.forAccount(probe)
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

        let account = model.createManualAccount(
            name: trimmedName,
            type: type,
            openingBalanceMinorUnits: balance,
            currency: currency
        )
        onCreated?(account)
        dismiss()
    }
}
