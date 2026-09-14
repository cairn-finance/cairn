import Foundation

/// Cleans raw bank/CSV descriptions into a stable, human-readable merchant name.
///
/// Deterministic and on-device. Used to group transactions, detect recurring
/// charges, and de-duplicate imports. The result preserves the original casing
/// where possible; callers compare case-insensitively.
public enum MerchantNormalizer {
    /// Store/order numbers, e.g. `#1234` or a trailing 4+ digit run.
    private static let trailingNumberPattern = #"\s+#?\d{3,}\b"#
    /// A trailing hash code with no spaces, e.g. `#A1B2C3`.
    private static let trailingHashCodePattern = #"\s*#[A-Za-z0-9]+$"#
    /// A trailing US state abbreviation, optionally with a ZIP code.
    private static let trailingStatePattern = #"\s+[A-Z]{2}(\s+\d{5}(-\d{4})?)?$"#
    private static let whitespacePattern = #"\s+"#
    /// Anything from a bare `*` onward, e.g. processor metadata.
    private static let asteriskSuffixPattern = #"\s*\*.*$"#

    /// Payment processors that pass the real merchant name after an `*`.
    private static let markerPrefixes = [
        "sq *", "sq*", "tst*", "tst *", "sp *", "sp*", "wpy*", "wl *",
        "paypal *", "paypal*", "pp*", "pp *", "toast*",
    ]

    /// Noise prefixes that carry no merchant information.
    private static let noisePrefixes = [
        "pos debit ", "pos purchase ", "debit card purchase ", "checkcard ",
        "ach debit ", "ach credit ", "recurring payment ", "web authorized pmt ",
        "purchase authorized on ", "card purchase ", "visa purchase ", "external withdrawal ",
        "point of sale withdrawal ", "pos withdrawal ",
    ]

    public static func normalize(_ raw: String) -> String {
        let original = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return "" }

        var text = original
        // Strip leading protocol labels (e.g. "ACH:", "PPD:") so the real
        // merchant is exposed before processor and noise handling.
        text = strippingLeadingLabels(from: text)
        let lowered = text.lowercased()

        // Amazon order suffixes contain opaque codes, so map the whole family.
        if lowered.hasPrefix("amzn") || lowered.hasPrefix("amazon") {
            return "Amazon"
        }

        // Processor that passes the merchant after a marker: take the tail.
        for prefix in markerPrefixes where lowered.hasPrefix(prefix) {
            if let marker = text.range(of: "*") {
                text = String(text[marker.upperBound...])
            }
            break
        }

        // Strip a leading noise phrase once.
        let loweredAfterPrefix = text.lowercased()
        for prefix in noisePrefixes where loweredAfterPrefix.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            break
        }

        // Remove processor metadata and trailing identifiers.
        text = text.replacingOccurrences(of: asteriskSuffixPattern, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: trailingHashCodePattern, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: trailingNumberPattern, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: trailingStatePattern, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: whitespacePattern, with: " ", options: .regularExpression)

        let charactersToTrim = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "-*#.,"))
        text = text.trimmingCharacters(in: charactersToTrim)

        return text.isEmpty ? original : text
    }

    /// Leading protocol labels that carry no merchant information. Stripped
    /// repeatedly so "ACH: PAYPAL *X" still reaches the PayPal handler.
    private static let leadingLabels = [
        "ach:", "pos:", "ppd:", "ccd:", "web:", "tel:", "eft:", "orig:", "pmt:", "payment:",
    ]

    private static func strippingLeadingLabels(from raw: String) -> String {
        var text = raw
        var stripped = true
        while stripped {
            stripped = false
            let lowered = text.lowercased()
            for label in leadingLabels where lowered.hasPrefix(label) {
                text = String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
                stripped = true
                break
            }
        }
        return text
    }

    /// A case-insensitive grouping key for the normalized name.
    public static func groupingKey(_ raw: String) -> String {
        normalize(raw).lowercased()
    }
}
