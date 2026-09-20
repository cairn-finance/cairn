import SwiftUI
import SwiftData
import CairnCore

/// Adds or edits one transaction in a manual account. Synced rows are
/// bank-owned, so this sheet is only ever reached from a manual account.
struct TransactionEditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \CairnSchemaV1.Category.sortOrder) private var categories: [CairnSchemaV1.Category]
    @Query(sort: \Tag.name) private var allTags: [Tag]

    let account: Account
    /// `nil` adds a new transaction; otherwise the row being edited.
    var transaction: LedgerTransaction?

    @State private var payee = ""
    @State private var amount = ""
    @State private var date = Date()
    @State private var note = ""
    @State private var categoryID: PersistentIdentifier?
    @State private var tagIDs: Set<PersistentIdentifier> = []
    @State private var showingNewTag = false
    @State private var errorMessage: String?
    @State private var didLoad = false
    @FocusState private var payeeFocused: Bool

    private var isEditing: Bool { transaction != nil }

    private var trimmedPayee: String {
        payee.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedAmount: Int64? {
        let trimmed = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return MinorUnits.parse(trimmed, exponent: account.currency.exponent)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Transaction") {
                    TextField("Payee", text: $payee, prompt: Text("Coffee, Rent, Paycheck…"))
                        .focused($payeeFocused)
                    HStack {
                        TextField("0.00", text: $amount)
                            .font(.body.weight(.semibold).monospacedDigit())
                            #if os(iOS)
                            .keyboardType(.numbersAndPunctuation)
                            #endif
                        Text(account.currency.displayLabel)
                            .foregroundStyle(.secondary)
                            .font(.subheadline.weight(.semibold))
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }

                Section("Category") {
                    Picker("Category", selection: $categoryID) {
                        Text("Uncategorized").tag(PersistentIdentifier?.none)
                        ForEach(categories.filter { !$0.isArchived }) { category in
                            Label(category.name, systemImage: category.symbolName)
                                .tag(Optional(category.persistentModelID))
                        }
                    }
                }

                Section("Tags") {
                    if selectedTags.isEmpty {
                        Text("No tags")
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 120), spacing: 8)],
                            alignment: .leading,
                            spacing: 8
                        ) {
                            ForEach(selectedTags) { tag in
                                Button { toggleTag(tag) } label: {
                                    TagChip(name: tag.name, colorHex: tag.colorHex, showsRemove: true)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Menu {
                        ForEach(allTags) { tag in
                            Button {
                                toggleTag(tag)
                            } label: {
                                Label(tag.name, systemImage: tagIDs.contains(tag.persistentModelID) ? "checkmark" : "tag")
                            }
                        }
                        if !allTags.isEmpty { Divider() }
                        Button("New Tag…", systemImage: "plus") { showingNewTag = true }
                    } label: {
                        Label("Add Tag", systemImage: "plus.circle")
                            .font(.subheadline.weight(.medium))
                    }
                }

                Section("Note") {
                    TextField("Add a note", text: $note, axis: .vertical)
                        .lineLimit(2...6)
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
            .navigationTitle(isEditing ? "Edit Transaction" : "New Transaction")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(trimmedPayee.isEmpty || parsedAmount == nil)
                }
            }
            .onAppear(perform: load)
            .sheet(isPresented: $showingNewTag) {
                TagEditorView { tag in
                    tagIDs.insert(tag.persistentModelID)
                }
                .cairnLockCover()
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }

    private var selectedTags: [Tag] {
        allTags.filter { tagIDs.contains($0.persistentModelID) }
    }

    private func toggleTag(_ tag: Tag) {
        if tagIDs.contains(tag.persistentModelID) {
            tagIDs.remove(tag.persistentModelID)
        } else {
            tagIDs.insert(tag.persistentModelID)
        }
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        if let transaction {
            payee = transaction.payeeDescription
            amount = MinorUnits.string(
                transaction.amountMinorUnits,
                exponent: account.currency.exponent
            )
            date = transaction.effectiveDate
            note = transaction.note ?? ""
            categoryID = transaction.userCategory?.persistentModelID
            tagIDs = Set((transaction.tags ?? []).map(\.persistentModelID))
        } else {
            date = .now
            payeeFocused = true
        }
    }

    private func save() {
        guard let parsedAmount else {
            errorMessage = "Enter a valid amount, e.g. -12.34."
            return
        }
        let entry = ManualEntry(
            payee: trimmedPayee,
            amountMinorUnits: parsedAmount,
            date: date,
            note: note,
            categoryID: categoryID,
            tagIDs: Array(tagIDs)
        )
        Task {
            let succeeded: Bool
            if let transaction {
                succeeded = await model.updateManualTransaction(entry, transaction: transaction)
            } else {
                succeeded = await model.addManualTransaction(entry, to: account)
            }
            if succeeded {
                dismiss()
            } else if let banner = model.banner {
                errorMessage = banner
            }
        }
    }
}
