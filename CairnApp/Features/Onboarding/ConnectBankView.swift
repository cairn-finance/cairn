import SwiftUI
import CairnCore

/// Reusable SimpleFIN connection form. Used during onboarding and when adding
/// another institution later.
struct ConnectBankView: View {
    @Environment(AppModel.self) private var model
    var onConnected: () -> Void

    @State private var token = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var trimmedToken: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect an institution")
                    .font(.headline)
                Text("Cairn reads balances and transactions through SimpleFIN. Create a setup token in your browser, then paste it here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Link(destination: URL(string: "https://bridge.simplefin.org/simplefin/create")!) {
                Label("Open SimpleFIN Bridge", systemImage: "safari")
            }
            .buttonStyle(.bordered)

            HStack(spacing: 10) {
                PasteButton(payloadType: String.self) { strings in
                    if let first = strings.first {
                        token = first
                        errorMessage = nil
                    }
                }
                .labelStyle(.titleAndIcon)
                Text("Paste the token instead of typing it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("SimpleFIN setup token", text: $token, axis: .vertical)
                .lineLimit(2...4)
                .font(.system(.footnote, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onChange(of: token) { _, _ in errorMessage = nil }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(CairnTheme.negative)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                connect()
            } label: {
                HStack(spacing: 8) {
                    if isWorking { ProgressView().controlSize(.small) }
                    Text(isWorking ? "Connecting…" : "Connect")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(trimmedToken.isEmpty || isWorking)
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
