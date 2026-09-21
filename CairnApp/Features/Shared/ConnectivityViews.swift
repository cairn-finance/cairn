import SwiftUI
import CairnCore

/// An inline, calm notice that the device is offline. Placed on Home so a
/// paused sync reads as expected rather than broken.
struct OfflineNoticeView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(CairnTheme.warning)
                .frame(width: 30, height: 30)
                .background(CairnTheme.warning.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("You’re offline")
                    .font(.subheadline.weight(.semibold))
                Text("Sync is paused. Cached data still works, and Cairn catches up when you’re back online.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }
}

/// A persistent, actionable home for a sync that didn’t finish. It stays on
/// screen until the problem clears, unlike the transient toast banner.
struct SyncIssueCard: View {
    @Environment(AppModel.self) private var model
    @State private var showingRemoveConfirm = false

    private struct Issue {
        let title: String
        let detail: String
        var hint: String?
        let isFailure: Bool
    }

    private var issue: Issue? {
        switch model.syncState {
        case let .failed(message):
            if model.syncProblemIsJustOffline {
                return Issue(
                    title: "Sync paused",
                    detail: model.offlineSyncExplanation,
                    hint: message,
                    isFailure: false
                )
            }
            return Issue(title: "Last sync didn’t finish", detail: message, isFailure: true)
        case let .waiting(title, detail, _):
            return Issue(title: title, detail: detail, isFailure: false)
        case .idle, .syncing, .success:
            return nil
        }
    }

    var body: some View {
        if let issue {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: issue.isFailure ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(issue.isFailure ? CairnTheme.warning : .secondary)
                            .frame(width: 30, height: 30)
                            .background(
                                (issue.isFailure ? CairnTheme.warning : Color.secondary).opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(issue.title)
                                .font(.subheadline.weight(.semibold))
                            Text(issue.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let hint = issue.hint {
                                Text(hint)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    HStack(spacing: 16) {
                        if !model.isOffline {
                            Button("Try Again") {
                                Task { await model.syncAll(force: true) }
                            }
                            .font(.subheadline.weight(.semibold))
                            .disabled(model.syncState == .syncing)
                        }
                        if model.syncState.missingCredentialIDs != nil {
                            Button("Remove Connection", role: .destructive) {
                                showingRemoveConfirm = true
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                        NavigationLink {
                            SyncDiagnosticsView()
                        } label: {
                            Text("Details")
                                .font(.subheadline.weight(.semibold))
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .cairnAppear()
            .confirmationDialog(
                "Remove the connection?",
                isPresented: $showingRemoveConfirm,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    if let ids = model.syncState.missingCredentialIDs {
                        Task { await model.removeConnections(credentialIDs: ids) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the saved connection and its credential. Connecting again needs a new SimpleFIN setup token.")
            }
        }
    }
}
