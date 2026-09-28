import SwiftUI
import SwiftData
import CairnCore

/// The person's rules, in priority order. Matching actions combine, while a
/// higher rule wins conflicts and manual category choices remain untouched.
struct RulesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var modelContext
    @Query private var settings: [AppSettings]
    @Query(
        sort: [
            SortDescriptor(\CategorizationRule.priority, order: .reverse),
            SortDescriptor(\CategorizationRule.createdAt),
        ]
    )
    private var rules: [CategorizationRule]

    @State private var editorTarget: EditorTarget?

    /// One sheet serves both create and edit.
    private enum EditorTarget: Identifiable {
        case create
        case edit(CategorizationRule)

        var id: String {
            switch self {
            case .create: "create"
            case let .edit(rule): "edit-\(rule.uuid.uuidString)"
            }
        }
    }

    private var homeCurrency: Currency { NetWorthMath.homeCurrency(settings: settings) }

    var body: some View {
        List {
            if rules.isEmpty {
                Section {
                    EmptyStateView(
                        systemImage: "slider.horizontal.3",
                        title: "No rules yet",
                        message: "Match bank descriptions or amounts to set categories, names, tags, or compact rows.",
                        actionTitle: "New Rule"
                    ) {
                        editorTarget = .create
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(rules) { rule in
                        row(rule)
                    }
                    .onDelete(perform: delete)
                    .onMove(perform: move)
                } footer: {
                    Text("Drag to reorder. Matching rules combine; higher rules win conflicting actions.")
                }
            }
        }
        .cairnListStyle()
        .navigationTitle("Rules")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editorTarget = .create
                } label: {
                    Label("New Rule", systemImage: "plus")
                }
            }
            #if os(iOS)
            if !rules.isEmpty {
                ToolbarItem(placement: .secondaryAction) {
                    EditButton()
                }
            }
            #endif
        }
        .sheet(item: $editorTarget) { target in
            Group {
                switch target {
                case .create:
                    RuleEditorView()
                case let .edit(rule):
                    RuleEditorView(rule: rule)
                }
            }
            .cairnLockCover()
        }
    }

    // MARK: - Rows

    private func row(_ rule: CategorizationRule) -> some View {
        HStack(spacing: 12) {
            Button {
                editorTarget = .edit(rule)
            } label: {
                HStack(spacing: 12) {
                    CategoryBadge(
                        symbolName: rule.assignedCategory?.symbolName,
                        hex: rule.assignedCategory?.colorHex,
                        size: 36
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ruleTitle(rule))
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        Text(Self.summary(for: rule, currency: homeCurrency))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("", isOn: enabledBinding(rule))
                .labelsHidden()
                .accessibilityLabel(Text(verbatim: ruleTitle(rule)))
        }
    }

    private func ruleTitle(_ rule: CategorizationRule) -> String {
        if !rule.name.isEmpty { return rule.name }
        if let category = rule.assignedCategory { return category.name }
        return "Rule"
    }

    private func enabledBinding(_ rule: CategorizationRule) -> Binding<Bool> {
        Binding(
            get: { rule.isEnabled },
            set: { newValue in
                rule.isEnabled = newValue
                try? modelContext.save()
                Task { await model.applyRules() }
            }
        )
    }

    // MARK: - Editing

    private func delete(_ offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(rules[index])
        }
        try? modelContext.save()
        Task { await model.applyRules() }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ordered = rules
        ordered.move(fromOffsets: source, toOffset: destination)
        // Highest priority first, so the row at the top is checked first.
        for (index, rule) in ordered.enumerated() {
            rule.priority = ordered.count - index
        }
        try? modelContext.save()
        Task { await model.applyRules() }
    }

    /// A short, human-readable version of a rule's condition.
    static func summary(for rule: CategorizationRule, currency: Currency) -> String {
        var parts: [String] = []
        let field = RuleField(rawValue: rule.fieldRaw) ?? .payee
        if field == .payee {
            let kind = RuleMatchKind(rawValue: rule.matchKindRaw) ?? .contains
            let pattern = rule.pattern.isEmpty ? "anything" : "“\(rule.pattern)”"
            parts.append("Description \(kind.displayName.lowercased()) \(pattern)")
        } else {
            parts.append("Amount")
        }
        if rule.minAmountMinorUnits != nil || rule.maxAmountMinorUnits != nil {
            let min = rule.minAmountMinorUnits.map { ruleAmount($0, currency: currency) } ?? "…"
            let max = rule.maxAmountMinorUnits.map { ruleAmount($0, currency: currency) } ?? "…"
            parts.append("\(min) to \(max)")
        }
        var actions: [String] = []
        if let category = rule.assignedCategory { actions.append(category.name) }
        if let displayName = rule.displayNameTemplate, !displayName.isEmpty {
            actions.append("Name: \(displayName)")
        }
        if let tags = rule.appliedTags, !tags.isEmpty {
            actions.append(String(localized: "^[\(tags.count) tag](inflect: true)"))
        }
        if rule.makesCompact { actions.append("Compact") }
        return parts.joined(separator: " · ") + " → " + actions.joined(separator: " · ")
    }

    /// Rules compare raw minor units at two decimal places, independent of the
    /// account's currency, so format them the same way for a stable display.
    static func ruleAmount(_ minorUnits: Int64, currency: Currency) -> String {
        Money(minorUnits: minorUnits, currency: Currency(code: currency.code, exponent: 2)).formatted()
    }
}

