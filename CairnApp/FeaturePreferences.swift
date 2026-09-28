import SwiftUI

/// Device-local visibility preferences for optional Cairn surfaces. These are
/// presentation choices, so they do not add a CloudKit field or sync between
/// devices.
enum AppFeature: String, CaseIterable, Identifiable {
    case budgeting

    var id: String { rawValue }

    var storageKey: String { "cairn.feature.\(rawValue).enabled" }

    var defaultEnabled: Bool { true }

    var title: LocalizedStringKey {
        switch self {
        case .budgeting: "Show budgeting"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .budgeting: "Show budget cards, links, and exports. Saved limits stay on device if you turn this off."
        }
    }

    var systemImage: String {
        switch self {
        case .budgeting: "chart.pie.fill"
        }
    }
}
