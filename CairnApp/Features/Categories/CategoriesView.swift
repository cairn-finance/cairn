import SwiftUI
import SwiftData
import CairnCore

/// The fixed set of category colors, so categories stay legible in both light
/// and dark mode and never depend on a color well.
enum CategoryColorPalette {
    static let colors = [
        "#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#00C7BE", "#30B0C7",
        "#007AFF", "#5856D6", "#AF52DE", "#FF2D55", "#8E8E93", "#A2845E",
    ]
}

/// A small, curated set of SF Symbols for categories.
enum CategorySymbolPalette {
    static let symbols = [
        "tag.fill", "cart.fill", "fork.knife", "car.fill", "house.fill",
        "bolt.fill", "bag.fill", "heart.fill", "play.circle.fill", "airplane",
        "percent", "arrow.left.arrow.right", "questionmark.circle", "arrow.down.circle.fill",
        "creditcard.fill", "building.columns.fill", "gift.fill", "pawprint.fill",
        "book.fill", "dumbbell.fill", "wrench.and.screwdriver.fill", "cup.and.saucer.fill",
        "tram.fill", "cross.case.fill", "paintpalette.fill", "banknote.fill",
    ]
}

/// Manage the person's categories: add, rename, recolor, reorder, and hide.
/// Built-in categories are structural and only ever get reordered or recolored.
struct CategoriesView: View {
    @Environment(AppModel.self) private var model
    @Query(
        sort: [
            SortDescriptor(\CairnSchemaV1.Category.sortOrder),
            SortDescriptor(\CairnSchemaV1.Category.createdAt),
        ]
    )
    private var categories: [CairnSchemaV1.Category]

    @State private var editorTarget: EditorTarget?
    @State private var pendingDeletion: CairnSchemaV1.Category?

    private enum EditorTarget: Identifiable {
        case create
        case edit(CairnSchemaV1.Category)

        var id: String {
            switch self {
            case .create: "create"
            case let .edit(category): "edit-\(category.uuid.uuidString)"
            }
        }
    }

    private var active: [CairnSchemaV1.Category] { categories.filter { !$0.isArchived } }
    private var archived: [CairnSchemaV1.Category] { categories.filter(\.isArchived) }

    var body: some View {
        List {
            Section {
                ForEach(active) { category in
                    row(category, reorderable: true)
                }
            } footer: {
                Text("Drag order is set with the arrows. Categories are listed in this order wherever you pick one.")
            }

            if !archived.isEmpty {
                Section {
                    ForEach(archived) { category in
                        archivedRow(category)
                    }
                } header: {
                    Text("Hidden")
                } footer: {
                    Text("Hidden categories stay on the transactions and rules that already use them, "
                        + "but no longer appear in pickers.")
                }
            }
        }
        .cairnListStyle()
        .navigationTitle("Categories")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editorTarget = .create
                } label: {
                    Label("New Category", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editorTarget) { target in
            Group {
                switch target {
                case .create:
                    CategoryEditorView()
                case let .edit(category):
                    CategoryEditorView(category: category)
                }
            }
            .cairnLockCover()
        }
        .confirmationDialog(
            pendingDeletion.map { "Remove \($0.name)?" } ?? "Remove category?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let category = pendingDeletion {
                switch deletionDecision(for: category) {
                case .delete:
                    Button("Delete", role: .destructive) {
                        Task { await model.deleteCategory(id: category.uuid) }
                        pendingDeletion = nil
                    }
                case .archive:
                    if !category.isArchived {
                        Button("Archive") {
                            Task { await model.setCategoryArchived(id: category.uuid, archived: true) }
                            pendingDeletion = nil
                        }
                    }
                case .forbidden:
                    EmptyView()
                }
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            if let category = pendingDeletion {
                Text(deletionMessage(for: category))
            }
        }
    }

    // MARK: - Rows

