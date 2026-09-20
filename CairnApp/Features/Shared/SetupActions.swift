import SwiftUI
import CairnCore

/// The ways to start using Cairn without a bank: connect a bank, create a
/// manual account, or import a CSV. Owns the sheets it presents, so any empty
/// state can offer the same paths without repeating presentation code.
struct SetupActions: View {
    /// Whether to offer a SimpleFIN connection. Screens that already cover
    /// bank connections can turn it off.
    var includesConnect: Bool = true
    /// The type given to a manual account created from here.
    var manualAccountType: AccountType = .checking
    /// Called after one of the paths finishes, if the caller cares.
    var onFinished: (() -> Void)?

    @State private var showingConnect = false
    @State private var showingManual = false
    @State private var showingImport = false

    var body: some View {
        VStack(spacing: 12) {
            if includesConnect {
                Button {
                    showingConnect = true
                } label: {
                    Label("Connect a Bank", systemImage: "building.columns")
                }
                .buttonStyle(.cairnProminent)
                manualButton.buttonStyle(.cairnSecondary)
                importButton.buttonStyle(.cairnSecondary)
            } else {
                manualButton.buttonStyle(.cairnProminent)
                importButton.buttonStyle(.cairnSecondary)
            }
        }
        .sheet(isPresented: $showingConnect) {
            AddConnectionSheet { finish() }
                .cairnLockCover()
        }
        .sheet(isPresented: $showingManual) {
            ManualAccountSheet(initialType: manualAccountType, onCreated: { _ in finish() })
                .cairnLockCover()
        }
        .sheet(isPresented: $showingImport) {
            CSVImportSheet(onFinished: finish)
                .cairnLockCover()
        }
    }

    private var manualButton: some View {
        Button {
            showingManual = true
        } label: {
            Label("Add a Manual Account", systemImage: "square.and.pencil")
        }
    }

    private var importButton: some View {
        Button {
            showingImport = true
        } label: {
            Label("Import CSV", systemImage: "square.and.arrow.down")
        }
    }

    private func finish() {
        onFinished?()
    }
}

/// A friendly first-run empty state with a short title, one plain explanation,
/// and the SetupActions paths beneath it.
struct GetStartedEmptyState: View {
    var systemImage: String = "mountain.2.fill"
    var title: LocalizedStringKey
    var message: LocalizedStringKey
    var includesConnect: Bool = true
    var manualAccountType: AccountType = .checking
    var onFinished: (() -> Void)?

    var body: some View {
        VStack(spacing: CairnTheme.Spacing.l) {
            ZStack {
                Circle()
                    .fill(CairnTheme.accent.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(CairnTheme.accent)
            }
            .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 340)
            SetupActions(
                includesConnect: includesConnect,
                manualAccountType: manualAccountType,
                onFinished: onFinished
            )
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 24)
    }
}
