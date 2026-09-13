import Foundation

/// A thin, testable client for the parts of the SimpleFIN protocol Cairn uses:
/// claiming a setup token and fetching account sets. It never logs credentials,
/// only talks HTTPS, and relies on the platform's default certificate
/// verification.
public actor SimpleFINClient {
    private let session: URLSession
    private let decoder = JSONDecoder()

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// A session configured for short timeouts and no on-disk caching, so
    /// financial responses do not linger in a URL cache.
    public static func ephemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    // MARK: - Claim

    /// Exchanges a SimpleFIN setup token (a Base64-encoded claim URL) for the
    /// long-lived Access URL. The Access URL is a bearer credential and must be
    /// stored in the Keychain.
    public func claim(token: String) async throws -> URL {
        guard let claimURL = Self.decodeToken(token) else {
            throw SimpleFINError.invalidToken
        }
        guard claimURL.scheme?.lowercased() == "https" else {
            throw SimpleFINError.insecureURL
        }

        var request = URLRequest(url: claimURL)
        request.httpMethod = "POST"
        request.setValue("Cairn/0.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await perform(request)

        guard let http = response as? HTTPURLResponse else {
            throw SimpleFINError.transport("No HTTP response while claiming the token.")
        }

        switch http.statusCode {
        case 200:
            break
        case 403:
            throw SimpleFINError.claimForbidden
        default:
            throw SimpleFINError.httpStatus(http.statusCode)
        }

        let body = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let accessURL = URL(string: body),
              accessURL.scheme?.lowercased() == "https",
              accessURL.host != nil else {
            throw SimpleFINError.invalidToken
        }
        return accessURL
    }

    /// Decodes a setup token. Tolerates surrounding whitespace and the line
    /// wrapping people often introduce when copying from a browser.
    static func decodeToken(_ token: String) -> URL? {
        let cleaned = token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty else { return nil }

        var base64 = cleaned
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        if let data = Data(base64Encoded: base64),
           let string = String(data: data, encoding: .utf8),
           let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return url
        }

        // Some tokens arrive URL-safe encoded.
        let urlSafe = base64
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: urlSafe),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Accounts

    /// Fetches the account set for an Access URL.
    /// - Parameters:
    ///   - startDate: Restricts transactions to those posted on or after this
    ///     date, enabling incremental sync.
    ///   - includePending: Include not-yet-posted transactions when supported.
    public func fetchAccounts(
        accessURL: URL,
        startDate: Date? = nil,
        includePending: Bool = true
    ) async throws -> SimpleFINAccountSet {
        guard accessURL.scheme?.lowercased() == "https" else {
            throw SimpleFINError.insecureURL
        }

        let (credentials, requestURL) = Self.accountsRequestURL(accessURL: accessURL, startDate: startDate, includePending: includePending)

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("Cairn/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let credentials {
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await perform(request)

        guard let http = response as? HTTPURLResponse else {
            throw SimpleFINError.transport("No HTTP response while fetching accounts.")
        }

        switch http.statusCode {
        case 200:
            break
        case 402:
            throw SimpleFINError.paymentRequired
        case 403:
            throw SimpleFINError.unauthorized
        default:
            throw SimpleFINError.httpStatus(http.statusCode)
        }

        do {
            let dto = try decoder.decode(SimpleFINAccountSetDTO.self, from: data)
            return dto.toDomain()
        } catch {
            throw SimpleFINError.decoding(error.localizedDescription)
        }
    }

    /// Fetches metadata for a custom currency (miles, points, etc.).
    public func fetchCustomCurrency(at url: URL) async throws -> Currency {
        guard url.scheme?.lowercased() == "https" else {
            throw SimpleFINError.insecureURL
        }
        var request = URLRequest(url: url)
        request.setValue("Cairn/0.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SimpleFINError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        struct CustomCurrencyDTO: Decodable {
            let name: String?
            let abbr: String?
        }
        let dto = try decoder.decode(CustomCurrencyDTO.self, from: data)
        return Currency(
            code: url.absoluteString,
            exponent: 2,
            isCustom: true,
            customName: dto.name.map(ErrorSanitizer.sanitize),
            customAbbreviation: dto.abbr.map(ErrorSanitizer.sanitize)
        )
    }

    // MARK: - Helpers

    /// Builds the `/accounts` request URL and the Basic auth value, keeping
    /// credentials out of the URL that is actually sent (and therefore out of
    /// any network logs).
    static func accountsRequestURL(
        accessURL: URL,
        startDate: Date?,
        includePending: Bool
    ) -> (credentials: String?, url: URL) {
        var components = URLComponents(url: accessURL, resolvingAgainstBaseURL: false)
        let user = components?.user ?? accessURL.user
        let password = components?.password ?? accessURL.password
        components?.user = nil
        components?.password = nil

        var base = components?.url ?? accessURL
        if !base.path.hasSuffix("/accounts") {
            base = base.appending(path: "accounts")
        }

        var credentials: String?
        if let user, let password {
            credentials = Data("\(user):\(password)".utf8).base64EncodedString()
        } else if let user {
            credentials = Data("\(user):".utf8).base64EncodedString()
        }

        var queryComponents = URLComponents(url: base, resolvingAgainstBaseURL: false)
        var queryItems: [URLQueryItem] = [URLQueryItem(name: "version", value: "2")]
        if includePending {
            queryItems.append(URLQueryItem(name: "pending", value: "1"))
        }
        if let startDate {
            let epoch = Int(startDate.timeIntervalSince1970)
            queryItems.append(URLQueryItem(name: "start-date", value: String(epoch)))
        }
        queryComponents?.queryItems = queryItems

        return (credentials, queryComponents?.url ?? base)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as SimpleFINError {
            throw error
        } catch {
            throw SimpleFINError.transport(error.localizedDescription)
        }
    }
}
