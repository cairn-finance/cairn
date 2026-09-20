#if os(iOS)
import SwiftUI
import CairnCore

/// Connects Apple Wallet through FinanceKit. This path is separate from
/// SimpleFIN: there is no token and no bank server, only Apple's on-device
/// Wallet data for the accounts the person chooses to share.
struct WalletConnectView: View {
    @Environment(AppModel.self) private var model
    var onConnected: () -> Void

    @State private var isWorking = false
    @State private var errorMessage: String?

    private var alreadyConnected: Bool { model.walletAccountCount > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: CairnTheme.Spacing.l) {
            Card {
                VStack(alignment: .leading, spacing: 18) {
                    feature(
                        icon: "creditcard.fill",
                        title: "Apple Card, Apple Cash, and Savings",
                        detail: "Cairn reads balances and transactions from the eligible Wallet accounts you pick."
                    )
                    feature(
                        icon: "lock.shield.fill",
                        title: "Read-only and on-device",
                        detail: "Cairn can never move money, and none of this goes through a Cairn server or a bank login."
                    )
                    feature(
                        icon: "hand.raised.fill",
                        title: "You choose what to share",
                        detail: "Apple’s picker decides the accounts and how far back to share. Change it any time in Settings › Privacy & Security › Financial Data."
                    )
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(CairnTheme.negative)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            }

            Button {
                connect()
            } label: {
                HStack(spacing: 8) {
                    if isWorking {
                        ProgressView().controlSize(.small).tint(.white)
                    }
                    if isWorking {
                        Text("Connecting…")
                    } else if alreadyConnected {
                        Text("Refresh Apple Wallet")
                    } else {
                        Text("Connect Apple Wallet")
                    }
                }
            }
            .buttonStyle(.cairnProminent)
            .disabled(isWorking)

            Text("Cairn only reads. Apple Wallet keeps working exactly as it does today.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .animation(CairnTheme.Motion.quick, value: errorMessage)
    }

    private func feature(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(CairnTheme.accent)
                .frame(width: 30, height: 30)
                .background(CairnTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func connect() {
        Task {
            isWorking = true
            defer { isWorking = false }
            if await model.connectWallet() {
                errorMessage = nil
                onConnected()
            } else {
                errorMessage = model.syncState.errorMessage
                    ?? "Cairn couldn’t read Wallet data. You can try again."
            }
        }
    }
}
#endif
