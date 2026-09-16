import SwiftUI

/// Covers a scene with the lock screen while the app lock is engaged, and
/// re-locks when the scene leaves the foreground. Applied to every scene so a
/// macOS settings window can't leak account names either.
struct LockGate<Content: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            // The content stays mounted so the tab selection, navigation stacks,
            // scroll position, and any half-typed text survive a lock. Sheets are
            // drawn in their own window above this one, so each opts into
            // `.cairnLockCover()` to hide behind the lock too.
            content
                .disabled(model.lock.isLocked)
                .allowsHitTesting(!model.lock.isLocked)

            if model.lock.isLocked {
                LockScreenView()
                    .transition(.opacity)
                    .zIndex(1)
            }

            // The app switcher snapshots a scene as it goes inactive, and macOS
            // window thumbnails refresh then too, so cover the content without
            // engaging the lock — locking on every Control Center pull would
            // prompt for Face ID constantly.
            if model.lock.isEnabled, scenePhase != .active {
                PrivacyCoverView()
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .animation(CairnTheme.Motion.standard, value: model.lock.isLocked)
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .background:
                // Leaving the foreground re-engages the lock.
                model.lock.lock()
            case .active:
                // Prompt only once the scene is actually frontmost. Asking
                // during launch makes LAContext fail with `.notInteractive`,
                // which would show a misleading "couldn't unlock" message.
                Task { await model.lock.unlock() }
            default:
                break
            }
        }
        .onChange(of: model.lock.isLocked) { _, locked in
            // Enabling the lock while the app is already open should prompt at
            // once rather than waiting for the next foreground.
            guard locked, scenePhase == .active else { return }
            Task { await model.lock.unlock() }
        }
    }
}

/// Covers a presented sheet while the app is locked.
///
/// A sheet is drawn in its own window above the view that presented it, so the
/// lock overlay in `LockGate` can never reach one. Sheet content opts in with
/// this modifier, which keeps the sheet mounted — and any half-typed text — while
/// hiding it behind the lock screen.
private struct LockCoverModifier: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .overlay {
                if model.lock.isLocked {
                    LockScreenView()
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .animation(CairnTheme.Motion.standard, value: model.lock.isLocked)
    }
}

extension View {
    /// Hides this sheet's content behind the lock screen while Cairn is locked.
    func cairnLockCover() -> some View {
        modifier(LockCoverModifier())
    }
}

/// An opaque curtain over the app while the scene is inactive, so the app
/// switcher and window thumbnails never capture balances. It is not the lock:
/// it has no unlock action and disappears when the scene becomes active again.
struct PrivacyCoverView: View {
    var body: some View {
        ZStack {
            CairnTheme.inkGradient.ignoresSafeArea()
            Image(systemName: "lock.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(CairnTheme.inkGlow)
        }
        .accessibilityHidden(true)
    }
}

/// The full-screen cover shown while Cairn is locked. One calm ink page with a
/// single unlock action, matching the onboarding surface.
struct LockScreenView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            background
            VStack(spacing: CairnTheme.Spacing.xl) {
                mark
                VStack(spacing: 6) {
                    Text("Cairn")
                        .font(.system(size: 34, weight: .bold))
                        .tracking(-0.5)
                    Text("Locked")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.66))
                }

                if let message = model.lock.lastError {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    Task { await model.lock.unlock() }
                } label: {
                    Group {
                        if model.lock.isUnlocking {
                            ProgressView().tint(CairnTheme.ink)
                        } else {
                            Label(model.lock.unlockActionTitle, systemImage: unlockIcon)
                        }
                    }
                }
                .buttonStyle(LockButtonStyle())
                .disabled(model.lock.isUnlocking)
                .frame(maxWidth: 320)
            }
            .padding(28)
            .frame(maxWidth: 420)
            .foregroundStyle(.white)
        }
        .ignoresSafeArea()
        .accessibilityAddTraits(.isModal)
    }

    private var unlockIcon: String {
        switch model.lock.biometryName {
        case "Face ID": "faceid"
        case "Touch ID": "touchid"
        default: "lock.open"
        }
    }

    private var mark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(width: 72, height: 72)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                )
            Image(systemName: "lock.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(CairnTheme.inkGlow)
        }
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

/// The cream call-to-action used on the ink lock surface.
private struct LockButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(CairnTheme.ink)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity)
            .background(CairnTheme.cream.opacity(isEnabled ? 1 : 0.6), in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
