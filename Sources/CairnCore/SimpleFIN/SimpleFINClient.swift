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

    /// User-Agent sent to SimpleFIN. The version is read from the app bundle so
    /// it can never go stale; the package and tests fall back to a plain name.
    static var userAgent: String {
        guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              !version.isEmpty
        else { return "Cairn" }
        return "Cairn/\(version)"
    }

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
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        // The claim path *is* the setup token, and a failed claim leaves it
        // unused, so never write it to a log the person is asked to share.
        await cairnLog(.info, "POST \(claimURL.host ?? "?"): claiming a setup token (path withheld).")
        let (data, response) = try await perform(request)

        guard let http = response as? HTTPURLResponse else {
            await cairnLog(.error, "No HTTP response while claiming the token.")
            throw SimpleFINError.transport("No HTTP response while claiming the token.")
        }
        await cairnLog(.info, "Claim HTTP \(http.statusCode)")

        switch http.statusCode {
        case 200:
            break
        case 403:
            await cairnLog(.error, "Claim HTTP 403: token already used.")
            throw SimpleFINError.claimForbidden
        default:
            await cairnLog(.error, "Claim HTTP \(http.statusCode).")
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
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let credentials {
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }

        await cairnLog(.info, "GET \(requestURL.host ?? "?")\(requestURL.path)?\(requestURL.query ?? "")")

        let (data, response) = try await perform(request)

        guard let http = response as? HTTPURLResponse else {
            await cairnLog(.error, "No HTTP response while fetching accounts.")
            throw SimpleFINError.transport("No HTTP response while fetching accounts.")
        }
        await cairnLog(.info, "HTTP \(http.statusCode), \(data.count) bytes")

        switch http.statusCode {
        case 200:
            break
        case 402:
            await cairnLog(.error, "HTTP 402: the SimpleFIN subscription needs attention.")
            throw SimpleFINError.paymentRequired
        case 403:
            if let errors = errors(in: data), !errors.isEmpty {
                await cairnLog(.error, "HTTP 403: \(errors.map(\.message).joined(separator: " | "))")
                throw SimpleFINError.serverReported(errors)
            }
            await cairnLog(.error, "HTTP 403: access revoked or credentials invalid.")
            throw SimpleFINError.unauthorized
        default:
            if let errors = errors(in: data), !errors.isEmpty {
                await cairnLog(.error, "HTTP \(http.statusCode): \(errors.map(\.message).joined(separator: " | "))")
                throw SimpleFINError.serverReported(errors)
            }
            await cairnLog(.error, "HTTP \(http.statusCode) with no structured errors.")
            throw SimpleFINError.httpStatus(http.statusCode)
        }

        do {
            let dto = try decoder.decode(SimpleFINAccountSetDTO.self, from: data)
            // A custom currency (miles, points) arrives as a URL to a descriptor.
            // Resolve those before mapping so the account shows its real name.
            let customCurrencies = await resolveCustomCurrencies(in: dto)
            let accountSet = dto.toDomain(customCurrencies: customCurrencies)
            let errors = accountSet.errors.isEmpty ? "none" : accountSet.errors.map(\.message).joined(separator: " | ")
            await cairnLog(
                .info,
                "Decoded connections=\(accountSet.connections.count) accounts=\(accountSet.accounts.count) "
                    + "transactions=\(accountSet.accounts.reduce(0) { $0 + $1.transactions.count }) errors=\(errors)"
            )
            return accountSet
        } catch {
            await cairnLog(.error, "Decoding failed: \(ErrorSanitizer.sanitize(error.localizedDescription))")
            throw SimpleFINError.decoding(error.localizedDescription)
        }
    }

    /// Fetches descriptors for any custom-currency URLs in a response, so an
    /// account denominated in points or miles shows its real name instead of a
    /// bare "Custom". A failure is ignored: the plain fallback is better than
    /// failing a whole sync over a label.
    private func resolveCustomCurrencies(in dto: SimpleFINAccountSetDTO) async -> [String: Currency] {
        let values = Set(
            (dto.accounts ?? []).flatMap { account in
                [account.currency] + (account.holdings ?? []).map(\.currency)
            }
            .compactMap { $0 }
        )
        let urls = values.filter { value in
            guard let scheme = URL(string: value)?.scheme?.lowercased() else { return false }
            return scheme == "https" || scheme == "http"
        }
        guard !urls.isEmpty else { return [:] }

        var resolved: [String: Currency] = [:]
        for value in urls {
            guard let url = URL(string: value) else { continue }
            if let currency = try? await fetchCustomCurrency(at: url) {
                resolved[value] = currency
            }
        }
        return resolved
    }

    /// Fetches metadata for a custom currency (miles, points, etc.).
    public func fetchCustomCurrency(at url: URL) async throws -> Currency {
        guard url.scheme?.lowercased() == "https" else {
            throw SimpleFINError.insecureURL
        }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

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

    /// Extracts structured errors from a response body. The bridge may include
    /// `errlist` on non-200 responses as well as 200, and its docs ask apps to
    /// always show those messages, so surface the real text when we can.
    private func errors(in data: Data) -> [SimpleFINServerError]? {
        (try? decoder.decode(SimpleFINAccountSetDTO.self, from: data))?.toDomain().errors
    }

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
