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
            }
        }
        .overlay(alignment: .top) {
            if let banner = model.banner {
                BannerView(text: banner)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    // A toast must never intercept taps on the toolbar beneath.
                    .allowsHitTesting(false)
            }
        }
        .animation(.snappy, value: model.banner)
        // Banners are transient: clear them after a few seconds so they never
        // sit over the toolbar.
        .task(id: model.banner) {
            guard model.banner != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            model.banner = nil
        }
    }
}

private struct BannerView: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.tint)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.separator.opacity(0.4)))
        .padding(.horizontal)
        .frame(maxWidth: 520)
    }
}

#if os(iOS)
struct MainTabView: View {
    var body: some View {
        TabView {
            Tab("Accounts", systemImage: "building.columns.fill") {
                NavigationStack { AccountsView() }
            }
            Tab("Insights", systemImage: "chart.bar.xaxis") {
                NavigationStack { InsightsView() }
            }
            Tab("Transactions", systemImage: "list.bullet.rectangle") {
                NavigationStack { TransactionsView() }
            }
            Tab("Net Worth", systemImage: "chart.line.uptrend.xyaxis") {
                NavigationStack { NetWorthView() }
            }
            Tab("Settings", systemImage: "gearshape.fill") {
                NavigationStack { SettingsView() }
            }
        }
    }
}
#endif

#if os(macOS)
enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case accounts, insights, transactions, netWorth, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accounts: "Accounts"
        case .insights: "Insights"
        case .transactions: "Transactions"
        case .netWorth: "Net Worth"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .accounts: "building.columns.fill"
        case .insights: "chart.bar.xaxis"
        case .transactions: "list.bullet.rectangle"
        case .netWorth: "chart.line.uptrend.xyaxis"
        case .settings: "gearshape.fill"
        }
    }
}

struct MainShellView: View {
    @State private var selection: SidebarSection = .accounts

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            switch selection {
            case .accounts: NavigationStack { AccountsView() }
            case .insights: NavigationStack { InsightsView() }
            case .transactions: NavigationStack { TransactionsView() }
            case .netWorth: NavigationStack { NetWorthView() }
            case .settings: NavigationStack { SettingsView() }
            }
        }
        .frame(minWidth: 880, minHeight: 560)
    }
}
#endif

extension AppModel.SyncState {
    var errorMessage: String? {
        if case let .failed(message) = self { return message }
        return nil
    }
}