    private func row(_ category: CairnSchemaV1.Category, reorderable: Bool) -> some View {
        HStack(spacing: 12) {
            Button {
                editorTarget = .edit(category)
            } label: {
                HStack(spacing: 12) {
                    CategoryBadge(symbolName: category.symbolName, hex: category.colorHex, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(category.name)
                            if category.isSystem {
                                Image(systemName: "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Text(referenceSummary(category))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if reorderable {
                reorderControls(category)
            }
        }
        .contextMenu {
            Button("Edit", systemImage: "pencil") { editorTarget = .edit(category) }
            if !category.isSystem {
                Button("Archive", systemImage: "archivebox") {
                    Task { await model.setCategoryArchived(id: category.uuid, archived: true) }
                }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    pendingDeletion = category
                }
            }
        }
    }

    private func archivedRow(_ category: CairnSchemaV1.Category) -> some View {
        HStack(spacing: 12) {
            CategoryBadge(symbolName: category.symbolName, hex: category.colorHex, size: 36)
                .opacity(0.55)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.name)
                Text("Hidden")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Unhide") {
                Task { await model.setCategoryArchived(id: category.uuid, archived: false) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .contextMenu {
            Button("Unhide", systemImage: "eye") {
                Task { await model.setCategoryArchived(id: category.uuid, archived: false) }
            }
            if !category.isSystem {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    pendingDeletion = category
                }
            }
        }
    }

    private func reorderControls(_ category: CairnSchemaV1.Category) -> some View {
        HStack(spacing: 2) {
            Button {
                Task { await model.moveCategory(id: category.uuid, direction: .up) }
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(active.first?.uuid == category.uuid)
            .accessibilityLabel("Move \(category.name) up")

            Button {
                Task { await model.moveCategory(id: category.uuid, direction: .down) }
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(active.last?.uuid == category.uuid)
            .accessibilityLabel("Move \(category.name) down")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }

    // MARK: - Deletion

    private func deletionDecision(for category: CairnSchemaV1.Category) -> CategoryDeletionDecision {
        let transactionCount = (category.userTransactions?.count ?? 0)
            + (category.autoTransactions?.count ?? 0)
        return CategoryManagement.deletionDecision(
            isSystem: category.isSystem,
            transactionCount: transactionCount,
            ruleCount: category.rules?.count ?? 0
        )
    }

    private func deletionMessage(for category: CairnSchemaV1.Category) -> String {
        switch deletionDecision(for: category) {
        case .delete:
            return "This category isn’t used by any transaction or rule, so it can be deleted for good."
        case .archive:
            if category.isArchived {
                return "Transactions or rules still use “\(category.name)”, so it can’t be deleted. "
                    + "It’s already hidden; unhide it first if you want it in pickers again."
            }
            return "Transactions or rules still use “\(category.name)”. Deleting it would strip their label, "
                + "so you can hide it instead. You can unhide it later."
        case .forbidden:
            return "“\(category.name)” is a built-in category. It can be recolored or reordered, but not removed."
        }
    }

    private func referenceSummary(_ category: CairnSchemaV1.Category) -> String {
        let transactionCount = (category.userTransactions?.count ?? 0)
            + (category.autoTransactions?.count ?? 0)
        let ruleCount = category.rules?.count ?? 0
        var parts: [String] = []
        if transactionCount > 0 {
            parts.append(String(localized: "^[\(transactionCount) transaction](inflect: true)"))
        }
        if ruleCount > 0 {
            parts.append(String(localized: "^[\(ruleCount) rule](inflect: true)"))
        }
        return parts.isEmpty ? "Not used yet" : parts.joined(separator: " · ")
    }
}

/// Creates a category, or edits an existing one's name, symbol, and color.
struct CategoryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    /// When set, the editor edits this category instead of creating one.
    var category: CairnSchemaV1.Category?

    @State private var didLoad = false
    @State private var name = ""
    @State private var symbolName = CategorySymbolPalette.symbols.first ?? "tag.fill"
    @State private var colorHex = CategoryColorPalette.colors.first ?? "#30B0C7"

    private var isSystem: Bool { category?.isSystem ?? false }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 44), spacing: 12)]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Category name", text: $name)
                        .disabled(isSystem)
                }
                Section {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(CategorySymbolPalette.symbols, id: \.self) { symbol in
                            Button {
                                symbolName = symbol
                            } label: {
                                Image(systemName: symbol)
                                    .font(.system(size: 18, weight: .medium))
                                    .frame(width: 34, height: 34)
                                    .foregroundStyle(symbol == symbolName ? Color.white : CairnTheme.color(hex: colorHex))
                                    .background(
                                        symbol == symbolName
                                            ? CairnTheme.color(hex: colorHex)
                                            : CairnTheme.color(hex: colorHex).opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(isSystem)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Symbol")
                } footer: {
                    if isSystem {
                        Text("Built-in categories keep their name and symbol.")
                    }
                }
                Section("Color") {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(CategoryColorPalette.colors, id: \.self) { hex in
                            Button {
                                colorHex = hex
                            } label: {
                                Circle()
                                    .fill(CairnTheme.color(hex: hex))
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        if hex == colorHex {
                                            Image(systemName: "checkmark")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                if !trimmedName.isEmpty {
                    Section("Preview") {
                        HStack(spacing: 12) {
                            CategoryBadge(symbolName: symbolName, hex: colorHex, size: 36)
                            Text(trimmedName)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(category == nil ? "New Category" : "Edit Category")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(trimmedName.isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        guard let category else { return }
        name = category.name
        symbolName = category.symbolName
        colorHex = category.colorHex
    }

    private func save() {
        guard let name = CategoryManagement.normalizedName(name) else { return }
        let symbol = symbolName
        let color = colorHex
        let existingID = category?.uuid
        Task {
            if let existingID {
                _ = await model.updateCategory(
                    id: existingID,
                    name: name,
                    symbolName: symbol,
                    colorHex: color
                )
            } else {
                _ = await model.createCategory(name: name, symbolName: symbol, colorHex: color)
            }
        }
        dismiss()
    }
}
