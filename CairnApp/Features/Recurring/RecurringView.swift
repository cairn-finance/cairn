import SwiftUI
import SwiftData
import CairnCore

/// Subscriptions and other regular payments Cairn has spotted in history.
/// Detection is entirely on-device; nothing about a merchant leaves the phone.
struct RecurringView: View {
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<Account> { $0.isHidden == false })
    private var accounts: [Account]
    @Query private var settings: [AppSettings]
    @Query(sort: \ConfirmedCommitment.nextDueDate)
    private var commitments: [ConfirmedCommitment]
    @State private var editingCommitment: ConfirmedCommitment?

    private var homeCurrency: Currency { NetWorthMath.homeCurrency(settings: settings) }

    private var primaryCurrency: Currency {
        accounts.first(where: { $0.currency == homeCurrency })?.currency
            ?? accounts.first(where: { $0.currency.code == homeCurrency.code })?.currency
            ?? accounts.first?.currency
            ?? homeCurrency
    }

    private var series: [RecurringSeries] {
        model.recurringSeries.filter { $0.currency == primaryCurrency }
    }

    private var visibleCommitments: [ConfirmedCommitment] {
        commitments.filter { $0.currency == primaryCurrency }
    }

    private var outgoing: [RecurringSeries] {
        series.filter { $0.direction == .outgoing }
    }

    private var incoming: [RecurringSeries] {
        series.filter { $0.direction == .incoming }
    }

    private var monthlyOutgoing: Int64 {
        outgoing.reduce(Int64(0)) { MinorUnits.addClamped($0, $1.monthlyEquivalentMinorUnits) }
    }

    private var monthlyIncoming: Int64 {
        incoming.reduce(Int64(0)) { MinorUnits.addClamped($0, $1.monthlyEquivalentMinorUnits) }
    }

    /// The soonest upcoming charge, used for the hero's secondary line.
    private var nextCharge: RecurringSeries? {
        outgoing
            .filter { !$0.isOverdue() }
            .min { $0.nextExpectedDate < $1.nextExpectedDate }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.xl) {
                if series.isEmpty && visibleCommitments.isEmpty {
                    EmptyStateView(
                        systemImage: "repeat",
                        title: "No recurring payments yet",
                        message: "Cairn finds charges that repeat on a schedule after three matching charges on one account.",
                        actionTitle: "Sync Now"
                    ) {
                        Task { await model.syncAll(force: true) }
                    }
                } else {
                    if !series.isEmpty {
                        hero.cairnAppear()
                    }
                    if !visibleCommitments.isEmpty {
                        confirmedSection.cairnAppear(delay: series.isEmpty ? 0 : 0.05)
                    }
                    if !outgoing.isEmpty {
                        section("Subscriptions & bills", series: outgoing).cairnAppear(delay: visibleCommitments.isEmpty ? 0.05 : 0.1)
                    }
                    if !incoming.isEmpty {
                        section("Recurring income", series: incoming).cairnAppear(delay: visibleCommitments.isEmpty ? 0.1 : 0.15)
                    }
                    FootnoteText(
                        "Based on your synced and imported history. Cairn never sends merchant names off this device."
                    )
                    .cairnAppear(delay: 0.15)
                }
            }
            .cairnScreen()
        }
        .cairnCanvas()
        .navigationTitle("Recurring")
        .sheet(item: $editingCommitment) { commitment in
            CommitmentEditSheet(commitment: commitment)
                .cairnLockCover()
        }
        .task { await model.refreshRecurring() }
    }

    private var confirmedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Confirmed plans")
            RowGroup {
                ForEach(visibleCommitments) { commitment in
                    Button { editingCommitment = commitment } label: {
                        ConfirmedCommitmentRow(commitment: commitment)
                    }
                    .buttonStyle(.plain)
                    if commitment.persistentModelID != visibleCommitments.last?.persistentModelID {
                        RowDivider()
                    }
                }
            }
            FootnoteText("Confirmed plans stay available even when their detected transaction history changes.")
        }
    }

    // MARK: - Hero

    private var hero: some View {
        HeroCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Recurring commitments")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.75))

                AmountText(
                    money: Money(minorUnits: monthlyOutgoing, currency: primaryCurrency),
                    font: .cairnHero,
                    colorOverride: .white,
                    deemphasizeFraction: true
                )

                HStack(spacing: 8) {
                    Text("^[\(outgoing.count) subscription](inflect: true) & bills")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                    if let next = nextCharge {
                        Text("·")
                            .foregroundStyle(.white.opacity(0.4))
                        Text("Next \(next.nextExpectedDate.formatted(.dateTime.month(.abbreviated).day()))")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

                if !incoming.isEmpty {
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 1)
                    HStack(alignment: .top, spacing: 16) {
                        heroMetric("Monthly out", monthlyOutgoing)
                        heroMetric("Monthly in", monthlyIncoming, tint: CairnTheme.inkGlow)
                    }
                }
            }
        }
    }

    private func heroMetric(_ title: String, _ minorUnits: Int64, tint: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
            AmountText(
                money: Money(minorUnits: minorUnits, currency: primaryCurrency),
                font: .subheadline.weight(.semibold),
                colorOverride: tint
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Sections

    private func section(_ title: LocalizedStringKey, series: [RecurringSeries]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: title)
            RowGroup {
                ForEach(Array(series.enumerated()), id: \.element.id) { index, item in
                    NavigationLink {
                        RecurringDetailView(series: item)
                    } label: {
                        RecurringRow(series: item)
                    }
                    .buttonStyle(.plain)
                    if index < series.count - 1 {
                        RowDivider()
                    }
                }
            }
        }
    }
}

