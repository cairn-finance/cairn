import Foundation

/// Formats and describes a monetary amount held as minor units.
public struct Money: Hashable, Sendable {
    public var minorUnits: Int64
    public var currency: Currency

    public init(minorUnits: Int64, currency: Currency) {
        self.minorUnits = minorUnits
        self.currency = currency
    }

    public var decimal: Decimal {
        MinorUnits.decimal(minorUnits, exponent: currency.exponent)
    }

    public var isNegative: Bool { minorUnits < 0 }
    public var isZero: Bool { minorUnits == 0 }

    /// A localized currency string. ISO currencies use the platform currency
    /// format; custom currencies are rendered with their abbreviation or name.
    public func formatted(locale: Locale = .autoupdatingCurrent) -> String {
        if currency.isCustom {
            let amount = decimal.formatted(.number.precision(.fractionLength(currency.exponent)).locale(locale))
            let unit = currency.customAbbreviation ?? currency.customName ?? ""
            return unit.isEmpty ? amount : "\(amount) \(unit)"
        }
        return decimal.formatted(.currency(code: currency.code).locale(locale))
    }
}
