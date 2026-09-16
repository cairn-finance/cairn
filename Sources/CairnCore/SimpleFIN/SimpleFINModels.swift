import Foundation

// MARK: - Wire format (SimpleFIN v2 account set)

/// Raw decoded JSON from `GET /accounts`. Kept private to the module so the rest
/// of the app works with sanitized, strongly typed domain values.
struct SimpleFINAccountSetDTO: Decodable {
    let errlist: [SimpleFINErrorDTO]?
    let connections: [SimpleFINConnectionDTO]?
    let accounts: [SimpleFINAccountDTO]?

    enum CodingKeys: String, CodingKey {
        case errlist, connections, accounts
    }
}

struct SimpleFINErrorDTO: Decodable {
    let code: String?
    let msg: String?
    let connID: String?
    let accountID: String?

    enum CodingKeys: String, CodingKey {
        case code, msg
        case connID = "conn_id"
        case accountID = "account_id"
    }
}

struct SimpleFINConnectionDTO: Decodable {
    let connID: String?
    let name: String?
    let orgID: String?
    let orgName: String?
    let orgURL: String?
    let sfinURL: String?

    enum CodingKeys: String, CodingKey {
        case name
        case connID = "conn_id"
        case orgID = "org_id"
        case orgName = "org_name"
        case orgURL = "org_url"
        case sfinURL = "sfin_url"
    }
}

struct SimpleFINAccountDTO: Decodable {
    let id: String?
    let name: String?
    let connID: String?
    let connName: String?
    let currency: String?
    let balance: String?
    let availableBalance: String?
    let balanceDate: Double?
    let transactions: [SimpleFINTransactionDTO]?
    let holdings: [SimpleFINHoldingDTO]?

    enum CodingKeys: String, CodingKey {
        case id, name, currency, balance, transactions, holdings
        case connID = "conn_id"
        case connName = "conn_name"
        case availableBalance = "available-balance"
        case balanceDate = "balance-date"
    }
}

/// Investment positions are an extension some servers return. The official
/// protocol does not require them, so a missing `holdings` key is normal.
struct SimpleFINHoldingDTO: Decodable {
    let id: String?
    let symbol: String?
    let description: String?
    let shares: String?
    let marketValue: String?
    let costBasis: String?
    let purchasePrice: String?
    let currency: String?

    enum CodingKeys: String, CodingKey {
        case id, symbol, description, shares, currency
        case marketValue = "market_value"
        case costBasis = "cost_basis"
        case purchasePrice = "purchase_price"
    }
}

struct SimpleFINTransactionDTO: Decodable {
    let id: String?
    let posted: Double?
    let amount: String?
    let description: String?
    let transactedAt: Double?
    let pending: Bool?

    enum CodingKeys: String, CodingKey {
        case id, posted, amount, description, pending
        case transactedAt = "transacted_at"
    }
}

// MARK: - Domain values

/// A parsed, sanitized account set ready to be persisted.
public struct SimpleFINAccountSet: Sendable {
    public var connections: [SimpleFINConnection]
    public var accounts: [SimpleFINAccount]
    public var errors: [SimpleFINServerError]

    public init(
        connections: [SimpleFINConnection] = [],
        accounts: [SimpleFINAccount] = [],
        errors: [SimpleFINServerError] = []
    ) {
        self.connections = connections
        self.accounts = accounts
        self.errors = errors
    }
}

public struct SimpleFINConnection: Sendable, Hashable {
    public let id: String
    public let name: String
    public let organizationID: String
    public let organizationName: String?
    public let organizationURL: String?
    public let simpleFINURL: String

    public init(
        id: String,
        name: String,
        organizationID: String,
        organizationName: String? = nil,
        organizationURL: String? = nil,
        simpleFINURL: String = ""
    ) {
        self.id = id
        self.name = name
        self.organizationID = organizationID
        self.organizationName = organizationName
        self.organizationURL = organizationURL
        self.simpleFINURL = simpleFINURL
    }
}