/// One detected series in the list: the merchant, its rhythm, and the charge.
struct RecurringRow: View {
    let series: RecurringSeries

    var body: some View {
        HStack(spacing: CairnTheme.Spacing.m) {
            CategoryBadge(
                symbolName: series.categorySymbolName ?? "repeat",
                hex: series.categoryColorHex,
                size: 40
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(series.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(series.cadence.displayName)
                    Text("·").foregroundStyle(.tertiary)
                    Text(nextText.text)
                        .foregroundStyle(nextText.isOverdue ? CairnTheme.warning : .secondary)
                    if let label = series.confidenceLabel {
                        StatusPill(text: "\(label)", tint: .secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                AmountText(
                    money: Money(minorUnits: abs(series.averageAmountMinorUnits), currency: series.currency),
                    showSign: series.direction == .incoming,
                    font: .body.weight(.semibold),
                    colorOverride: series.direction == .incoming ? CairnTheme.positive : nil
                )
                .fixedSize(horizontal: true, vertical: false)

                if series.cadence != .monthly {
                    Text("≈ \(Money(minorUnits: series.monthlyEquivalentMinorUnits, currency: series.currency).formatted())/mo")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
    }

    private var nextText: (text: LocalizedStringKey, isOverdue: Bool) {
        let days = series.daysUntilNext()
        if days < 0 {
            return ("Was due \(series.nextExpectedDate.formatted(.dateTime.month(.abbreviated).day()))", true)
        }
        if days == 0 {
            return ("Due today", false)
        }
        if days <= 7 {
            return ("Due in ^[\(days) day](inflect: true)", false)
        }
        return ("Next \(series.nextExpectedDate.formatted(.dateTime.month(.abbreviated).day()))", false)
    }
}

private struct ConfirmedCommitmentRow: View {
    let commitment: ConfirmedCommitment

    var body: some View {
        HStack(spacing: CairnTheme.Spacing.m) {
            SettingsIcon(
                systemImage: commitment.state == .active ? "checkmark.circle.fill" : "pause.circle",
                tint: commitment.state == .active ? CairnTheme.positive : .secondary
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(commitment.name.isEmpty ? "Confirmed commitment" : commitment.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text("\(commitment.cadence.displayName) · \(commitment.nextDueDate.formatted(.dateTime.month(.abbreviated).day())) · \(commitment.state.rawValue.capitalized)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            AmountText(
                money: Money(minorUnits: MinorUnits.absClamped(commitment.amountMinorUnits), currency: commitment.currency),
                showSign: commitment.amountMinorUnits > 0,
                font: .body.weight(.semibold),
                colorOverride: commitment.amountMinorUnits > 0 ? CairnTheme.positive : nil
            )
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Double tap to edit this confirmed plan")
    }
}

/// A compact entry point shown on Home and Insights.
struct RecurringSummaryCard: View {
    let series: [RecurringSeries]
    let currency: Currency
    var confirmedCount: Int = 0

    private var outgoing: [RecurringSeries] {
        series.filter { $0.direction == .outgoing }
    }

    private var monthlyOutgoing: Int64 {
        outgoing.reduce(Int64(0)) { MinorUnits.addClamped($0, $1.monthlyEquivalentMinorUnits) }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    SettingsIcon(systemImage: "repeat", tint: Color(red: 0.62, green: 0.36, blue: 0.87))
                    Text("Subscriptions & recurring")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }

                if monthlyOutgoing > 0 {
                    AmountText(
                        money: Money(minorUnits: monthlyOutgoing, currency: currency),
                        font: .title3.weight(.semibold),
                        deemphasizeFraction: true
                    )
                    Text("Estimated monthly outgoing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: LocalizedStringKey {
        guard !series.isEmpty else { return "None detected yet" }
        let subscriptions = series.filter(\.isSubscription).count
        if confirmedCount > 0 { return "\(confirmedCount) confirmed · \(series.count) detected" }
        return "\(series.count) detected · ^[\(subscriptions) subscription](inflect: true)"
    }
}

/// The detail behind one detected series: the summary and every charge in it.
struct RecurringDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var modelContext
    @Query private var commitments: [ConfirmedCommitment]
    @State private var charges: [TransactionRowValue] = []
    @State private var isLoadingCharges = true
    @State private var chargeLoadFailed = false
    @State private var isConfirmed = false
    @State private var showingEdit = false

    let series: RecurringSeries

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.xl) {
                header
                if !isConfirmed {
                    Button {
                        Task { isConfirmed = await model.confirmRecurring(series) }
                    } label: {
                        Label(series.direction == .outgoing ? "Confirm as bill" : "Confirm as income", systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Text("Confirmation creates your own plan. Future syncs can change the detected evidence without changing this plan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let commitment {
                    HStack {
                        Label("Confirmed commitment", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(CairnTheme.positive)
                        Spacer()
                        Button("Edit") { showingEdit = true }
                    }
                    .sheet(isPresented: $showingEdit) {
                        CommitmentEditSheet(commitment: commitment)
                    }
                }
                summary
                if isLoadingCharges {
                    ProgressView("Loading charges…")
                } else if chargeLoadFailed {
                    FootnoteText("Couldn’t load these charges. Try opening this payment again.")
                } else if charges.isEmpty {
                    FootnoteText("These charges are no longer available.")
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(title: "Charges", trailing: "\(charges.count)")
                        TransactionDayList(rows: charges)
                    }
                }
            }
            .cairnScreen()
        }
        .cairnCanvas()
        .navigationTitle(series.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: series.id) {
            isConfirmed = commitments.contains { $0.detectorID == series.id }
            isLoadingCharges = true
            do {
                let rows = try await model.recurringChargeRows(for: series)
                guard !Task.isCancelled else { return }
                charges = rows
                chargeLoadFailed = false
            } catch {
                guard !Task.isCancelled else { return }
                charges = []
                chargeLoadFailed = true
            }
            isLoadingCharges = false
        }
    }

    private var commitment: ConfirmedCommitment? {
        commitments.first { $0.detectorID == series.id }
    }

    private var header: some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    CategoryBadge(
                        symbolName: series.categorySymbolName ?? "repeat",
                        hex: series.categoryColorHex,
                        size: 52
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(series.displayName)
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            Text(series.cadence.displayName)
                            if series.isVariableAmount {
                                StatusPill(text: "Varies", tint: .secondary)
                            }
                            if let label = series.confidenceLabel {
                                StatusPill(text: "\(label)", tint: .secondary)
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }

                AmountText(
                    money: Money(minorUnits: abs(series.averageAmountMinorUnits), currency: series.currency),
                    showSign: series.direction == .incoming,
                    font: .cairnDisplay,
                    colorOverride: series.direction == .incoming ? CairnTheme.positive : nil
                )
                .contentTransition(.numericText())

                let monthly = Money(
                    minorUnits: series.monthlyEquivalentMinorUnits,
                    currency: series.currency
                ).formatted()
                Text("\(series.cadence.displayName) · about \(monthly)/mo")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summary: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader("Details")
                detailRow("Direction", series.direction == .outgoing ? "Money out" : "Money in")
                detailRow("Charges seen", "\(series.occurrences)")
                detailRow("Every", String(localized: "\(series.cadence.displayName)"))
                detailRow("First seen", series.firstDate.formatted(date: .abbreviated, time: .omitted))
                detailRow("Most recent", series.lastDate.formatted(date: .abbreviated, time: .omitted))
                detailRow(
                    series.isOverdue() ? "Was due" : "Next expected",
                    series.nextExpectedDate.formatted(date: .abbreviated, time: .omitted)
                )
                detailRow("Accounts", series.accountNames.joined(separator: ", "))
                detailRow("Evidence", series.confidenceLabel.map { String(localized: $0) } ?? "Based on synced history")
                if let categoryName = series.categoryName {
                    detailRow("Category", categoryName)
                }
            }
        }
    }

    private func detailRow(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

private struct CommitmentEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let commitment: ConfirmedCommitment
    @State private var name: String
    @State private var amount: String
    @State private var cadence: RecurringCadence
    @State private var dueDate: Date
    @State private var state: CommitmentState
    @State private var scope: String
    @State private var errorMessage: String?

    init(commitment: ConfirmedCommitment) {
        self.commitment = commitment
        _name = State(initialValue: commitment.name)
        _amount = State(initialValue: MinorUnits.string(abs(commitment.amountMinorUnits), exponent: commitment.currency.exponent))
        _cadence = State(initialValue: commitment.cadence)
        _dueDate = State(initialValue: commitment.nextDueDate)
        _state = State(initialValue: commitment.state)
        _scope = State(initialValue: commitment.accountScope)
        _errorMessage = State(initialValue: nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
                TextField("Name", text: $name)
                TextField("Expected amount", text: $amount)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                Picker("Cadence", selection: $cadence) {
                    ForEach(RecurringCadence.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                DatePicker("Next due", selection: $dueDate, displayedComponents: .date)
                Picker("State", selection: $state) {
                    ForEach(CommitmentState.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                TextField("Account scope (optional)", text: $scope)
                Text("Forecasts use this saved amount and date. They do not move money or predict a bank's settlement time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Edit commitment")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let parsed = MinorUnits.parse(amount, exponent: commitment.currency.exponent), parsed > 0 else {
                            errorMessage = String(localized: "Enter a positive amount.")
                            return
                        }
                        commitment.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? commitment.name : name
                        commitment.amountMinorUnits = commitment.amountMinorUnits < 0 ? -abs(parsed) : abs(parsed)
                        commitment.cadenceRaw = cadence.rawValue; commitment.nextDueDate = dueDate; commitment.stateRaw = state.rawValue; commitment.accountScope = scope; commitment.modifiedAt = .now
                        do {
                            try modelContext.save()
                            dismiss()
                        } catch {
                            errorMessage = String(localized: "Couldn’t save this commitment. Try again.")
                        }
                    }
                }
            }
        }
    }
}
