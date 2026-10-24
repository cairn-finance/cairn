import SwiftUI
import CairnCore

struct SinkingFundEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let existing: SinkingFundInput?
    let hasEntries: Bool
    @State private var id: UUID
    @State private var name: String
    @State private var currency: Currency
    @State private var target: String
    @State private var opening = ""
    @State private var hasTargetDate: Bool
    @State private var targetDate: Date
    @State private var monthly: String
    @State private var state: SinkingFundState
    @State private var note: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    init(existing: SinkingFundInput? = nil, hasEntries: Bool = false) {
        self.existing = existing
        self.hasEntries = hasEntries
        let currency = existing?.currency ?? .usd
        _id = State(initialValue: existing?.uuid ?? UUID())
        _name = State(initialValue: existing?.name ?? "")
        _currency = State(initialValue: currency)
        _target = State(initialValue: existing.map { MinorUnits.string($0.targetMinorUnits, exponent: currency.exponent) } ?? "")
        _hasTargetDate = State(initialValue: existing?.targetDate != nil)
        _targetDate = State(initialValue: existing?.targetDate ?? .now)
        _monthly = State(initialValue: existing.map {
            MinorUnits.string($0.monthlyContributionMinorUnits, exponent: currency.exponent)
        } ?? "")
        _state = State(initialValue: existing?.state ?? .active)
        _note = State(initialValue: existing?.note ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CairnTheme.Spacing.l) {
                    TrackingFormSection(title: "Fund") {
                        TextField("Fund name", text: $name).focused($nameFocused)
                        TrackingAmountField("Target amount", text: $target)
                        TrackingCurrencyPicker(currency: $currency).disabled(hasEntries)
                        if existing == nil { TrackingAmountField("Already allocated (optional)", text: $opening) }
                    }
                    TrackingFormSection(title: "Contribution plan") {
                        Toggle("Set a target date", isOn: $hasTargetDate)
                        if hasTargetDate { DatePicker("Target date", selection: $targetDate, displayedComponents: .date) }
                        TrackingAmountField("Monthly contribution plan (optional)", text: $monthly)
                        FootnoteText("A target date gives a monthly suggestion. Record contributions when you set money aside.")
                    }
                    TrackingFormSection(title: "Details") {
                        Picker("Status", selection: $state) {
                            ForEach(SinkingFundState.allCases, id: \.self) { value in Text(value.title).tag(value) }
                        }
                        TextField("Note (optional)", text: $note, axis: .vertical).lineLimit(2...5)
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
            .navigationTitle(existing == nil ? "Add sinking fund" : "Edit sinking fund")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(isSaving).accessibilityIdentifier("saveSinkingFund")
                }
            }
            .task { if existing == nil { nameFocused = true } }
        }
        .interactiveDismissDisabled(isSaving)
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 620)
        #endif
    }

    private func save() {
        guard !isSaving else { return }
        do {
            guard let parsedTarget = PersonalTrackingAmount.parse(target, currency: currency) else {
                throw PersonalTrackingError.invalidAmount
            }
            let openingAmount = try parseOptional(opening)
            let monthlyAmount = try parseOptional(monthly)
            let input = SinkingFundInput(
                uuid: id, name: name, currency: currency, targetMinorUnits: parsedTarget,
                targetDate: hasTargetDate ? targetDate : nil, monthlyContributionMinorUnits: monthlyAmount,
                timeZoneIdentifier: existing?.timeZoneIdentifier ?? TimeZone.current.identifier, state: state, note: note
            )
            try SinkingFundCalculator.validate(input)
            isSaving = true
            Task {
                defer { isSaving = false }
                do { try await model.engine.saveSinkingFund(input, openingMinorUnits: openingAmount); dismiss() }
                catch { errorMessage = error.localizedDescription }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func parseOptional(_ text: String) throws -> Int64 {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return 0 }
        guard let amount = PersonalTrackingAmount.parse(text, currency: currency), amount >= 0 else {
            throw PersonalTrackingError.invalidAmount
        }
        return amount
    }
}

struct SinkingFundEntryEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let fund: SinkingFundInput
    @State private var id = UUID()
    @State private var kind = SinkingFundEntryKind.contribution
    @State private var amount = ""
    @State private var date = Date.now
    @State private var note = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CairnTheme.Spacing.l) {
                    HStack(spacing: CairnTheme.Spacing.m) {
                        TrackingSymbol(name: "tray.and.arrow.down")
                        Text(fund.name).font(.title3.weight(.semibold))
                    }
                    .padding(.horizontal, CairnTheme.Spacing.xs)
                    TrackingFormSection(title: "Allocation") {
                        Picker("Type", selection: $kind) {
                            ForEach([SinkingFundEntryKind.contribution, .withdrawal, .correction], id: \.self) { value in
                                Text(value.title).tag(value)
                            }
                        }
                        .accessibilityIdentifier("fundEntryType")
                        TrackingAmountField("Amount", text: $amount)
                        DatePicker("Date", selection: $date, in: ...Date.now, displayedComponents: .date)
                        TextField("Note (optional)", text: $note, axis: .vertical).lineLimit(2...5)
                    }
                    FootnoteText("Enter a positive contribution or withdrawal. Corrections may be positive or negative.")
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
            .navigationTitle("Record allocation")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(isSaving) }
            }
        }
        .interactiveDismissDisabled(isSaving)
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 520)
        #endif
    }

    private func save() {
        guard !isSaving else { return }
        guard let parsed = PersonalTrackingAmount.parse(amount, currency: fund.currency), parsed != 0,
              kind == .correction || parsed > 0 else {
            errorMessage = PersonalTrackingError.invalidAmount.localizedDescription
            return
        }
        let input = SinkingFundEntryInput(
            uuid: id, fundID: fund.uuid, amountMinorUnits: kind == .withdrawal ? -parsed : parsed,
            kind: kind, date: date, note: note
        )
        isSaving = true
        Task {
            defer { isSaving = false }
            do { try await model.engine.addSinkingFundEntry(input); dismiss() }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
