import SwiftUI
import CairnCore

struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                privacySection

                Card {
                    ConnectBankView {
                        model.completeOnboarding()
                    }
                }

                Button {
                    model.completeOnboarding()
                } label: {
                    Text("Continue without connecting a bank")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.subheadline)
            }
            .padding(24)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .background(backgroundGradient)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "mountain.2.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.tint)
            Text("Cairn")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text("Your money. Your data. No account, no server, no tracking.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var privacySection: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("Private by architecture")
                    .font(.headline)

                privacyPoint(
                    icon: "lock.shield.fill",
                    title: "Credentials stay in the Keychain",
                    detail: "Your SimpleFIN access URL is a bearer credential. It is stored in the Keychain, never in the database or logs."
                )
                privacyPoint(
                    icon: "eye.slash.fill",
                    title: "Financial fields are end-to-end encrypted",
                    detail: "Amounts, balances, and descriptions use CloudKit encrypted fields, so Apple stores the record but cannot read it."
                )
                privacyPoint(
                    icon: "server.rack",
                    title: "There is no Cairn server",
                    detail: "The only network calls are to the SimpleFIN server you choose and your own iCloud account."
                )
                privacyPoint(
                    icon: "chevron.left.forwardslash.chevron.right",
                    title: "Open source",
                    detail: "Every line is auditable. Cairn is Apache-2.0 licensed."
                )
                privacyPoint(
                    icon: "internaldrive",
                    title: "Prefer no iCloud at all?",
                    detail: "Switch to This Device Only in Settings. Your data stays on this device and your credential stops syncing."
                )
            }
        }
    }

    private func privacyPoint(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.14), Color.clear],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}
