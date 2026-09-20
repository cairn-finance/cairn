import SwiftUI
import CairnCore

/// First launch. One calm ink page that says what Cairn is and lets the person
/// connect a bank or skip straight in.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var connection: AddConnectionSheet.ConnectionKind?
    @State private var credentialToForget: AppModel.RecoverableCredential?
    @State private var showingUseWithoutBank = false

    var body: some View {
        ZStack {
            background
            ScrollView {
                VStack(alignment: .leading, spacing: CairnTheme.Spacing.xxl) {
                    wordmark
                        .cairnAppear()
                    promises
                        .cairnAppear(delay: 0.1)
                    if !model.recoverableCredentials.isEmpty {
                        recoveryCard
                            .cairnAppear(delay: 0.15)
                    }
                    actions
                        .cairnAppear(delay: 0.2)
                }
                .padding(.horizontal, 28)
                .padding(.top, 48)
                .padding(.bottom, 40)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(item: $connection) { kind in
            AddConnectionSheet(initialKind: kind) {
                connection = nil
                model.completeOnboarding()
            }
            .cairnLockCover()
        }
        .sheet(isPresented: $showingUseWithoutBank) {
            UseWithoutBankSheet {
                showingUseWithoutBank = false
                model.completeOnboarding()
            }
            .cairnLockCover()
        }
        .confirmationDialog(
            "Forget the saved connection?",
            isPresented: Binding(
                get: { credentialToForget != nil },
                set: { if !$0 { credentialToForget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Forget Connection", role: .destructive) {
                if let credential = credentialToForget { model.forget(credential) }
                credentialToForget = nil
            }
            Button("Cancel", role: .cancel) { credentialToForget = nil }
        } message: {
            Text("This removes the saved SimpleFIN connection from this device. "
                + "Reconnecting it later will need a new setup token.")
        }
    }

    /// Offered when the Keychain still holds a credential whose institution row
    /// is gone — the delete-and-reinstall case — so a working Access URL need not
    /// be thrown away for a new setup token.
    private var recoveryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(CairnTheme.inkGlow)
                    .accessibilityHidden(true)
                Text("Found a saved SimpleFIN connection")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            ForEach(model.recoverableCredentials) { credential in
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(credential.host) is still in this device’s Keychain. "
                        + "Reconnect it without creating a new setup token.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.66))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button {
                            Task { await model.reconnect(credential) }
                        } label: {
                            HStack(spacing: 6) {
                                if model.reconnectingCredentialIDs.contains(credential.id) {
                                    ProgressView().controlSize(.mini).tint(CairnTheme.ink)
                                }
                                Text(
                                    model.reconnectingCredentialIDs.contains(credential.id)
                                        ? "Reconnecting…"
                                        : "Reconnect"
                                )
                            }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(CairnTheme.ink)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(CairnTheme.cream, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.reconnectingCredentialIDs.contains(credential.id))
                        Button {
                            credentialToForget = credential
                        } label: {
                            Text("Not Now")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.10), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(20)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: CairnTheme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CairnTheme.cardRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var wordmark: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 64, height: 64)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                    )
                Image(systemName: "mountain.2.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(CairnTheme.inkGlow)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Cairn")
                    .font(.system(size: 44, weight: .bold))
                    .tracking(-1)
                Text("Your money. Your data.\nNo account, no server, no tracking.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.white)
    }

    private var promises: some View {
        VStack(alignment: .leading, spacing: 18) {
            promise(
                icon: "lock.shield.fill",
                title: "Credentials stay in the Keychain",
                detail: "Your SimpleFIN access URL never touches the database or logs."
            )
            promise(
                icon: "eye.slash.fill",
                title: "iCloud sync is opt-in",
                detail: "Off by default: nothing leaves this device unless you turn on iCloud, and amounts and descriptions are encrypted before it sees them."
            )
            promise(
                icon: "server.rack",
                title: "There is no Cairn server",
                detail: "The only network calls go to the SimpleFIN server you choose and your own iCloud."
            )
            promise(
                icon: "chevron.left.forwardslash.chevron.right",
                title: "Open source",
                detail: "Every line is auditable. Apache-2.0 licensed."
            )
        }
        .padding(20)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: CairnTheme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CairnTheme.cardRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private func promise(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(CairnTheme.inkGlow)
                .frame(width: 30, height: 30)
                .background(CairnTheme.inkGlow.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.66))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            // Asked before the buttons: connecting stores a Keychain credential
            // right away, and most people never look past the primary action.
            storageChoice
                .padding(.bottom, 4)

            Button {
                connection = .simpleFIN
            } label: {
                Label("Connect a Bank", systemImage: "building.columns")
            }
            .buttonStyle(OnboardingPrimaryStyle())

            #if os(iOS)
            if WalletAvailability.isSupported {
                Button {
                    connection = .wallet
                } label: {
                    Label("Connect Apple Wallet", systemImage: "wallet.pass")
                }
                .buttonStyle(OnboardingSecondaryStyle())
            }
            #endif

            Button {
                showingUseWithoutBank = true
            } label: {
                Text("Use without a bank")
            }
            .buttonStyle(OnboardingSecondaryStyle())

            Text("You can add SimpleFIN, Apple Wallet, or manual accounts any time from Home.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
    }

    private enum StorageChoice: String, CaseIterable, Identifiable {
        case local
        case cloud

        var id: String { rawValue }

        var title: String {
            switch self {
            case .local: "This Device Only"
            case .cloud: "iCloud Sync"
            }
        }
    }

    /// The storage decision the app used to make silently. Local is the default,
    /// so nothing is uploaded to iCloud before the person picks it.
    private var storageChoice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where should your data live?")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            SegmentedPicker(
                options: StorageChoice.allCases,
                selection: storageBinding,
                title: { $0.title },
                onInk: true
            )
            Text(storageDetail)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var storageBinding: Binding<StorageChoice> {
        Binding(
            get: { model.useCloudKit ? .cloud : .local },
            set: { model.chooseStoreMode(cloud: $0 == .cloud) }
        )
    }

    private var storageDetail: String {
        model.useCloudKit
            ? "Syncs through your private iCloud database, with amounts and descriptions encrypted first. Takes effect when you reopen Cairn."
            : "Nothing leaves this device. You can turn on iCloud Sync later in Settings."
    }

    private var background: some View {
        ZStack {
            CairnTheme.inkGradient
            RadialGradient(
                colors: [CairnTheme.inkGlow.opacity(0.35), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 520
            )
            RadialGradient(
                colors: [Color.white.opacity(0.05), .clear],
                center: .bottomLeading,
                startRadius: 0,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
    }
}

private struct OnboardingPrimaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(CairnTheme.ink)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity)
            .background(CairnTheme.cream, in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct OnboardingSecondaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(.white)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.10), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
