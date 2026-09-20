import Foundation

/// A currency descriptor. Cairn stores monetary values as integer minor units
/// together with one of these, so no floating point error is ever introduced and
/// SwiftData/CloudKit never has to mirror a `Decimal`.
///
/// SimpleFIN supports two kinds of currency:
/// - ISO 4217 codes such as `"USD"` or `"ZMW"` (`isCustom == false`).
/// - Custom currencies identified by a URL, e.g. airline miles (`isCustom == true`).
public struct Currency: Hashable, Sendable, Codable {
    /// ISO 4217 code, or the custom-currency URL for non-monetary currencies.
    public var code: String

    /// Number of digits after the decimal separator in the minor unit.
    /// ISO currencies default to 2; zero-decimal currencies (JPY) use 0.
    public var exponent: Int

    /// Whether `code` is a URL describing a custom currency.
    public var isCustom: Bool

    /// Human-readable name for custom currencies, if known.
    public var customName: String?

    /// Human-readable abbreviation for custom currencies, if known.
    public var customAbbreviation: String?

    public init(
        code: String,
        exponent: Int = 2,
        isCustom: Bool = false,
        customName: String? = nil,
        customAbbreviation: String? = nil
    ) {
        self.code = code
        self.exponent = exponent
        self.isCustom = isCustom
        self.customName = customName
        self.customAbbreviation = customAbbreviation
    }

    /// Builds a currency from a SimpleFIN `currency` string.
    ///
    /// A value that parses as an `http`/`https` URL is treated as a custom
    /// currency query URL; anything else is treated as an ISO code.
    public static func simpleFIN(_ raw: String) -> Currency {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return Currency(code: trimmed, exponent: 2, isCustom: true)
        }
        return Currency(code: trimmed.uppercased(), exponent: Self.defaultExponent(forISOCode: trimmed))
    }

    /// ISO 4217 currencies with no minor unit. Not exhaustive, but covers the
    /// common zero-decimal cases; anything unknown falls back to 2.
    private static let zeroDecimalCodes: Set<String> = [
        "BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW",
        "PYG", "RWF", "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF",
    ]

    public static func defaultExponent(forISOCode code: String) -> Int {
        zeroDecimalCodes.contains(code.uppercased()) ? 0 : 2
    }

    /// A user-facing label for pickers and rows.
    public var displayLabel: LocalizedStringResource {
        if isCustom {
            if let customName { return LocalizedStringResource(stringLiteral: customName) }
            if let customAbbreviation { return LocalizedStringResource(stringLiteral: customAbbreviation) }
            return "Custom"
        }
        return LocalizedStringResource(stringLiteral: code)
    }

    public static let usd = Currency(code: "USD")
}
