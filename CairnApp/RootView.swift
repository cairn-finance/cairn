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
                BannerView(text: banner) { model.banner = nil }
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.banner)
    }
}

private struct BannerView: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.tint)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
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
    case accounts, transactions, netWorth, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accounts: "Accounts"
        case .transactions: "Transactions"
        case .netWorth: "Net Worth"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .accounts: "building.columns.fill"
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
