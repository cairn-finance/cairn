import SwiftUI
import CairnCore

/// Reviews on-device recommendations before adding recurring category limits.
struct BudgetRecommendationsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let categories: [BudgetCategory]
    let settings: [BudgetSetting]
    let currency: Currency
    let accountScopes: [BudgetAccountScope]
    let currentMonthKey: String
    let timeZoneIdentifier: String

    @State private var recommendations: [BudgetRecommendation] = []
    @State private var selectedCategoryIDs: Set<UUID> = []
    @State private var explanationRecommendation: BudgetRecommendation?
    @State private var amountTexts: [UUID: String] = [:]
    @State private var isLoading = true
    @State private var isApplying = false
    @State private var loadFailed = false
    @State private var reloadToken = 0

    private var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? .current
    }

    private var monthKeys: [String] {
        BudgetCalculator.completedMonthKeys(
            before: currentMonthKey,
            count: 6,
            timeZone: timeZone
        )
    }

    private var validSelections: [BudgetLimitSelection] {
        recommendations.compactMap { recommendation in
            guard selectedCategoryIDs.contains(recommendation.id),
                  let text = amountTexts[recommendation.id],
                  let amount = MinorUnits.parse(text, exponent: currency.exponent),
                  amount > 0 else { return nil }
            return BudgetLimitSelection(categoryUUID: recommendation.id, amountMinorUnits: amount)
        }
    }

    private var canApply: Bool {
        !isLoading
            && !isApplying
            && !selectedCategoryIDs.isEmpty
            && validSelections.count == selectedCategoryIDs.count
    }

    private var selectedTotal: Int64 {
        validSelections.reduce(Int64(0)) {
            MinorUnits.addClamped($0, $1.amountMinorUnits)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Reviewing recent spending…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if loadFailed {
                    VStack(spacing: 16) {
                        GetStartedEmptyState(
                            systemImage: "exclamationmark.triangle",
                            title: "Suggestions unavailable",
                            message: "Cairn couldn't load recent transactions. Try again.",
                            includesConnect: false
                        )
                        Button("Try again") { reloadToken &+= 1 }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else if recommendations.isEmpty {
                    GetStartedEmptyState(
                        systemImage: "chart.pie",
                        title: "No suggestions yet",
                        message: "No unbudgeted category has enough spending history yet. Cairn needs net spending in at least three of the last six complete months.",
                        includesConnect: false
                    )
                    .padding()
                } else {
                    recommendationsContent
                }
            }
            .navigationTitle("Starting budget")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        applySelected()
                    } label: {
                        if isApplying {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Add selected")
                        }
                    }
                    .disabled(!canApply)
                }
            }
            .task(id: reloadToken) { await loadRecommendations() }
            .sheet(item: $explanationRecommendation) { recommendation in
                BudgetRecommendationDetail(
                    recommendation: recommendation,
                    currency: currency,
                    timeZoneIdentifier: timeZoneIdentifier
                )
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 540)
        #endif
    }

    private var recommendationsContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your starting plan")
                            .font(.headline)
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(selectedCategoryIDs.count) categories selected")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(Money(minorUnits: selectedTotal, currency: currency).formatted())
                                .font(.title3.weight(.semibold).monospacedDigit())
                        }
                        Text("These monthly limits start now and repeat. Adjust each amount before adding them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(recommendations) { recommendation in
                    recommendationRow(recommendation)
                }
                Text("Suggestions use six complete months of spending history on this device. Months without spending are shown in each category's explanation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding()
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
    }

    private var currencyLabel: String {
        currency.isCustom ? (currency.customAbbreviation ?? currency.customName ?? currency.code) : currency.code
    }

    private func recommendationRow(_ recommendation: BudgetRecommendation) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: selectionBinding(for: recommendation.id)) {
                    HStack(spacing: 10) {
                        CategoryBadge(
                            symbolName: recommendation.category.symbolName,
                            hex: recommendation.category.colorHex,
                            size: 32
                        )
                        VStack(alignment: .leading, spacing: 3) {
                            Text(recommendation.category.name)
                                .font(.subheadline.weight(.semibold))
                            Text("Spending in \(recommendation.monthsWithSpending) of \(recommendation.monthsSampled) months")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Text("Monthly limit")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(currencyLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Amount", text: amountBinding(for: recommendation))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .accessibilityLabel("\(recommendation.category.name) suggested monthly limit")
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                        .disabled(!selectedCategoryIDs.contains(recommendation.id))
                }

                Divider()
                Button {
                    explanationRecommendation = recommendation
                } label: {
                    HStack(spacing: 8) {
                        Label("Why this amount?", systemImage: "chart.bar.fill")
                            .font(.subheadline.weight(.medium))
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Why \(recommendation.category.name) has a suggested limit of \(Money(minorUnits: recommendation.suggestedLimitMinorUnits, currency: currency).formatted())")
            }
        }
    }

    private func selectionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedCategoryIDs.contains(id) },
            set: { isSelected in
                if isSelected {
                    selectedCategoryIDs.insert(id)
                } else {
                    selectedCategoryIDs.remove(id)
                }
            }
        )
    }

    private func amountBinding(for recommendation: BudgetRecommendation) -> Binding<String> {
        Binding(
            get: { amountTexts[recommendation.id] ?? MinorUnits.string(recommendation.suggestedLimitMinorUnits, exponent: currency.exponent) },
            set: { amountTexts[recommendation.id] = $0 }
        )
    }

    private func loadRecommendations() async {
        isLoading = true
        loadFailed = false
        guard let firstMonth = monthKeys.first,
              let start = BudgetCalculator.startOfMonth(firstMonth, timeZone: timeZone),
              let end = BudgetCalculator.startOfMonth(currentMonthKey, timeZone: timeZone),
              !accountScopes.isEmpty else {
            isLoading = false
            return
        }

        let container = model.container
        let fetcher = await Task.detached(priority: .utility) {
            BudgetFetcher(modelContainer: container)
        }.value
        let transactions: [BudgetTransaction]
        do {
            transactions = try await fetcher.budgetTransactions(scopes: accountScopes, from: start, to: end)
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = true
            isLoading = false
            return
        }
        guard !Task.isCancelled else { return }

        let alreadyConfigured = Set(BudgetCalculator.effectiveSettings(
            settings, monthKey: currentMonthKey, currency: currency
        ).values.filter(\.isEnabled).map(\.categoryUUID))
        recommendations = BudgetCalculator.recommendations(
            transactions: transactions,
            categories: categories.filter { !alreadyConfigured.contains($0.uuid) },
            currency: currency,
            monthKeys: monthKeys,
            minimumActiveMonths: 3,
            timeZone: timeZone
        )
        selectedCategoryIDs = Set(recommendations.map(\.id))
        amountTexts = Dictionary(uniqueKeysWithValues: recommendations.map {
            ($0.id, MinorUnits.string($0.suggestedLimitMinorUnits, exponent: currency.exponent))
        })
        isLoading = false
    }

    private func applySelected() {
        guard canApply else { return }
        isApplying = true
        Task {
            let saved = await model.applyBudgetRecommendations(
                validSelections,
                currency: currency,
                monthKey: currentMonthKey,
                timeZoneIdentifier: timeZoneIdentifier
            )
            isApplying = false
            if saved { dismiss() }
        }
    }
}

