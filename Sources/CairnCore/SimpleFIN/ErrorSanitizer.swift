import Foundation

/// Server-provided text is untrusted. It is stripped of control characters and
/// markup, normalized, and length-limited before it is ever shown to a person or
/// written to a log.
public enum ErrorSanitizer {
    public static let maximumLength = 400

    public static func sanitize(_ raw: String) -> String {
        var text = raw

        // Remove HTML/XML tags so a malicious server cannot inject markup.
        text = text.replacingOccurrences(
            of: "<[^>]*>",
            with: " ",
            options: .regularExpression
        )

        // Strip control characters, keeping ordinary whitespace.
        text = String(text.unicodeScalars.filter { scalar in
            if scalar == "\n" || scalar == "\t" { return true }
            return !(scalar.value < 0x20) && scalar.value != 0x7F
        })

        // Collapse runs of whitespace to single spaces.
        text = text.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.count > maximumLength {
            text = String(text.prefix(maximumLength)) + "…"
        }
        return text
    }
}
