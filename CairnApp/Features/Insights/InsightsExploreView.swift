import SwiftUI
import SwiftData
import CairnCore

struct InsightTagsView: View {
    @Query(sort: \Tag.name) private var tags: [Tag]
    let currency: Currency

    var body: some View {
        List {
            if tags.isEmpty {
                ContentUnavailableView(
                    "No tags yet",
                    systemImage: "tag",
                    description: Text("Add tags to transactions to browse them here.")
                )
            } else {
                ForEach(tags) { tag in
                    NavigationLink {
                        InsightFilteredListView(
                            title: tag.name,
                            emptyMessage: "No transactions have this tag.",
                            currency: currency,
                            scope: .tag(tag.persistentModelID)
                        )
                    } label: {
                        TagChip(name: tag.name, colorHex: tag.colorHex)
                    }
                }
            }
        }
        .cairnListStyle()
        .navigationTitle("Tags")
        .toolbar {
            NavigationLink("Manage", destination: TagsView())
        }
    }
}

struct InsightRulesView: View {
    @Query(sort: \CategorizationRule.priority, order: .reverse)
    private var rules: [CategorizationRule]
    let currency: Currency

    var body: some View {
        List {
            if rules.isEmpty {
                ContentUnavailableView(
                    "No rules yet",
                    systemImage: "slider.horizontal.3",
                    description: Text("Create rules to organize your transactions.")
                )
            } else {
                ForEach(rules) { rule in
                    NavigationLink {
                        InsightFilteredListView(
                            title: rule.name.isEmpty ? (rule.assignedCategory?.name ?? "Rule") : rule.name,
                            emptyMessage: "No transactions match this rule.",
                            currency: currency,
                            scope: .rule(rule.uuid)
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(rule.name.isEmpty ? (rule.assignedCategory?.name ?? "Rule") : rule.name)
                                .font(.body.weight(.medium))
                            Text(RulesView.summary(for: rule, currency: currency))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            if !rule.isEnabled {
                                Text("Off").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .cairnListStyle()
        .navigationTitle("Rules")
        .toolbar {
            NavigationLink("Manage", destination: RulesView())
        }
    }
}
