import Foundation

/// Routes contain only a destination and, optionally, a local commitment UUID.
public enum SystemSurfaceDestination: Hashable, Sendable {
    case forecast
    case connections
    case commitments
    case commitment(UUID)
    case netWorth
    case activity

    public var url: URL {
        let host: String
        switch self {
        case .forecast: host = "forecast"
        case .connections: host = "connections"
        case .commitments: host = "commitments"
        case .commitment(let id): host = "commitments/\(id.uuidString)"
        case .netWorth: host = "net-worth"
        case .activity: host = "activity"
        }
        // All components above are fixed strings or UUIDs.
        return URL(string: "cairn://\(host)") ?? URL(filePath: "/")
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "cairn",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        switch url.host?.lowercased() {
        case "forecast" where path.isEmpty, "insights" where path.isEmpty:
            self = .forecast
        case "connections" where path.isEmpty:
            self = .connections
        case "net-worth" where path.isEmpty:
            self = .netWorth
        case "activity" where path.isEmpty:
            self = .activity
        case "commitments" where path.isEmpty:
            self = .commitments
        case "commitments" where path.count == 1:
            guard let id = UUID(uuidString: path[0]) else { return nil }
            self = .commitment(id)
        default:
            return nil
        }
    }

    /// Notifications delivered by older versions did not include a route.
    public static func legacyNotification(identifier: String) -> Self? {
        switch identifier {
        case "cairn.stale-connection": .connections
        case "cairn.forecast-risk", "cairn.test-alert": .forecast
        default: identifier.hasPrefix("cairn.commitment.") ? .commitments : nil
        }
    }
}
