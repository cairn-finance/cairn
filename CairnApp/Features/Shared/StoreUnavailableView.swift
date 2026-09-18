import SwiftUI

/// Shown at the root instead of the app when the persistent store could not be
/// opened.
///
/// Deliberately not dismissable: continuing with an empty in-memory store would
/// look like a fresh install, and anything added to it would be lost on quit.
/// The only action retries opening the real store, which is never written to or
/// removed as part of this screen.
struct StoreUnavailableView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: CairnTheme.Spacing.l) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(CairnTheme.warning)

            VStack(spacing: 10) {
                Text("Cairn couldn’t open your data")
                    .font(.title2.weight(.semibold))
                Text(
                    "The data store on this device could not be opened, so Cairn has not started. "
                        + "Your data on disk has not been changed, uploaded, or deleted."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let failure = model.storeFailure {
                Text(failure)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: 520)
                    .background(
                        CairnTheme.surfaceInset,
                        in: RoundedRectangle(cornerRadius: CairnTheme.controlRadius, style: .continuous)
                    )
            }

            Button("Try Again") {
                model.retryStoreOpen()
            }
            .buttonStyle(.cairnProminent)
            .frame(maxWidth: 320)

            Text("Nothing was uploaded. If this keeps happening, check that the device has free space and try again.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cairnCanvas()
    }
}