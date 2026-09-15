import SwiftUI
import CairnCore

/// The single "add a connection" entry point. It offers SimpleFIN banks and,
/// on iPhone and iPad, Apple Wallet through FinanceKit — two independent
/// sources, since FinanceKit never needs a SimpleFIN token.
///
/// Pass `initialKind` to open straight into one source, which is how the
/// onboarding screen presents the two options directly.
struct AddConnectionSheet: View {
    var initialKind: ConnectionKind?
    var onConnected: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path: [ConnectionKind] = []

    enum ConnectionKind: Hashable, Identifiable {
        case simpleFIN
        case wallet

        var id: Self { self }
    }

    init(initialKind: ConnectionKind? = nil, onConnected: @escaping () -> Void) {
        self.initialKind = initialKind
        self.onConnected = onConnected
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let initialKind {
                    destination(for: initialKind)
                } else {
                    chooser
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
    }

    private var chooser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CairnTheme.Spacing.m) {
                choice(
                    kind: .simpleFIN,
                    icon: "building.columns.fill",
                    title: "Connect a Bank",
                    detail: "Read checking, savings, credit, and brokerage accounts through SimpleFIN."
                )
                #if os(iOS)
                if WalletAvailability.isSupported {
                    choice(
                        kind: .wallet,
                        icon: "wallet.pass.fill",
                        title: "Connect Apple Wallet",
                        detail: "Read Apple Card, Apple Cash, and Savings straight from Wallet. No SimpleFIN needed."
                    )
                }
                #endif
            }
            .padding(CairnTheme.Spacing.l)
            .frame(maxWidth: CairnTheme.screenMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .cairnCanvas()
        .navigationTitle("Add a Connection")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationDestination(for: ConnectionKind.self) { kind in
            destination(for: kind)
        }
    }

    @ViewBuilder
    private func destination(for kind: ConnectionKind) -> some View {
        switch kind {
        case .simpleFIN:
            ScrollView {
                ConnectBankView(onConnected: finish)
                    .padding(CairnTheme.Spacing.l)
                    .frame(maxWidth: CairnTheme.screenMaxWidth)
                    .frame(maxWidth: .infinity)
            }
            .cairnCanvas()
            .navigationTitle("Connect a Bank")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        case .wallet:
            #if os(iOS)
            ScrollView {
                WalletConnectView(onConnected: finish)
                    .padding(CairnTheme.Spacing.l)
                    .frame(maxWidth: CairnTheme.screenMaxWidth)
                    .frame(maxWidth: .infinity)
            }
            .cairnCanvas()
            .navigationTitle("Apple Wallet")
            .navigationBarTitleDisplayMode(.inline)
            #else
            EmptyStateView(
                systemImage: "wallet.pass",
                title: "Apple Wallet isn’t available",
                message: "Wallet financial data can only be read on iPhone and iPad."
            )
            .cairnCanvas()
            .navigationTitle("Apple Wallet")
            #endif
        }
    }

    private func choice(kind: ConnectionKind, icon: String, title: String, detail: String) -> some View {
        Button {
            path.append(kind)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(CairnTheme.accent)
                    .frame(width: 40, height: 40)
                    .background(CairnTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func finish() {
        onConnected()
        dismiss()
    }
}
