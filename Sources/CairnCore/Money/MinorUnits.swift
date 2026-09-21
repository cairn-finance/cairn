import Foundation

/// Exact conversion between SimpleFIN's decimal strings and Cairn's integer
/// minor units. All arithmetic is integer-based; no `Double` is involved.
public enum MinorUnits {
    /// Parses a numeric string such as `"-33293.43"` into minor units.
    ///
    /// The decimal separator is taken from `locale`, so `"12,34"` parses in a
    /// comma-decimal locale. A `.` is always accepted as a fallback, which keeps
    /// machine-generated amounts (SimpleFIN payloads always use `.`) working
    /// regardless of the device locale.
    ///
    /// - Returns: `nil` when the string is not a well-formed decimal number.
    public static func parse(_ string: String, exponent: Int, locale: Locale = .autoupdatingCurrent) -> Int64? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var negative = false
        var digits = Substring(trimmed)
        if let first = digits.first, first == "+" || first == "-" {
            negative = first == "-"
            digits = digits.dropFirst()
        }
        guard !digits.isEmpty else { return nil }

        let parts = splitOnDecimalSeparator(digits, locale: locale)
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

    /// Splits a digit string at the locale's decimal separator, falling back to
    /// `.` when the locale separator is absent. At most one split is performed;
    /// a second separator leaves the fraction non-numeric and the parse fails.
    private static func splitOnDecimalSeparator(_ digits: Substring, locale: Locale) -> [Substring] {
        if let separator = locale.decimalSeparator?.first, digits.contains(separator) {
            return digits.split(separator: separator, maxSplits: 1, omittingEmptySubsequences: false)
        }
        return digits.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
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

    // MARK: - Non-trapping arithmetic

    /// Adds two minor-unit amounts without trapping.
    ///
    /// Bank and CSV values are untrusted input, and summing `Int64` traps on
    /// overflow. Clamping keeps a corrupted total finite and obviously wrong
    /// instead of crashing the app in the middle of a sync.
    public static func addClamped(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return sum }
        return rhs >= 0 ? .max : .min
    }

    /// Subtracts without trapping, for the same reason as ``addClamped``.
    public static func subtractClamped(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (difference, overflow) = lhs.subtractingReportingOverflow(rhs)
        guard overflow else { return difference }
        return rhs >= 0 ? .min : .max
    }

    /// `abs` without trapping on `Int64.min`, whose magnitude is not
    /// representable.
    public static func absClamped(_ value: Int64) -> Int64 {
        value == .min ? .max : Swift.abs(value)
    }

    /// Multiplies without trapping, for the same reason as ``addClamped``.
    public static func multiplyClamped(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (product, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard overflow else { return product }
        return lhs.signum() == rhs.signum() ? .max : .min
    }

    /// Converts a rounded floating-point amount into the `Int64` range, saturating
    /// instead of trapping.
    ///
    /// `Int64(_: Double)` is a fatal error when the value is out of range or not a
    /// number, and these conversions sit on values derived from bank input. A
    /// projection is also the easiest place to produce an infinity — a rate
    /// divided by a very small denominator — so this must not be a plain cast.
    public static func clampedFromDouble(_ value: Double) -> Int64 {
        guard value.isFinite else {
            return value > 0 ? .max : (value < 0 ? .min : 0)
        }
        let rounded = value.rounded()
        // `Double(Int64.max)` rounds up past `Int64.max`, so compare against it
        // rather than converting and checking afterwards.
        if rounded >= Double(Int64.max) { return .max }
        if rounded <= Double(Int64.min) { return .min }
        return Int64(rounded)
    }

    private static func powerOfTenDecimal(_ exponent: Int) -> Decimal {
        var result = Decimal(1)
        for _ in 0..<exponent { result *= 10 }
        return result
    }
}