private struct BudgetRecommendationDetail: View {
    @Environment(\.dismiss) private var dismiss

    let recommendation: BudgetRecommendation
    let currency: Currency
    let timeZoneIdentifier: String

    private var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? .current
    }

    private func title(for monthKey: String) -> String {
        guard let start = BudgetCalculator.startOfMonth(monthKey, timeZone: timeZone) else { return monthKey }
        return start.addingTimeInterval(14 * 24 * 60 * 60).formatted(.dateTime.month(.wide).year())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Suggested monthly limit")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(Money(minorUnits: recommendation.suggestedLimitMinorUnits, currency: currency).formatted())
                                .font(.cairnDisplay)
                            Text("Median spending was \(Money(minorUnits: recommendation.typicalActiveMonthMinorUnits, currency: currency).formatted()) across \(recommendation.monthsWithSpending) months with net spending. The limit rounds that up to the next five currency units.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("Last six complete months")
                        .font(.headline)
                        .padding(.horizontal, 4)

                    Card {
                        VStack(spacing: 0) {
                            ForEach(recommendation.monthlySpending.reversed()) { month in
                                HStack(spacing: 12) {
                                    Text(title(for: month.monthKey))
                                        .font(.subheadline)
                                    Spacer()
                                    if month.amountMinorUnits == 0 {
                                        Text("No net spending")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        if month.amountMinorUnits > MinorUnits.multiplyClamped(recommendation.typicalActiveMonthMinorUnits, 2) {
                                            Text("Higher than typical")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(Money(minorUnits: month.amountMinorUnits, currency: currency).formatted())
                                            .font(.subheadline.monospacedDigit())
                                    }
                                }
                                .padding(.vertical, 10)
                                .accessibilityElement(children: .combine)
                                if month.id != recommendation.monthlySpending.first?.id {
                                    Divider()
                                }
                            }
                        }
                    }

                    Text("Months with no net spending are shown for context. The median uses months with spending, so one unusually expensive month has less influence on the suggestion.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .padding()
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(recommendation.category.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 540)
        #endif
    }
}