// MARK: - Editor

/// Creates or edits one rule, with a live preview of how many existing
/// transactions it would match.
struct RuleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var model
    @Query(
        sort: [
            SortDescriptor(\CairnSchemaV4.Category.sortOrder),
            SortDescriptor(\CairnSchemaV4.Category.createdAt),
        ]
    ) private var categories: [CairnSchemaV4.Category]
    @Query private var allTransactions: [LedgerTransaction]
    @Query private var settings: [AppSettings]
    @Query(sort: \Tag.name) private var allTags: [Tag]

    /// When set, the editor edits this rule instead of creating one.
    var rule: CategorizationRule?
    /// Prefills for a rule created from a transaction.
    var prefillPattern: String?
    var prefillCategory: CairnSchemaV4.Category?

    @State private var didLoad = false
    @State private var name = ""
    @State private var matchKind: RuleMatchKind = .contains
    @State private var pattern = ""
    @State private var useAmountRange = false
    @State private var minAmountText = ""
    @State private var maxAmountText = ""
    @State private var category: CairnSchemaV4.Category?
    @State private var displayNameTemplate = ""
    @State private var selectedTagIDs: Set<PersistentIdentifier> = []
    @State private var makesCompact = false
    @State private var isEnabled = true

    private var homeCurrency: Currency { NetWorthMath.homeCurrency(settings: settings) }

    /// "-0.00" or "-0,00" depending on the locale, matching the parser.
    private var negativeDecimalPlaceholder: String {
        let separator = Locale.autoupdatingCurrent.decimalSeparator ?? "."
        return "-0\(separator)00"
    }

    private var activeCategories: [CairnSchemaV4.Category] {
        categories.filter { !$0.isArchived }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name (optional)", text: $name)
                }

                Section {
                    Picker("Match", selection: $matchKind) {
                        ForEach(RuleMatchKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    TextField("Text to match", text: $pattern)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } header: {
                    Text("Description")
                } footer: {
                    Text("Matches the raw bank description, case-insensitively.")
                }

                Section {
                    Toggle("Limit by amount", isOn: $useAmountRange)
                    if useAmountRange {
                        amountField("Minimum", text: $minAmountText)
                        amountField("Maximum", text: $maxAmountText)
                    }
                } header: {
                    Text("Amount")
                } footer: {
                    Text("Optional. Amounts are signed: spending is negative (for example -12.34), income is positive.")
                }

                Section {
                    Picker("Category", selection: $category) {
                        Text("No category change").tag(CairnSchemaV4.Category?.none)
                        ForEach(activeCategories) { item in
                            Label(item.name, systemImage: item.symbolName).tag(CairnSchemaV4.Category?.some(item))
                        }
                    }
                    TextField("Display name (optional)", text: $displayNameTemplate)
                        .autocorrectionDisabled()
                    Toggle("Compact matching rows", isOn: $makesCompact)
                } header: {
                    Text("Actions")
                } footer: {
                    Text("For a regex, use {1}, {2}, and so on to insert captured text in the display name. "
                        + "The bank description stays unchanged.")
                }

                Section("Apply tags") {
                    if allTags.isEmpty {
                        Text("Create tags in Settings, then choose them here.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(allTags) { tag in
                            Toggle(tag.name, isOn: tagBinding(tag))
                        }
                    }
                }

                Section {
                    Toggle("Enabled", isOn: $isEnabled)
                }

                Section("Preview") {
                    previewRow
                }
            }
            .formStyle(.grouped)
            .navigationTitle(rule == nil ? "New Rule" : "Edit Rule")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear(perform: load)
        }
    }

    @ViewBuilder
    private func amountField(_ title: LocalizedStringKey, text: Binding<String>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(negativeDecimalPlaceholder, text: text)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 140)
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
        }
    }

    @ViewBuilder
    private var previewRow: some View {
        if let problem = patternProblem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("Enter some text to match.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            let matches = previewMatches
            VStack(alignment: .leading, spacing: 6) {
                if matches.isEmpty {
                    Text("No existing transactions match yet.")
                        .font(.subheadline.weight(.medium))
                } else {
                    Text("Matches ^[\(matches.count) existing transaction](inflect: true).")
                        .font(.subheadline.weight(.medium))
                }
                ForEach(matches.prefix(3), id: \.persistentModelID) { transaction in
                    Text(transaction.payeeDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var parsedAmountBounds: (min: Int64?, max: Int64?) {
        guard useAmountRange else { return (nil, nil) }
        let minText = minAmountText.trimmingCharacters(in: .whitespaces)
        let maxText = maxAmountText.trimmingCharacters(in: .whitespaces)
        let min = minText.isEmpty ? nil : MinorUnits.parse(minText, exponent: 2)
        let max = maxText.isEmpty ? nil : MinorUnits.parse(maxText, exponent: 2)
        return (min, max)
    }

    private var isAmountRangeValid: Bool {
        guard useAmountRange else { return true }
        let minText = minAmountText.trimmingCharacters(in: .whitespaces)
        let maxText = maxAmountText.trimmingCharacters(in: .whitespaces)
        let bounds = parsedAmountBounds
        if !minText.isEmpty, bounds.min == nil { return false }
        if !maxText.isEmpty, bounds.max == nil { return false }
        if let min = bounds.min, let max = bounds.max, min > max { return false }
        return true
    }

    /// Why the draft pattern can't be used, or `nil` when it's fine. A regex that
    /// can backtrack exponentially (nested quantifiers) would stall the
    /// categorization pass, so it is refused here rather than disabled later.
    private var patternProblem: String? {
        guard matchKind == .regularExpression else { return nil }
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return RulesEngine.patternProblem(trimmed)
    }

    private var canSave: Bool {
        !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && isAmountRangeValid
            && patternProblem == nil
            && (category != nil || !displayNameTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !selectedTagIDs.isEmpty || makesCompact)
    }

    private var draftSnapshot: RuleSnapshot? {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let bounds = parsedAmountBounds
        return RuleSnapshot(
            id: UUID(),
            field: .payee,
            matchKind: matchKind,
            pattern: trimmed,
            minAmountMinorUnits: bounds.min,
            maxAmountMinorUnits: bounds.max,
            categoryID: category?.uuid,
            priority: 0,
            displayNameTemplate: displayNameTemplate.trimmingCharacters(in: .whitespacesAndNewlines),
            makesCompact: makesCompact,
            appliedTagIDs: Array(selectedTagIDs)
        )
    }

    private var previewMatches: [LedgerTransaction] {
        guard let snapshot = draftSnapshot else { return [] }
        return allTransactions.filter { transaction in
            snapshot.matches(
                amountMinorUnits: transaction.amountMinorUnits,
                description: transaction.payeeDescription
            )
        }
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        if let rule {
            name = rule.name
            matchKind = RuleMatchKind(rawValue: rule.matchKindRaw) ?? .contains
            pattern = rule.pattern
            category = rule.assignedCategory
            displayNameTemplate = rule.displayNameTemplate ?? ""
            selectedTagIDs = Set((rule.appliedTags ?? []).map(\.persistentModelID))
            makesCompact = rule.makesCompact
            isEnabled = rule.isEnabled
            useAmountRange = rule.minAmountMinorUnits != nil || rule.maxAmountMinorUnits != nil
            minAmountText = rule.minAmountMinorUnits.map { MinorUnits.string($0, exponent: 2) } ?? ""
            maxAmountText = rule.maxAmountMinorUnits.map { MinorUnits.string($0, exponent: 2) } ?? ""
        } else {
            pattern = prefillPattern ?? ""
            category = prefillCategory
        }
    }

    private func save() {
        guard canSave else { return }
        let target: CategorizationRule
        if let rule {
            target = rule
        } else {
            target = CategorizationRule()
            target.priority = nextPriority()
            modelContext.insert(target)
        }
        let bounds = parsedAmountBounds
        target.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        target.fieldRaw = RuleField.payee.rawValue
        target.matchKindRaw = matchKind.rawValue
        target.pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        target.minAmountMinorUnits = bounds.min
        target.maxAmountMinorUnits = bounds.max
        target.assignedCategory = category
        let trimmedDisplayName = displayNameTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        target.displayNameTemplate = trimmedDisplayName.isEmpty ? nil : trimmedDisplayName
        target.appliedTags = allTags.filter { selectedTagIDs.contains($0.persistentModelID) }
        target.makesCompact = makesCompact
        target.isEnabled = isEnabled
        try? modelContext.save()
        Task { await model.applyRules() }
        dismiss()
    }

    private func nextPriority() -> Int {
        let existing = (try? modelContext.fetch(FetchDescriptor<CategorizationRule>())) ?? []
        return (existing.map(\.priority).max() ?? -1) + 1
    }

    private func tagBinding(_ tag: Tag) -> Binding<Bool> {
        Binding(
            get: { selectedTagIDs.contains(tag.persistentModelID) },
            set: { selected in
                if selected { selectedTagIDs.insert(tag.persistentModelID) }
                else { selectedTagIDs.remove(tag.persistentModelID) }
            }
        )
    }
}
