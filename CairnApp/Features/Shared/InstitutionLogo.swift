import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A small institution mark loaded from that institution's own website.
/// If the site has no conventional favicon, the name initials remain visible.
struct InstitutionLogo: View {
    let organizationURL: String?
    let displayName: String
    var size: CGFloat = 28

    @State private var imageData: Data?

    private var faviconURL: URL? {
        InstitutionFaviconURL.make(from: organizationURL)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(CairnTheme.surface)

            if let imageData, let image = Self.image(from: imageData) {
                image
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.14)
            } else {
                Text(initials)
                    .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                    .foregroundStyle(CairnTheme.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityHidden(true)
        .task(id: faviconURL) {
            await loadFavicon()
        }
    }

    private var initials: String {
        let letters = displayName.split(whereSeparator: \.isWhitespace)
            .prefix(2)
            .map { String($0.prefix(1)) }
            .joined()
            .uppercased()
        return letters.isEmpty ? "?" : letters
    }

    private func loadFavicon() async {
        imageData = nil
        guard let faviconURL else { return }

        let cacheKey = faviconURL.absoluteString
        if let cachedData = InstitutionLogoCache.shared.data(for: cacheKey) {
            imageData = cachedData
            return
        }

        var request = URLRequest(url: faviconURL)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled,
                  let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  data.count <= 1_000_000,
                  Self.image(from: data) != nil else { return }

            InstitutionLogoCache.shared.insert(data, for: cacheKey)
            imageData = data
        } catch {
            // A missing or offline favicon is presentation-only; keep the initials.
        }
    }

    private static func image(from data: Data) -> Image? {
        #if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #elseif os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #else
        nil
        #endif
    }
}

/// Only uses the domain from SimpleFIN's organization URL. Requiring a public
/// hostname and HTTPS avoids requesting icons from local or insecure endpoints.
enum InstitutionFaviconURL {
    static func make(from organizationURL: String?) -> URL? {
        guard let organizationURL else { return nil }
        let trimmed = organizationURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let website = URLComponents(string: candidate),
              website.user == nil,
              website.password == nil,
              let scheme = website.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = website.host?.lowercased(),
              host.contains("."),
              !host.contains(":"),
              host != "localhost",
              !host.hasSuffix(".local"),
              !isIPv4Address(host) else { return nil }

        var icon = URLComponents()
        icon.scheme = "https"
        icon.host = host
        icon.path = "/favicon.ico"
        return icon.url
    }

    private static func isIPv4Address(_ host: String) -> Bool {
        host.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil
    }
}

private final class InstitutionLogoCache: @unchecked Sendable {
    static let shared = InstitutionLogoCache()

    private let storage = NSCache<NSString, NSData>()

    func data(for key: String) -> Data? {
        storage.object(forKey: key as NSString) as Data?
    }

    func insert(_ data: Data, for key: String) {
        storage.setObject(data as NSData, forKey: key as NSString, cost: data.count)
    }
}
