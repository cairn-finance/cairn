import SwiftUI
import SwiftData
import CairnCore

/// Monthly category limits and actual spending for one account currency.
struct BudgetView: View {
    @Environment(AppModel.self) private var model
    @Query(filter: #Predicate<Account> { $0.isHidden == false }, sort: \Account.displayOrder)
    private var accounts: [Account]
    @Query(sort: [SortDescriptor(\CairnSchemaV2.Category.sortOrder), SortDescriptor(\CairnSchemaV2.Category.createdAt)])
    private var categories: [CairnSchemaV2.Category]
    @Query private var appSettings: [AppSettings]
    @Query private var savedSettings: [CategoryBudget]

    @State private var monthKey = BudgetCalculator.monthKey(for: .now)
    @State private var selectedCurrencyCode = ""
    @State private var transactions: [BudgetTransaction] = []
    @State private var reloadToken = 0
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var editTarget: BudgetLine?
    @State private var showingRecommendations = false

    private var currencies: [Currency] {
        var seen = Set<String>()
        return accounts.compactMap { account in
            guard seen.insert(account.currency.code).inserted else { return nil }
            return account.currency
        }.sorted { $0.code.localizedStandardCompare($1.code) == .orderedAscending }
    }

    private var defaultCurrency: Currency {
        let home = appSettings.first?.homeCurrencyCode ?? "USD"
        return currencies.first(where: { $0.code == home }) ?? currencies.first ?? .usd
    }

    private var currency: Currency {
        currencies.first(where: { $0.code == selectedCurrencyCode }) ?? defaultCurrency
    }

    private var budgetTimeZone: TimeZone {
        savedSettings
            .filter { $0.currencyCode == currency.code }
            .sorted {
                if $0.monthKey != $1.monthKey { return $0.monthKey < $1.monthKey }
                return $0.uuid.uuidString < $1.uuid.uuidString
            }
            .compactMap { TimeZone(identifier: $0.timeZoneIdentifier) }
            .first ?? .current
    }

    private var monthStart: Date {
        BudgetCalculator.startOfMonth(monthKey, timeZone: budgetTimeZone) ?? .now
    }

    private var displayMonthDate: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = budgetTimeZone
        return calendar.date(byAdding: .day, value: 14, to: monthStart) ?? monthStart
    }

