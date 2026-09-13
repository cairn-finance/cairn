import Foundation

/// Exact conversion between SimpleFIN's decimal strings and Cairn's integer
/// minor units. All arithmetic is integer-based; no `Double` is involved.
public enum MinorUnits {
    /// Parses a numeric string such as `"-33293.43"` into minor units.
    ///
    /// - Returns: `nil` when the string is not a well-formed decimal number.
    public static func parse(_ string: String, exponent: Int) -> Int64? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var negative = false
        var digits = Substring(trimmed)
        if let first = digits.first, first == "+" || first == "-" {
            negative = first == "-"
            digits = digits.dropFirst()
        }
        guard !digits.isEmpty else { return nil }

        let parts = digits.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let wholePart = parts[0]
        let fractionPart = parts.count > 1 ? parts[1] : ""
        guard !wholePart.isEmpty || !fractionPart.isEmpty else { return nil }
        guard wholePart.allSatisfy(\.isNumber), fractionPart.allSatisfy(\.isNumber) else { return nil }

        let safeExponent = max(0, exponent)
        let padded = fractionPart.count >= safeExponent
            ? String(fractionPart.prefix(safeExponent))
            : String(fractionPart) + String(repeating: "0", count: safeExponent - fractionPart.count)

        guard let wholeValue = Int64(wholePart.isEmpty ? "0" : wholePart),
              let fractionValue = Int64(padded.isEmpty ? "0" : padded) else {
            return nil
        }

        let scale = powerOfTen(safeExponent)
        let (multiplied, overflow) = wholeValue.multipliedReportingOverflow(by: scale)
        guard !overflow else { return nil }
        let (combined, addOverflow) = multiplied.addingReportingOverflow(fractionValue)
        guard !addOverflow else { return nil }

        // Any digits beyond the exponent are truncated toward zero. SimpleFIN
        // amounts are already expressed at the currency's precision.
        return negative ? -combined : combined
    }

    /// Converts minor units back into an exact `Decimal`, for formatting.
    public static func decimal(_ minorUnits: Int64, exponent: Int) -> Decimal {
        Decimal(minorUnits) / powerOfTenDecimal(max(0, exponent))
    }

    /// A locale-independent string representation, useful for export.
    public static func string(_ minorUnits: Int64, exponent: Int) -> String {
        let safeExponent = max(0, exponent)
        guard safeExponent > 0 else { return String(minorUnits) }

        let negative = minorUnits < 0
        let magnitude = minorUnits.magnitude
        let scale = UInt64(powerOfTen(safeExponent))
        let whole = magnitude / scale
        let fraction = magnitude % scale
        let fractionString = String(fraction)
        let padded = String(repeating: "0", count: safeExponent - fractionString.count) + fractionString
        return "\(negative ? "-" : "")\(whole).\(padded)"
    }

    private static func powerOfTen(_ exponent: Int) -> Int64 {
        var result: Int64 = 1
        for _ in 0..<exponent { result *= 10 }
        return result
    }

    private static func powerOfTenDecimal(_ exponent: Int) -> Decimal {
        var result = Decimal(1)
        for _ in 0..<exponent { result *= 10 }
        return result
    }
}