public struct SimpleFINAccount: Sendable {
    public let id: String
    public let name: String
    public let connectionID: String
    public let connectionName: String?
    public let currency: Currency
    public let balanceMinorUnits: Int64
    public let availableBalanceMinorUnits: Int64?
    public let balanceDate: Date?
    public let transactions: [SimpleFINTransaction]
    public let holdings: [SimpleFINHolding]

    public init(
        id: String,
        name: String,
        connectionID: String,
        connectionName: String? = nil,
        currency: Currency,
        balanceMinorUnits: Int64,
        availableBalanceMinorUnits: Int64? = nil,
        balanceDate: Date? = nil,
        transactions: [SimpleFINTransaction] = [],
        holdings: [SimpleFINHolding] = []
    ) {
        self.id = id
        self.name = name
        self.connectionID = connectionID
        self.connectionName = connectionName
        self.currency = currency
        self.balanceMinorUnits = balanceMinorUnits
        self.availableBalanceMinorUnits = availableBalanceMinorUnits
        self.balanceDate = balanceDate
        self.transactions = transactions
        self.holdings = holdings
    }
}

/// One investment position, exactly as the bank reported it at the last sync.
public struct SimpleFINHolding: Sendable, Hashable {
    public let id: String
    public let symbol: String?
    public let name: String
    /// Exact decimal string; kept verbatim to preserve fractional shares.
    public let sharesRaw: String?
    public let currency: Currency
    public let marketValueMinorUnits: Int64
    public let costBasisMinorUnits: Int64?
    public let purchasePriceMinorUnits: Int64?

    public init(
        id: String,
        symbol: String? = nil,
        name: String,
        sharesRaw: String? = nil,
        currency: Currency,
        marketValueMinorUnits: Int64,
        costBasisMinorUnits: Int64? = nil,
        purchasePriceMinorUnits: Int64? = nil
    ) {
        self.id = id
        self.symbol = symbol
        self.name = name
        self.sharesRaw = sharesRaw
        self.currency = currency
        self.marketValueMinorUnits = marketValueMinorUnits
        self.costBasisMinorUnits = costBasisMinorUnits
        self.purchasePriceMinorUnits = purchasePriceMinorUnits
    }
}

public struct SimpleFINTransaction: Sendable, Hashable {
    public let id: String
    public let postedDate: Date?
    public let transactedAt: Date?
    public let amountMinorUnits: Int64
    public let description: String
    public let isPending: Bool

    public init(
        id: String,
        postedDate: Date?,
        transactedAt: Date?,
        amountMinorUnits: Int64,
        description: String,
        isPending: Bool
    ) {
        self.id = id
        self.postedDate = postedDate
        self.transactedAt = transactedAt
        self.amountMinorUnits = amountMinorUnits
        self.description = description
        self.isPending = isPending
    }
}

/// A structured error reported by the SimpleFIN server, with its message
/// sanitized for display.
public struct SimpleFINServerError: Sendable, Hashable, Identifiable {
    public let id: String
    public let code: String
    public let message: String
    public let connectionID: String?
    public let accountID: String?

    public init(code: String, message: String, connectionID: String? = nil, accountID: String? = nil) {
        self.code = code
        self.message = message
        self.connectionID = connectionID
        self.accountID = accountID
        self.id = "\(code)-\(connectionID ?? "")-\(accountID ?? "")-\(message)"
    }

    /// The general category of the error code (`gen`, `con`, `act`), used to
    /// decide whether it is fatal for a connection.
    public var prefix: String {
        String(code.split(separator: ".").first ?? "")
    }
}

// MARK: - DTO → domain conversion

extension SimpleFINAccountSetDTO {
    /// Resolves a raw SimpleFIN currency value, preferring a fetched custom
    /// descriptor (miles, points) over the bare URL fallback.
    private static func currency(
        for raw: String?,
        customCurrencies: [String: Currency]
    ) -> Currency {
        let value = raw ?? "USD"
        if let resolved = customCurrencies[value] { return resolved }
        return Currency.simpleFIN(value)
    }

