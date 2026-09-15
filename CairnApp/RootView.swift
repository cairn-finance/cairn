import SwiftUI
import CairnCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.onboardingComplete {
                #if os(macOS)
                MainShellView()
                #else
                MainTabView()
                #endif
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .animation(CairnTheme.Motion.standard, value: model.onboardingComplete)
        .overlay(alignment: .top) {
            if let banner = model.banner {
                BannerView(text: banner)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    // A toast must never intercept taps on the toolbar beneath.
                    .allowsHitTesting(false)
            }
        }
        .animation(CairnTheme.Motion.quick, value: model.banner)
        .tint(CairnTheme.accent)
        // Banners are transient: clear them after a few seconds so they never
        // sit over the toolbar.
        .task(id: model.banner) {
            guard model.banner != nil else { return }
            try? await Task.sleep(for: .seconds(4.5))
            guard !Task.isCancelled else { return }
            model.banner = nil
        }
    }
}

/// A transient, non-blocking status toast.
private struct BannerView: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(CairnTheme.accent)
                .padding(.top, 1)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(CairnTheme.outline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        .padding(.horizontal)
        .frame(maxWidth: 520)
    }
}

/// The app's top-level destinations, shared by the iOS tab bar and the macOS
/// sidebar so both platforms have the same information architecture.
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case home, activity, insights, investments, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .activity: "Activity"
        case .insights: "Insights"
        case .investments: "Investments"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .activity: "list.bullet.rectangle.fill"
        case .insights: "chart.bar.xaxis"
        case .investments: "chart.line.uptrend.xyaxis"
        case .settings: "gearshape.fill"
        }
    }

    /// The first tab shown. Debug builds accept `-cairn-tab <name>` so UI can be
    /// checked screen by screen.
    static var initial: AppSection {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-cairn-tab"), index + 1 < args.count,
           let section = AppSection(rawValue: args[index + 1]) {
            return section
        }
        #endif
        return .home
    }

    @MainActor @ViewBuilder
    var destination: some View {
        switch self {
        case .home: HomeView()
        case .activity: TransactionsView()
        case .insights: InsightsView()
        case .investments: InvestmentsView()
        case .settings: SettingsView()
        }
    }
}

#if os(iOS)
struct MainTabView: View {
    @State private var selection: AppSection = AppSection.initial

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppSection.allCases) { section in
                Tab(section.title, systemImage: section.systemImage, value: section) {
                    NavigationStack { section.destination }
                }
            }
        }
    }
}
#endif

#if os(macOS)
struct MainShellView: View {
    @State private var selection: AppSection = AppSection.initial

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            NavigationStack { selection.destination }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}
#endif

extension AppModel.SyncState {
    var errorMessage: String? {
        if case let .failed(message) = self { return message }
        return nil
    }

    /// A non-fatal message worth surfacing in diagnostics (for example, a
    /// credential still on its way through iCloud Keychain). Not a failure.
    var noticeMessage: String? {
        if case let .waiting(message) = self { return message }
        return nil
    }

    /// Whether there is anything to explain in the diagnostics sheet.
    var hasDetails: Bool { errorMessage != nil || noticeMessage != nil }
}
