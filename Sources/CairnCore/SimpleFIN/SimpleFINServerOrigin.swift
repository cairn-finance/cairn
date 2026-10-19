import Foundation

/// The HTTPS authority of a locally claimed Access URL, without its secret.
/// Connection metadata returned by a server is never proof of this origin.
public enum SimpleFINServerOrigin {
    public static func normalized(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let port = url.port ?? 443
        guard (1...65_535).contains(port) else { return nil }
        return "https://\(host):\(port)"
    }

    public static func normalized(_ value: String) -> String? {
        guard let url = URL(string: value) else { return nil }
        return normalized(url)
    }
}