    /// - Parameter customCurrencies: Descriptors already fetched for any
    ///   custom-currency URLs in this response, keyed by the raw value the
    ///   server sent. Without them an account shows a bare "Custom".
    func toDomain(customCurrencies: [String: Currency] = [:]) -> SimpleFINAccountSet {
        let connections = (self.connections ?? []).map { dto in
            SimpleFINConnection(
                id: dto.connID ?? "",
                name: ErrorSanitizer.sanitize(dto.name ?? "Institution"),
                organizationID: dto.orgID ?? "",
                organizationName: dto.orgName.map(ErrorSanitizer.sanitize),
                organizationURL: dto.orgURL,
                simpleFINURL: dto.sfinURL ?? ""
            )
        }

        let accounts = (self.accounts ?? []).compactMap { dto -> SimpleFINAccount? in
            guard let id = dto.id, !id.isEmpty else { return nil }
            let currency = Self.currency(for: dto.currency, customCurrencies: customCurrencies)
            let exponent = currency.exponent
            let balance = MinorUnits.parse(dto.balance ?? "0", exponent: exponent) ?? 0
            let available = dto.availableBalance.flatMap { MinorUnits.parse($0, exponent: exponent) }
            let transactions = (dto.transactions ?? []).compactMap { txn -> SimpleFINTransaction? in
                guard let txnID = txn.id, !txnID.isEmpty else { return nil }
                let amount = MinorUnits.parse(txn.amount ?? "0", exponent: exponent) ?? 0
                return SimpleFINTransaction(
                    id: txnID,
                    postedDate: Self.date(from: txn.posted),
                    transactedAt: Self.date(from: txn.transactedAt),
                    amountMinorUnits: amount,
                    description: ErrorSanitizer.sanitize(txn.description ?? ""),
                    isPending: txn.pending ?? false
                )
            }
            let holdings = (dto.holdings ?? []).compactMap { holding -> SimpleFINHolding? in
                guard let holdingID = holding.id, !holdingID.isEmpty else { return nil }
                let holdingCurrency = Self.currency(
                    for: holding.currency ?? dto.currency,
                    customCurrencies: customCurrencies
                )
                let holdingExponent = holdingCurrency.exponent
                let marketValue = MinorUnits.parse(holding.marketValue ?? "0", exponent: holdingExponent) ?? 0
                let costBasis = holding.costBasis.flatMap { MinorUnits.parse($0, exponent: holdingExponent) }
                let purchasePrice = holding.purchasePrice.flatMap { MinorUnits.parse($0, exponent: holdingExponent) }
                return SimpleFINHolding(
                    id: holdingID,
                    symbol: holding.symbol.map(ErrorSanitizer.sanitize),
                    name: ErrorSanitizer.sanitize(holding.description ?? ""),
                    sharesRaw: holding.shares,
                    currency: holdingCurrency,
                    marketValueMinorUnits: marketValue,
                    costBasisMinorUnits: costBasis,
                    purchasePriceMinorUnits: purchasePrice
                )
            }
            return SimpleFINAccount(
                id: id,
                name: ErrorSanitizer.sanitize(dto.name ?? "Account"),
                connectionID: dto.connID ?? "",
                connectionName: dto.connName.map(ErrorSanitizer.sanitize),
                currency: currency,
                balanceMinorUnits: balance,
                availableBalanceMinorUnits: available,
                balanceDate: Self.date(from: dto.balanceDate),
                transactions: transactions,
                holdings: holdings
            )
        }

        let errors = (self.errlist ?? []).map { dto in
            SimpleFINServerError(
                code: dto.code ?? "gen.",
                message: ErrorSanitizer.sanitize(dto.msg ?? "Unknown error"),
                connectionID: dto.connID,
                accountID: dto.accountID
            )
        }

        return SimpleFINAccountSet(connections: connections, accounts: accounts, errors: errors)
    }

    /// SimpleFIN timestamps are Unix epoch seconds and may be `0` for pending
    /// transactions, which is not a meaningful date.
    private static func date(from epoch: Double?) -> Date? {
        guard let epoch, epoch > 0 else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }
}
