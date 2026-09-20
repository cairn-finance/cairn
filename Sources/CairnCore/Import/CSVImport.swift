import Foundation

/// A single parsed row ready to be inserted as a transaction.
public struct ImportedTransaction: Sendable, Hashable {
    public let date: Date
    /// Raw description from the file (used as `payeeDescription`).
    public let description: String
    /// Raw merchant text when the file provides one, else the description.
    public let merchant: String
    public let amountMinorUnits: Int64

    public init(date: Date, description: String, merchant: String, amountMinorUnits: Int64) {
        self.date = date
        self.description = description
        self.merchant = merchant
        self.amountMinorUnits = amountMinorUnits
    }
}

public struct CSVImportResult: Sendable {
    public var transactions: [ImportedTransaction]
    public var skippedRows: Int
    public var warnings: [String]

    public init(transactions: [ImportedTransaction] = [], skippedRows: Int = 0, warnings: [String] = []) {
        self.transactions = transactions
        self.skippedRows = skippedRows
        self.warnings = warnings
    }
}

/// Date layouts seen in bank and Apple exports.
public enum ImportDateFormat: String, Sendable, CaseIterable, Codable {
    case monthDayYear
    case dayMonthYear
    case yearMonthDay

    public var displayName: String {
        switch self {
        case .monthDayYear: "MM/DD/YYYY"
        case .dayMonthYear: "DD/MM/YYYY"
        case .yearMonthDay: "YYYY-MM-DD"
        }
    }

    var patterns: [String] {
        switch self {
        case .monthDayYear: ["MM/dd/yyyy", "M/d/yyyy", "MM/dd/yy", "M/d/yy"]
        case .dayMonthYear: ["dd/MM/yyyy", "d/M/yyyy", "dd.MM.yyyy", "d.M.yyyy", "dd/MM/yy", "d/M/yy"]
        case .yearMonthDay: ["yyyy-MM-dd", "yyyy/MM/dd", "yyyy.MM.dd"]
        }
    }
}

/// Known export layouts, used only to pick sensible defaults.
public enum CSVImportPreset: String, Sendable, CaseIterable, Codable {
    case appleCard
    case appleSavings
    case generic

    public var displayName: LocalizedStringResource {
        switch self {
        case .appleCard: "Apple Card"
        case .appleSavings: "Apple Savings"
        case .generic: "Generic CSV"
        }
    }

    public var summary: LocalizedStringResource {
        switch self {
        case .appleCard:
            "Wallet → Apple Card → Statements → Export Transactions (CSV)."
        case .appleSavings:
            "Wallet → Apple Card → Savings → Documents → Export Transactions (CSV)."
        case .generic:
            "Any CSV with date, description, and amount columns."
        }
    }

    var preferredDateFormat: ImportDateFormat {
        switch self {
        case .appleCard, .appleSavings: .monthDayYear
        case .generic: .yearMonthDay
        }
    }
}

/// Which CSV columns map to which transaction fields.
public struct CSVImportMapping: Sendable, Hashable {
    public var dateColumn: String
    public var descriptionColumn: String?
    public var merchantColumn: String?
    public var amountColumn: String?
    public var debitColumn: String?
    public var creditColumn: String?
    public var dateFormat: ImportDateFormat
    /// Some exports write expenses as positive numbers; this flips the sign.
    public var flipsSign: Bool

    public init(
        dateColumn: String,
        descriptionColumn: String? = nil,
        merchantColumn: String? = nil,
        amountColumn: String? = nil,
        debitColumn: String? = nil,
        creditColumn: String? = nil,
        dateFormat: ImportDateFormat = .monthDayYear,
        flipsSign: Bool = false
    ) {
        self.dateColumn = dateColumn
        self.descriptionColumn = descriptionColumn
        self.merchantColumn = merchantColumn
        self.amountColumn = amountColumn
        self.debitColumn = debitColumn
        self.creditColumn = creditColumn
        self.dateFormat = dateFormat
        self.flipsSign = flipsSign
    }
}

/// Finds the best column for each role by header name, so preset headers we
/// haven't seen exactly (notably Apple Savings) still map correctly.
public enum CSVColumnResolver {
    private static let synonyms: [(role: String, patterns: [String])] = [
        ("date", ["transaction date", "post date", "posted date", "date", "clearing date"]),
        ("description", ["description", "name", "payee", "memo", "details", "narrative"]),
        ("merchant", ["merchant", "vendor"]),
        ("amount", ["amount (usd)", "amount", "transaction amount", "value"]),
        ("debit", ["debit", "withdrawal", "money out", "outflow"]),
        ("credit", ["credit", "deposit", "money in", "inflow"]),
    ]

    public static func resolve(headers: [String], preset: CSVImportPreset) -> CSVImportMapping? {
        let normalized = headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        func find(_ patterns: [String]) -> String? {
            for pattern in patterns {
                if let index = normalized.firstIndex(of: pattern) { return headers[index] }
            }
            for pattern in patterns {
                if let index = normalized.firstIndex(where: { $0.contains(pattern) }) { return headers[index] }
            }
            return nil
        }

        func value(for role: String) -> String? {
            guard let entry = synonyms.first(where: { $0.role == role }) else { return nil }
            return find(entry.patterns)
        }

        guard let dateColumn = value(for: "date") else { return nil }

        return CSVImportMapping(
            dateColumn: dateColumn,
            descriptionColumn: value(for: "description"),
            merchantColumn: value(for: "merchant"),
            amountColumn: value(for: "amount"),
            debitColumn: value(for: "debit"),
            creditColumn: value(for: "credit"),
            dateFormat: preset.preferredDateFormat,
            flipsSign: false
        )
    }
}

