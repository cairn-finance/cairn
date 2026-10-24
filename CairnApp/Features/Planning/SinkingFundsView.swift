import SwiftUI
import SwiftData
import CairnCore

struct SinkingFundsView: View {
    @Query(sort: \SinkingFund.name) private var funds: [SinkingFund]
    @Query private var entries: [SinkingFundEntry]
    @State private var showingAdd = false
    @State private var showsArchived = false

    private var visibleFunds: [SinkingFund] { funds.filter { showsArchived || $0.stateRaw != "archived" } }
    private var currencies: [Currency] {
        Set(funds.filter { $0.stateRaw != "archived" }.compactMap { try? $0.input.currency })
            .sorted { $0.stableIdentifier < $1.stableIdentifier }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.xl) {
                if visibleFunds.isEmpty {
                    EmptyStateView(
                        systemImage: "tray.and.arrow.down", title: "Make room for what's ahead",
                        message: "Set money aside for insurance, a holiday, repairs, or another future expense.",
                        actionTitle: "Add sinking fund"
                    ) { showingAdd = true }
                } else {
                    DashboardGrid(minimumColumnWidth: 340) {
                        ForEach(currencies, id: \.self) { currency in summaryCard(currency) }
                    }
                    ScreenSectionHeader("Your funds")
                    DashboardGrid(minimumColumnWidth: 300) {
                        ForEach(visibleFunds) { fund in
                            NavigationLink { SinkingFundDetail(fundID: fund.uuid) } label: { fundCard(fund) }
                                .buttonStyle(.pressableCard)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(fund.name)
                                .accessibilityValue(fundAccessibilityValue(fund))
                                .accessibilityHint("Shows fund progress and allocation history")
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                    FootnoteText("Allocations track your plans without moving money or changing account balances or spending.")
                }
            }
            .cairnScreen(maxWidth: CairnTheme.dashboardMaxWidth)
        }
        .cairnScrollEdge().cairnCanvas()
        .navigationTitle("Sinking funds")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add sinking fund", systemImage: "plus") { showingAdd = true }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu { Toggle("Show archived funds", isOn: $showsArchived) } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Sinking fund options")
            }
        }
        .sheet(isPresented: $showingAdd) { SinkingFundEditor().cairnLockCover() }
    }

    @ViewBuilder
    private func summaryCard(_ currency: Currency) -> some View {
        if let totals = totals(currency) {
            HeroCard {
                VStack(alignment: .leading, spacing: CairnTheme.Spacing.l) {
                    HStack {
                        Text("Set aside").font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.75))
                        Spacer()
                        Text(currency.displayLabel).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.65))
                    }
                    AmountText(money: Money(minorUnits: totals.funded, currency: currency),
                               font: .cairnHero, colorOverride: .white, deemphasizeFraction: true)
                    Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
                    HStack {
                        Text("Monthly plan").font(.subheadline).foregroundStyle(.white.opacity(0.7))
                        Spacer()
                        AmountText(money: Money(minorUnits: totals.monthly, currency: currency),
                                   font: .headline, colorOverride: .white)
                    }
                }
            }
        } else { Card { FootnoteText("Fund totals unavailable") } }
    }

    private func totals(_ currency: Currency) -> (funded: Int64, monthly: Int64)? {
        var funded: Int64 = 0
        var monthly: Int64 = 0
        for fund in funds where fund.stateRaw != "archived" {
            guard let input = try? fund.input, input.currency == currency else { continue }
            guard let history = try? entries.filter({ $0.fundID == input.uuid }).map({ try $0.input }),
                  let summary = try? SinkingFundCalculator.summary(for: input, entries: history) else { return nil }
            funded = MinorUnits.addClamped(funded, summary.fundedMinorUnits)
            if input.state == .active { monthly = MinorUnits.addClamped(monthly, input.monthlyContributionMinorUnits) }
        }
        return (funded, monthly)
    }

    private func fundCard(_ fund: SinkingFund) -> some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.l) {
                HStack(spacing: CairnTheme.Spacing.m) {
                    TrackingSymbol(name: "tray.and.arrow.down")
                    Text(fund.name).font(.headline).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                if let input = try? fund.input,
                   let history = try? entries.filter({ $0.fundID == input.uuid }).map({ try $0.input }),
                   let summary = try? SinkingFundCalculator.summary(for: input, entries: history) {
                    AmountText(money: Money(minorUnits: summary.fundedMinorUnits, currency: input.currency), font: .cairnDisplay)
                    ProgressView(value: min(1, summary.progress)).tint(CairnTheme.accent)
                        .accessibilityLabel("Fund progress")
                        .accessibilityValue(summary.progress.formatted(.percent.precision(.fractionLength(0))))
                    HStack(alignment: .firstTextBaseline) {
                        Text("of \(Money(minorUnits: input.targetMinorUnits, currency: input.currency).formatted())")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: CairnTheme.Spacing.s)
                        if input.state != .active { Text(input.state.title).font(.caption).foregroundStyle(.secondary) }
                        else if let target = input.targetDate {
                            Text(target, format: .dateTime.month().day()).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else { FootnoteText("Fund totals unavailable") }
            }
        }
    }

    private func fundAccessibilityValue(_ fund: SinkingFund) -> Text {
        guard let input = try? fund.input,
              let history = try? entries.filter({ $0.fundID == input.uuid }).map({ try $0.input }),
              let summary = try? SinkingFundCalculator.summary(for: input, entries: history) else {
            return Text("Fund totals unavailable")
        }
        let funded = Money(minorUnits: summary.fundedMinorUnits, currency: input.currency).formatted()
        let target = Money(minorUnits: input.targetMinorUnits, currency: input.currency).formatted()
        return Text("\(funded) set aside toward \(target)")
    }
}

