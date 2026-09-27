import SwiftUI

struct TabCustomizationView: View {
    @AppStorage(TabLayout.orderKey) private var orderRaw = ""
    @AppStorage(TabLayout.hiddenKey) private var hiddenRaw = ""

    private var layout: TabLayout {
        TabLayout(orderRaw: orderRaw, hiddenRaw: hiddenRaw)
    }

    var body: some View {
        List {
            Section {
                ForEach(layout.orderedSections) { section in
                    Toggle(isOn: visibility(for: section)) {
                        Label(section.title, systemImage: section.systemImage)
                    }
                    .disabled(section == .settings || isLastVisibleDestination(section))
                }
                .onMove(perform: move)
            } footer: {
                Text("Drag to change the order. Settings stays visible so you can change this later.")
            }

            Section {
                Button("Restore Default Tabs") {
                    orderRaw = ""
                    hiddenRaw = ""
                }
                .disabled(orderRaw.isEmpty && hiddenRaw.isEmpty)
            }
        }
        .navigationTitle("Customize Navigation")
        #if os(iOS)
        .toolbar { EditButton() }
        #endif
    }

    private func isLastVisibleDestination(_ section: AppSection) -> Bool {
        guard section != .settings, !layout.hiddenSections.contains(section) else { return false }
        return layout.visibleSections.filter { $0 != .settings }.count == 1
    }

    private func visibility(for section: AppSection) -> Binding<Bool> {
        Binding(
            get: { !layout.hiddenSections.contains(section) },
            set: { isVisible in
                var hidden = layout.hiddenSections
                if isVisible {
                    hidden.remove(section)
                } else if section != .settings && !isLastVisibleDestination(section) {
                    hidden.insert(section)
                }
                hiddenRaw = TabLayout.encodeHidden(hidden)
            }
        )
    }

    private func move(from source: IndexSet, to destination: Int) {
        var sections = layout.orderedSections
        sections.move(fromOffsets: source, toOffset: destination)
        orderRaw = TabLayout.encodeOrder(sections)
    }
}