/// Turns a parsed CSV document into transactions using a column mapping.
public enum CSVImportParser {
    public static func parse(
        _ document: CSVParser.Document,
        mapping: CSVImportMapping,
        currency: Currency
    ) -> CSVImportResult {
        let headers = document.headers
        guard let dateIndex = headers.firstIndex(of: mapping.dateColumn) else {
            return CSVImportResult(warnings: ["The date column “\(mapping.dateColumn)” wasn’t found."])
        }
        let descriptionIndex = mapping.descriptionColumn.flatMap { headers.firstIndex(of: $0) }
        let merchantIndex = mapping.merchantColumn.flatMap { headers.firstIndex(of: $0) }
        let amountIndex = mapping.amountColumn.flatMap { headers.firstIndex(of: $0) }
        let debitIndex = mapping.debitColumn.flatMap { headers.firstIndex(of: $0) }
        let creditIndex = mapping.creditColumn.flatMap { headers.firstIndex(of: $0) }

        guard amountIndex != nil || debitIndex != nil || creditIndex != nil else {
            return CSVImportResult(warnings: ["No amount column was found."])
        }

        let dateParser = ImportDateParser(preferred: mapping.dateFormat)
        var transactions: [ImportedTransaction] = []
        var skipped = 0

        for row in document.dataRows {
            guard let rawDate = value(row, dateIndex),
                  let date = dateParser.date(from: rawDate) else {
                skipped += 1
                continue
            }

            let amount = amountMinorUnits(
                row: row,
                columns: AmountColumns(
                    amountIndex: amountIndex,
                    debitIndex: debitIndex,
                    creditIndex: creditIndex,
                    flipsSign: mapping.flipsSign
                ),
                exponent: currency.exponent
            )
            guard let amount else {
                skipped += 1
                continue
            }

            let description = value(row, descriptionIndex) ?? value(row, merchantIndex) ?? ""
            let merchant = value(row, merchantIndex) ?? description
            guard !description.isEmpty || !merchant.isEmpty else {
                skipped += 1
                continue
            }

            transactions.append(
                ImportedTransaction(
                    date: date,
                    description: description.isEmpty ? merchant : description,
                    merchant: merchant,
                    amountMinorUnits: amount
                )
            )
        }

        return CSVImportResult(transactions: transactions, skippedRows: skipped)
    }

    private static func value(_ row: [String], _ index: Int?) -> String? {
        guard let index, index < row.count else { return nil }
        let text = row[index].trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The signed-amount columns for one CSV preset.
    private struct AmountColumns {
        let amountIndex: Int?
        let debitIndex: Int?
        let creditIndex: Int?
        let flipsSign: Bool
    }

    private static func amountMinorUnits(
        row: [String],
        columns: AmountColumns,
        exponent: Int
    ) -> Int64? {
        if let debitIndex = columns.debitIndex,
           let debit = value(row, debitIndex),
           let magnitude = parseMagnitude(debit, exponent: exponent) {
            return columns.flipsSign ? abs(magnitude) : -abs(magnitude)
        }
        if let creditIndex = columns.creditIndex,
           let credit = value(row, creditIndex),
           let magnitude = parseMagnitude(credit, exponent: exponent) {
            return columns.flipsSign ? -abs(magnitude) : abs(magnitude)
        }
        if let amountIndex = columns.amountIndex, let raw = value(row, amountIndex) {
            return parseAmount(raw, flipsSign: columns.flipsSign, exponent: exponent)
        }
        return nil
    }

    static func parseAmount(_ raw: String, flipsSign: Bool, exponent: Int) -> Int64? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var negative = false
        if text.hasPrefix("("), text.hasSuffix(")") {
            negative = true
            text = String(text.dropFirst().dropLast())
        }
        text = text.replacingOccurrences(of: ",", with: "")
        text = text.replacingOccurrences(of: "$", with: "")
        text = text.replacingOccurrences(of: "USD", with: "", options: .caseInsensitive)
        text = text.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("-") {
            negative.toggle()
            text = String(text.dropLast())
        }
        if text.hasPrefix("-") {
            negative.toggle()
            text = String(text.dropFirst())
        }
        guard let magnitude = MinorUnits.parse(text, exponent: exponent) else { return nil }
        let value = negative ? -abs(magnitude) : magnitude
        return flipsSign ? -value : value
    }

    /// Parses a magnitude, ignoring any sign (used for split debit/credit columns).
    static func parseMagnitude(_ raw: String, exponent: Int) -> Int64? {
        parseAmount(raw, flipsSign: false, exponent: exponent).map(abs)
    }
}

/// Builds and reuses date formatters for one import run.
struct ImportDateParser {
    private let formatters: [DateFormatter]

    init(preferred: ImportDateFormat) {
        let patterns = preferred.patterns
            + ImportDateFormat.allCases.filter { $0 != preferred }.flatMap(\.patterns)
        formatters = patterns.map { pattern in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = pattern
            formatter.isLenient = false
            return formatter
        }
    }

    func date(from text: String) -> Date? {
        if let iso = ISO8601DateFormatter().date(from: text) {
            return iso
        }
        for formatter in formatters {
            if let date = formatter.date(from: text) {
                return date
            }
        }
        return nil
    }
}
