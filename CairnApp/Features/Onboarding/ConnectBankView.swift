import SwiftUI
import CairnCore

/// Reusable SimpleFIN connection form, presented in a sheet from onboarding
/// and from Home when adding another institution.
struct ConnectBankView: View {
    @Environment(AppModel.self) private var model
    var onConnected: () -> Void

    @State private var token = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var tokenFocused: Bool

    private var trimmedToken: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CairnTheme.Spacing.l) {
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    step(1, "Create a setup token", detail: "SimpleFIN Bridge connects to your bank and hands you a one-time token.") {
                        Link(destination: URL(string: "https://bridge.simplefin.org/simplefin/create")!) {
                            Label("Open SimpleFIN Bridge", systemImage: "safari")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.cairnSecondary)
                    }

                    RowDivider(leadingInset: 0)

                    step(2, "Paste the token here", detail: "Cairn claims it once, stores the access URL in the Keychain, and runs the first sync.") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("SimpleFIN setup token", text: $token, axis: .vertical)
                                .lineLimit(2...4)
                                .font(.system(.footnote, design: .monospaced))
                                .textFieldStyle(.plain)
                                .focused($tokenFocused)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                                .padding(12)
                                .background(CairnTheme.surfaceInset, in: RoundedRectangle(cornerRadius: CairnTheme.controlRadius, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: CairnTheme.controlRadius, style: .continuous)
                                        .strokeBorder(tokenFocused ? CairnTheme.accent.opacity(0.6) : CairnTheme.outline, lineWidth: 1)
                                )
                                .animation(CairnTheme.Motion.quick, value: tokenFocused)
                                .onChange(of: token) { _, _ in errorMessage = nil }

                            PasteButton(payloadType: String.self) { strings in
                                if let first = strings.first {
                                    token = first
                                    errorMessage = nil
                                }
                            }
                            .labelStyle(.titleAndIcon)
                            .buttonBorderShape(.capsule)
                        }
                    }
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
                    Text(isWorking ? "Connecting…" : "Connect")
                }
            }
            .buttonStyle(.cairnProminent)
            .disabled(trimmedToken.isEmpty || isWorking)

            Text("Cairn only reads balances and transactions. It never moves money, and you can revoke access from SimpleFIN at any time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .animation(CairnTheme.Motion.quick, value: errorMessage)
    }

    private func step<Content: View>(_ number: Int, _ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(CairnTheme.inkGradient, in: Circle())
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content()
            }
        }
    }

    private func connect() {
        Task {
            isWorking = true
            defer { isWorking = false }
            if await model.connectInstitution(token: trimmedToken) {
                token = ""
                errorMessage = nil
                onConnected()
            } else {
                errorMessage = model.syncState.errorMessage
                    ?? "Cairn couldn’t connect with that token."
            }
        }
    }
}
