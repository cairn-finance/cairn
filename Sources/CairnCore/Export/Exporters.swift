import Foundation

/// A flat, sendable row describing one transaction for export.
public struct TransactionExportRow: Sendable {
    public var institution: String
    public var account: String
    public var date: Date
    public var amount: String
    public var currency: String
    public var description: String
    public var category: String?
    public var isPending: Bool
    public var isTransfer: Bool
    public var isIgnored: Bool
    public var note: String?
    public var tags: [String]
    public var transactionID: String

    public init(
        institution: String,
        account: String,
        date: Date,
        amount: String,
        currency: String,
        description: String,
        category: String? = nil,
        isPending: Bool = false,
        isTransfer: Bool = false,
        isIgnored: Bool = false,
        note: String? = nil,
        tags: [String] = [],
        transactionID: String
    ) {
        self.institution = institution
        self.account = account
        self.date = date
        self.amount = amount
        self.currency = currency
        self.description = description
        self.category = category
        self.isPending = isPending
        self.isTransfer = isTransfer
        self.isIgnored = isIgnored
        self.note = note
        self.tags = tags
        self.transactionID = transactionID
    }
}

/// CSV and JSON writers. "Your data is yours" is only true if you can get it
/// out in an open format, so these ship in the first release.
public enum Exporters {
    public static let csvHeader = [
        "Institution", "Account", "Date", "Amount", "Currency",
        "Description", "Category", "Pending", "Transfer", "Ignored",
        "Note", "Tags", "Transaction ID",
    ]

    public static func csv(rows: [TransactionExportRow], locale: Locale = Locale(identifier: "en_US_POSIX")) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var lines: [String] = [csvHeader.joined(separator: ",")]
        lines.reserveCapacity(rows.count + 1)

        for row in rows {
            let fields: [(value: String, neutralizeFormula: Bool)] = [
                (row.institution, true),
                (row.account, true),
                (formatter.string(from: row.date), false),
                // Amounts legitimately start with "-", so never neutralize them.
                (row.amount, false),
                (row.currency, true),
                (row.description, true),
                (row.category ?? "", true),
                (row.isPending ? "true" : "false", false),
                (row.isTransfer ? "true" : "false", false),
                (row.isIgnored ? "true" : "false", false),
                (row.note ?? "", true),
                (row.tags.joined(separator: "; "), true),
                (row.transactionID, true),
            ]
            lines.append(
                fields
                    .map { escapeCSV($0.value, neutralizeFormula: $0.neutralizeFormula) }
                    .joined(separator: ",")
            )
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// RFC 4180 escaping: quote when the field contains a comma, quote, or
    /// newline, and double any embedded quotes.
    static func escapeCSV(_ field: String, neutralizeFormula: Bool = false) -> String {
        let value = neutralizeFormula ? neutralizeFormulaInjection(field) : field
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    /// Neutralizes spreadsheet formula injection. A bank-provided description or
    /// a user note that begins with `=`, `+`, `-`, or `@` would otherwise be
    /// evaluated as a formula when the CSV is opened in Excel, Numbers, or
    /// Google Sheets. A leading apostrophe forces it to be treated as text.
    static func neutralizeFormulaInjection(_ field: String) -> String {
        guard let first = field.first else { return field }
        if first == "=" || first == "+" || first == "-" || first == "@"
            || first == "\t" || first == "\r" {
            return "'" + field
        }
        return field
    }

    public static func json(rows: [TransactionExportRow], prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        }
        let payload = JSONExport(
            format: "cairn.transactions",
            version: 1,
            transactions: rows.map(JSONTransaction.init)
        )
        return try encoder.encode(payload)
    }

    /// The top-level document written by `json(rows:)`.
    public struct JSONExport: Encodable {
        let format: String
        let version: Int
        let transactions: [JSONTransaction]
    }

    /// One transaction in the JSON document.
    public struct JSONTransaction: Encodable {
        let institution: String
        let account: String
        let date: Date
        let amount: String
        let currency: String
        let description: String
        let category: String?
        let pending: Bool
        let transfer: Bool
        let ignored: Bool
        let note: String?
        let tags: [String]
        let transactionID: String

        init(_ row: TransactionExportRow) {
            institution = row.institution
            account = row.account
            date = row.date
            amount = row.amount
            currency = row.currency
            description = row.description
            category = row.category
            pending = row.isPending
            transfer = row.isTransfer
            ignored = row.isIgnored
            note = row.note
            tags = row.tags
            transactionID = row.transactionID
        }
    }
}