struct SinkingFundDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Query private var funds: [SinkingFund]
    @Query(sort: \SinkingFundEntry.date, order: .reverse) private var allEntries: [SinkingFundEntry]
    let fundID: UUID
    @State private var showingEdit = false
    @State private var showingEntry = false
    @State private var showingDelete = false
    @State private var deletingEntry: UUID?
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(fundID: UUID) {
        self.fundID = fundID
        _funds = Query(filter: #Predicate { $0.uuid == fundID })
    }

    private var entries: [SinkingFundEntry] { allEntries.filter { $0.fundID == fundID } }

    var body: some View {
        Group {
            if let fund = funds.first, let input = try? fund.input { detail(input) }
            else { ContentUnavailableView("Fund unavailable", systemImage: "tray.and.arrow.down") }
        }
        .navigationTitle("Sinking fund")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("Couldn't save changes", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
        .confirmationDialog("Delete this sinking fund?", isPresented: $showingDelete) {
            Button("Delete fund", role: .destructive) {
                perform { try await model.engine.deleteSinkingFund(fundID); dismiss() }
            }
        } message: { Text("Its allocation history will also be removed. Account transactions are kept.") }
        .confirmationDialog("Delete this allocation?", isPresented: Binding(
            get: { deletingEntry != nil }, set: { if !$0 { deletingEntry = nil } }
        )) {
            Button("Delete allocation", role: .destructive) {
                if let id = deletingEntry { perform { try await model.engine.deleteSinkingFundEntry(id) } }
                deletingEntry = nil
            }
        }
    }

    private func detail(_ input: SinkingFundInput) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.xl) {
                if let values = try? entries.map({ try $0.input }),
                   let summary = try? SinkingFundCalculator.summary(for: input, entries: values) {
                    hero(input, summary: summary)
                    if input.state == .active || input.state == .paused {
                        Button { showingEntry = true } label: { Label("Record allocation", systemImage: "plus") }
                            .buttonStyle(.cairnProminent).disabled(isSaving)
                    }
                    planCard(input, summary: summary)
                } else {
                    Card { FootnoteText("Fund totals unavailable. Review the allocation history.") }
                }
                historySection(input)
                if !input.note.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: CairnTheme.Spacing.m) {
                            CardHeader("Note")
                            Text(input.note).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                FootnoteText("Record a withdrawal when you spend from a fund. The purchase stays in account spending.")
            }
            .cairnScreen()
        }
        .cairnScrollEdge().cairnCanvas()
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("Edit") { showingEdit = true }.disabled(isSaving) }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Delete fund", systemImage: "trash", role: .destructive) { showingDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Sinking fund options").disabled(isSaving)
            }
        }
        .sheet(isPresented: $showingEdit) {
            SinkingFundEditor(existing: input, hasEntries: !entries.isEmpty).cairnLockCover()
        }
        .sheet(isPresented: $showingEntry) { SinkingFundEntryEditor(fund: input).cairnLockCover() }
    }

    private func hero(_ input: SinkingFundInput, summary: SinkingFundSummary) -> some View {
        HeroCard {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.l) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: CairnTheme.Spacing.xs) {
                        Text(input.name).font(.title3.weight(.semibold))
                        Text(input.state.title).font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    Image(systemName: "tray.and.arrow.down").font(.title2).foregroundStyle(CairnTheme.inkGlow)
                        .accessibilityHidden(true)
                }
                AmountText(money: Money(minorUnits: summary.fundedMinorUnits, currency: input.currency),
                           font: .cairnHero, colorOverride: .white, deemphasizeFraction: true)
                Text("of \(Money(minorUnits: input.targetMinorUnits, currency: input.currency).formatted()) set aside")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.75))
                ProgressView(value: min(1, summary.progress)).tint(CairnTheme.inkGlow)
                    .accessibilityLabel("Fund progress")
                    .accessibilityValue(summary.progress.formatted(.percent.precision(.fractionLength(0))))
                HStack {
                    Text("Remaining").foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    AmountText(money: Money(minorUnits: summary.remainingMinorUnits, currency: input.currency),
                               font: .subheadline.weight(.semibold), colorOverride: .white)
                }
                .font(.subheadline)
            }
        }
    }

    private func planCard(_ input: SinkingFundInput, summary: SinkingFundSummary) -> some View {
        Card {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.l) {
                CardHeader("Contribution plan")
                HStack(alignment: .top, spacing: CairnTheme.Spacing.l) {
                    Metric(title: "Monthly plan",
                           money: Money(minorUnits: input.monthlyContributionMinorUnits, currency: input.currency))
                    Metric(title: "This month",
                           money: Money(minorUnits: summary.contributedThisMonthMinorUnits, currency: input.currency))
                }
                if let target = input.targetDate {
                    Divider()
                    TrackingDetailRow(title: "Target date", value: target.formatted(date: .abbreviated, time: .omitted))
                }
                if let suggested = summary.suggestedMonthlyMinorUnits {
                    TrackingDetailRow(title: "Suggested per month", value: money(suggested, input.currency))
                }
                FootnoteText("Plans are not recorded automatically.")
            }
        }
    }

    private func historySection(_ input: SinkingFundInput) -> some View {
        VStack(alignment: .leading, spacing: CairnTheme.Spacing.s) {
            SectionLabel(title: "Allocation history")
            if entries.isEmpty {
                Card { Text("No allocations recorded").font(.subheadline).foregroundStyle(.secondary) }
            } else {
                RowGroup {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: CairnTheme.Spacing.s) {
                            HStack(spacing: CairnTheme.Spacing.m) {
                                TrackingSymbol(name: entry.amountMinorUnits < 0 ? "arrow.up.right" : "arrow.down.left", size: 36)
                                VStack(alignment: .leading, spacing: CairnTheme.Spacing.xs) {
                                    Text(SinkingFundEntryKind(rawValue: entry.kindRaw)?.title ?? "Allocation")
                                        .font(.body.weight(.medium))
                                    Text(entry.date, format: .dateTime.month().day().year())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                AmountText(money: Money(minorUnits: entry.amountMinorUnits, currency: input.currency),
                                           showSign: true, font: .body.weight(.semibold))
                                Menu {
                                    Button("Delete allocation", systemImage: "trash", role: .destructive) {
                                        deletingEntry = entry.uuid
                                    }
                                } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
                                .buttonStyle(.plain).accessibilityLabel("Allocation options").disabled(isSaving)
                            }
                            if !entry.note.isEmpty { Text(entry.note).font(.subheadline).foregroundStyle(.secondary) }
                        }
                        .padding(CairnTheme.Spacing.l)
                        if entry.uuid != entries.last?.uuid { RowDivider() }
                    }
                }
            }
        }
    }

    private func money(_ amount: Int64, _ currency: Currency) -> String {
        Money(minorUnits: amount, currency: currency).formatted()
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