    private var monthEnd: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = budgetTimeZone
        return calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
    }

    private var currencyAccounts: [Account] {
        accounts.filter { $0.currency.code == currency.code }
    }

    private var settingsValues: [BudgetSetting] {
        savedSettings.map {
            BudgetSetting(
                uuid: $0.uuid,
                categoryUUID: $0.categoryUUID,
                currency: $0.currency,
                monthKey: $0.monthKey,
                amountMinorUnits: $0.amountMinorUnits,
                isMonthOverride: $0.isMonthOverride,
                isEnabled: $0.isEnabled,
                timeZoneIdentifier: $0.timeZoneIdentifier,
                modifiedAt: $0.modifiedAt
            )
        }
    }

    private var categoryValues: [BudgetCategory] {
        categories.map {
            BudgetCategory(
                uuid: $0.uuid,
                name: $0.name,
                colorHex: $0.colorHex,
                symbolName: $0.symbolName,
                sortOrder: $0.sortOrder,
                isArchived: $0.isArchived
            )
        }
    }

    private var snapshot: BudgetSnapshot {
        BudgetCalculator.snapshot(
            transactions: transactions,
            categories: categoryValues,
            settings: settingsValues,
            monthKey: monthKey,
            currency: currency,
            timeZone: budgetTimeZone
        )
    }

    private var reloadKey: String {
        "\(reloadToken)-\(monthKey)-\(currency.code)-\(budgetTimeZone.identifier)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.l) {
                monthPicker
                if currencies.count > 1 {
                    currencyPicker
                }
                if monthKey == BudgetCalculator.monthKey(for: .now, timeZone: budgetTimeZone),
                   !currencyAccounts.isEmpty {
                    recommendationButton
                }
                if currencyAccounts.isEmpty {
                    GetStartedEmptyState(
                        systemImage: "chart.pie",
                        title: "No accounts in this currency",
                        message: "Add or unhide an account to plan spending in this currency."
                    )
                } else if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 28)
                } else if loadFailed {
                    GetStartedEmptyState(
                        systemImage: "exclamationmark.triangle",
                        title: "Spending unavailable",
                        message: "Cairn couldn't load this month's transactions. Try again.",
                        includesConnect: false
                    )
                    Button("Try again") { reloadToken &+= 1 }
                        .frame(maxWidth: .infinity)
                } else {
                    summaryCard(snapshot)
                    categoryList(snapshot)
                    if snapshot.unbudgetedMinorUnits != 0 {
                        unbudgetedCard(snapshot)
                    }
                }
            }
            .cairnScreen()
        }
        .cairnCanvas()
        .navigationTitle("Budget")
        .task {
            if selectedCurrencyCode.isEmpty {
                selectedCurrencyCode = defaultCurrency.code
                monthKey = BudgetCalculator.monthKey(for: .now, timeZone: budgetTimeZone)
            }
            for await _ in NotificationCenter.default.notifications(named: ModelContext.didSave) {
                reloadToken &+= 1
            }
        }
        .task(id: reloadKey) { await loadTransactions() }
        .onChange(of: selectedCurrencyCode) { _, _ in
            monthKey = BudgetCalculator.monthKey(for: .now, timeZone: budgetTimeZone)
        }
        .sheet(item: $editTarget) { line in
            BudgetLimitEditor(
                category: line.category,
                currency: currency,
                monthKey: monthKey,
                timeZoneIdentifier: budgetTimeZone.identifier,
                currentLimit: line.plannedMinorUnits,
                currentSetting: line.effectiveSetting
            )
            .cairnLockCover()
        }
        .sheet(isPresented: $showingRecommendations) {
            BudgetRecommendationsSheet(
                categories: categoryValues,
                settings: settingsValues,
                currency: currency,
                accountScopes: currencyAccounts.map { BudgetAccountScope(bankAccountID: $0.bankAccountID) },
                currentMonthKey: BudgetCalculator.monthKey(for: .now, timeZone: budgetTimeZone),
                timeZoneIdentifier: budgetTimeZone.identifier
            )
            .cairnLockCover()
        }
        .sensoryFeedback(.selection, trigger: monthKey)
    }

    private var recommendationButton: some View {
        Button { showingRecommendations = true } label: {
            Card(padding: 14) {
                HStack(spacing: 12) {
                    SettingsIcon(systemImage: "sparkles", tint: CairnTheme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Build a starting budget").font(.subheadline.weight(.semibold))
                        Text("Get limit suggestions from your recent spending.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var currencyPicker: some View {
        Picker("Currency", selection: $selectedCurrencyCode) {
            ForEach(currencies, id: \.code) { option in
                Text(option.isCustom ? (option.customName ?? option.customAbbreviation ?? "Custom") : option.code)
                    .tag(option.code)
            }
        }
        .pickerStyle(.menu)
        .accessibilityLabel("Budget currency")
    }

    private var monthPicker: some View {
        HStack {
            Button {
                if let previous = BudgetCalculator.shiftMonth(monthKey, by: -1, timeZone: budgetTimeZone) {
                    monthKey = previous
                }
            } label: {
                Image(systemName: "chevron.left").frame(width: 36, height: 36)
            }
            .accessibilityLabel("Previous month")

            Spacer()
            Text(displayMonthDate.formatted(.dateTime.month(.wide).year()))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()

            Button {
                if let next = BudgetCalculator.shiftMonth(monthKey, by: 1, timeZone: budgetTimeZone) {
                    monthKey = next
                }
            } label: {
                Image(systemName: "chevron.right").frame(width: 36, height: 36)
            }
            .accessibilityLabel("Next month")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    private func summaryCard(_ data: BudgetSnapshot) -> some View {
        Card {
            let hasLimits = data.lines.contains { $0.plannedMinorUnits != nil }
            let displayedSpent = hasLimits ? data.budgetedSpentMinorUnits : data.spentMinorUnits
            let remaining = Money(minorUnits: data.remainingMinorUnits, currency: data.currency).formatted()
            let allSpent = Money(minorUnits: data.spentMinorUnits, currency: data.currency).formatted()
            VStack(alignment: .leading, spacing: 12) {
                Text(hasLimits ? "Spent in planned categories" : "Spent this month")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline) {
                    AmountText(
                        money: Money(minorUnits: displayedSpent, currency: data.currency),
                        font: .cairnDisplay
                    )
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        if hasLimits {
                            Text("of \(Money(minorUnits: data.plannedMinorUnits, currency: data.currency).formatted()) planned")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            AmountText(
                                money: Money(minorUnits: data.remainingMinorUnits, currency: data.currency),
                                font: .subheadline.weight(.semibold),
                                colorOverride: data.remainingMinorUnits < 0 ? CairnTheme.warning : CairnTheme.positive
                            )
                            .accessibilityLabel("\(remaining) remaining in planned categories")
                        } else {
                            Text("No limits set")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !hasLimits {
                    Text("Set category limits to make a monthly plan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if data.plannedMinorUnits > 0 {
                    ProgressView(value: min(1, max(0, Double(data.budgetedSpentMinorUnits) / Double(data.plannedMinorUnits))))
                        .tint(data.remainingMinorUnits < 0 ? CairnTheme.warning : CairnTheme.accent)
                        .accessibilityLabel("Monthly budget progress")
                }
                if hasLimits {
                    Text("\(allSpent) spent across all categories this month")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func categoryList(_ data: BudgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Categories")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 4)
            ForEach(data.lines) { line in
                categoryRow(line, month: displayMonthDate, currency: data.currency)
            }
        }
    }

    private func categoryRow(_ line: BudgetLine, month: Date, currency: Currency) -> some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    NavigationLink {
                        InsightFilteredListView(
                            title: line.category.name,
                            emptyMessage: "No transactions in this category for this month.",
                            currency: currency,
                            scope: .budgetCategory(
                                name: line.category.name,
                                month: month,
                                currencyCode: currency.code,
                                timeZoneIdentifier: budgetTimeZone.identifier
                            )
                        )
                    } label: {
                        HStack(spacing: 10) {
                            CategoryBadge(symbolName: line.category.symbolName, hex: line.category.colorHex, size: 34)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 5) {
                                    Text(line.category.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    if line.category.isArchived {
                                        Text("Hidden").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Text(categoryDetail(line, currency: currency))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 2)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        editTarget = line
                    } label: {
                        Text(line.plannedMinorUnits == nil ? "Set" : "Edit")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(CairnTheme.surfaceInset, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit \(line.category.name) limit")
                }
                if let limit = line.plannedMinorUnits, limit > 0 {
                    ProgressView(value: min(1, max(0, Double(line.spentMinorUnits) / Double(limit))))
                        .tint((line.remainingMinorUnits ?? 0) < 0 ? CairnTheme.warning : CairnTheme.accent)
                        .padding(.leading, 44)
                        .accessibilityLabel("\(line.category.name) budget progress")
                }
            }
        }
    }

    private func categoryDetail(_ line: BudgetLine, currency: Currency) -> String {
        let spent = Money(minorUnits: line.spentMinorUnits, currency: currency).formatted()
        guard let limit = line.plannedMinorUnits else { return "\(spent) spent · No limit" }
        let remaining = Money(minorUnits: line.remainingMinorUnits ?? 0, currency: currency).formatted()
        return "\(spent) spent · \(remaining) remaining of \(Money(minorUnits: limit, currency: currency).formatted())"
    }

    private func unbudgetedCard(_ data: BudgetSnapshot) -> some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Unbudgeted spending").font(.subheadline.weight(.semibold))
                    Text("Includes uncategorized transactions and categories without a limit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                AmountText(money: Money(minorUnits: data.unbudgetedMinorUnits, currency: data.currency), font: .subheadline)
            }
        }
    }

    private func loadTransactions() async {
        guard !currencyAccounts.isEmpty,
              let start = BudgetCalculator.startOfMonth(monthKey, timeZone: budgetTimeZone) else {
            transactions = []
            loadFailed = false
            isLoading = false
            return
        }
        isLoading = true
        loadFailed = false
        let scopes = currencyAccounts.map { BudgetAccountScope(bankAccountID: $0.bankAccountID) }
        let container = model.container
        let fetcher = await Task.detached(priority: .utility) {
            BudgetFetcher(modelContainer: container)
        }.value
        do {
            let fetched = try await fetcher.budgetTransactions(scopes: scopes, from: start, to: monthEnd)
            guard !Task.isCancelled else { return }
            transactions = fetched
        } catch {
            guard !Task.isCancelled else { return }
            transactions = []
            loadFailed = true
        }
        isLoading = false
    }
}

private struct BudgetLimitEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let category: BudgetCategory
    let currency: Currency
    let monthKey: String
    let timeZoneIdentifier: String
    let currentLimit: Int64?
    let currentSetting: BudgetSetting?

    @State private var amountText = ""
    @State private var scope: LimitScope = .fromMonth
    @State private var isSaving = false
    @State private var showingRemoveConfirmation = false
    @FocusState private var amountIsFocused: Bool

    private enum LimitScope: Hashable {
        case monthOnly
        case fromMonth

        var isMonthOverride: Bool { self == .monthOnly }
    }

    private var currencyLabel: String {
        currency.isCustom ? (currency.customAbbreviation ?? currency.customName ?? currency.code) : currency.code
    }

    private var monthLabel: String {
        let timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        guard let start = BudgetCalculator.startOfMonth(monthKey, timeZone: timeZone) else { return monthKey }
        return start.addingTimeInterval(14 * 24 * 60 * 60).formatted(.dateTime.month(.wide).year())
    }

    private var validAmount: Int64? {
        guard let amount = MinorUnits.parse(amountText, exponent: currency.exponent), amount > 0 else { return nil }
        return amount
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        CategoryBadge(symbolName: category.symbolName, hex: category.colorHex, size: 40)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(category.name)
                                .font(.title3.weight(.semibold))
                            Text("Monthly category limit")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 4)

                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Amount")
                                .font(.subheadline.weight(.semibold))
                            HStack(spacing: 10) {
                                Text(currencyLabel)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                TextField("0.00", text: $amountText)
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 180)
                                    .focused($amountIsFocused)
                                    #if os(iOS)
                                    .keyboardType(.decimalPad)
                                    #endif
                                    .accessibilityLabel("Monthly category limit")
                            }
                            Text(category.isArchived
                                 ? "Unhide this category before setting a new limit."
                                 : "Choose the amount you want to spend in this category each month.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Applies to")
                                .font(.subheadline.weight(.semibold))
                            scopeRow(.monthOnly, title: "Only \(monthLabel)")
                            Divider()
                            scopeRow(.fromMonth, title: "\(monthLabel) onward")
                            Text(scope == .monthOnly
                                 ? "A recurring limit, if set, applies again next month."
                                 : "This becomes the recurring limit. Existing exceptions in later months remain in place.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let currentLimit {
                        let formattedLimit = Money(minorUnits: currentLimit, currency: currency).formatted()
                        let limitScope = currentSetting?.isMonthOverride == true ? "for this month" : "recurring"
                        Card {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Current limit: \(formattedLimit) \(limitScope).")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("Remove limit", role: .destructive) {
                                    showingRemoveConfirmation = true
                                }
                                .disabled(isSaving)
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(currentLimit == nil ? "Set limit" : "Edit limit")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save limit") { save(isEnabled: true) }
                        .disabled(isSaving || category.isArchived || validAmount == nil)
                }
            }
            .onAppear {
                scope = currentSetting?.isMonthOverride == true ? .monthOnly : .fromMonth
                if let currentLimit {
                    amountText = MinorUnits.string(currentLimit, exponent: currency.exponent)
                } else {
                    amountIsFocused = true
                }
            }
            .confirmationDialog("Remove \(category.name) limit?", isPresented: $showingRemoveConfirmation) {
                Button(
                    scope == .monthOnly ? "Remove for \(monthLabel)" : "Remove from \(monthLabel) onward",
                    role: .destructive
                ) {
                    save(isEnabled: false)
                }
            } message: {
                Text(scope == .monthOnly
                     ? "The recurring limit will apply again next month."
                     : "This removes the recurring limit from \(monthLabel). Later exceptions remain in place.")
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 480)
        #endif
    }

    private func scopeRow(_ option: LimitScope, title: String) -> some View {
        Button {
            scope = option
        } label: {
            HStack(spacing: 12) {
                Image(systemName: scope == option ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(scope == option ? CairnTheme.accent : Color.secondary)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(scope == option ? "Selected" : "Not selected")
    }

    private func save(isEnabled: Bool) {
        guard !isSaving else { return }
        let amount: Int64
        if isEnabled {
            guard let validAmount else { return }
            amount = validAmount
        } else {
            amount = 0
        }
        isSaving = true
        Task {
            let saved = await model.setBudgetLimit(
                categoryUUID: category.uuid,
                currency: currency,
                monthKey: monthKey,
                amountMinorUnits: amount,
                isMonthOverride: scope.isMonthOverride,
                isEnabled: isEnabled,
                timeZoneIdentifier: timeZoneIdentifier
            )
            isSaving = false
            if saved { dismiss() }
        }
    }
}
