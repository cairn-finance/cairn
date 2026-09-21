import SwiftUI
import SwiftData
import CairnCore

/// The fixed set of tag colors, so tags stay legible in both light and dark
/// mode and never depend on a color well.
enum TagColorPalette {
    static let colors = [
        "#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#00C7BE", "#30B0C7",
        "#007AFF", "#5856D6", "#AF52DE", "#FF2D55", "#8E8E93", "#A2845E",
    ]
}

/// A small capsule for a tag, optionally with a remove affordance.
struct TagChip: View {
    let name: String
    let colorHex: String
    var showsRemove: Bool = false

    var body: some View {
        let tint = CairnTheme.color(hex: colorHex)
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            if showsRemove {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.6)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .foregroundStyle(tint)
        .background(tint.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 1))
    }
}

/// Manage the person's tags. Tags are free-form labels and never touch
/// categorization.
struct TagsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Tag.name) private var tags: [Tag]

    @State private var editorTarget: EditorTarget?

    private enum EditorTarget: Identifiable {
        case create
        case edit(Tag)

        var id: String {
            switch self {
            case .create: "create"
            case let .edit(tag): "edit-\(tag.persistentModelID)"
            }
        }
    }

    var body: some View {
        List {
            if tags.isEmpty {
                Section {
                    EmptyStateView(
                        systemImage: "tag",
                        title: "No tags yet",
                        message: "Tags are labels you can add to any transaction and search for later.",
                        actionTitle: "New Tag"
                    ) {
                        editorTarget = .create
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(tags) { tag in
                        Button {
                            editorTarget = .edit(tag)
                        } label: {
                            row(tag)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: delete)
                } footer: {
                    Text("Deleting a tag removes it from every transaction. The transactions themselves stay.")
                }
            }
        }
        .cairnListStyle()
        .navigationTitle("Tags")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editorTarget = .create
                } label: {
                    Label("New Tag", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editorTarget) { target in
            Group {
                switch target {
                case .create:
                    TagEditorView()
                case let .edit(tag):
                    TagEditorView(tag: tag)
                }
            }
            .cairnLockCover()
        }
    }

    private func row(_ tag: Tag) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(CairnTheme.color(hex: tag.colorHex))
                .frame(width: 14, height: 14)
            Text(tag.name)
            Spacer(minLength: 8)
            Text("\(tag.transactions?.count ?? 0)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func delete(_ offsets: IndexSet) {
        for index in offsets {
            let tag = tags[index]
            // Detach from transactions before deleting so the relationship is
            // never left pointing at a removed object.
            for transaction in tag.transactions ?? [] {
                transaction.tags = (transaction.tags ?? []).filter {
                    $0.persistentModelID != tag.persistentModelID
                }
            }
            modelContext.delete(tag)
        }
        try? modelContext.save()
    }
}

/// Creates or renames a tag and picks its color.
struct TagEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    /// When set, the editor edits this tag instead of creating one.
    var tag: Tag?
    /// Called with the saved tag, so a caller can assign it right away.
    var onSave: ((Tag) -> Void)?

    @State private var didLoad = false
    @State private var name = ""
    @State private var colorHex = TagColorPalette.colors.first ?? "#30B0C7"

    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 12)]

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Tag name", text: $name)
                }
                Section("Color") {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(TagColorPalette.colors.indices, id: \.self) { index in
                            let hex = TagColorPalette.colors[index]
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
                                                .accessibilityHidden(true)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Color \(index + 1)"))
                            .accessibilityAddTraits(hex == colorHex ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                }
                if !previewName.isEmpty {
                    Section("Preview") {
                        TagChip(name: previewName, colorHex: colorHex)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(tag == nil ? "New Tag" : "Edit Tag")
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

    private var previewName: String { trimmedName }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        guard let tag else { return }
        name = tag.name
        colorHex = tag.colorHex
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        let target: Tag
        if let tag {
            target = tag
        } else {
            target = Tag(name: trimmedName, colorHex: colorHex)
            modelContext.insert(target)
        }
        target.name = trimmedName
        target.colorHex = colorHex
        try? modelContext.save()
        onSave?(target)
        dismiss()
    }
}
