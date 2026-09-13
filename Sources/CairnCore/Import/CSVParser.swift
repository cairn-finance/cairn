import Foundation

/// A small, allocation-light CSV reader that follows RFC 4180 quoting rules and
/// tolerates CRLF, semicolon/tab/pipe delimiters, and a UTF-8 BOM.
///
/// Financial exports vary a lot; this deliberately does not assume a fixed
/// delimiter or line ending.
public enum CSVParser {
    public static let candidateDelimiters: [Character] = [",", ";", "\t", "|"]

    public struct Document: Sendable {
        public let rows: [[String]]
        public let delimiter: Character

        public var headers: [String] { rows.first ?? [] }
        public var dataRows: [[String]] { rows.count > 1 ? Array(rows.dropFirst()) : [] }
    }

    public static func parse(_ text: String, delimiter explicitDelimiter: Character? = nil) -> Document {
        var content = text
        if content.hasPrefix("\u{FEFF}") {
            content.removeFirst()
        }

        let delimiter = explicitDelimiter ?? sniffDelimiter(content)
        let characters = Array(content)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 2
                        continue
                    }
                    inQuotes = false
                    index += 1
                    continue
                }
                field.append(character)
                index += 1
                continue
            }

            // Note: Swift treats CRLF as a single `Character`, so match any
            // newline grapheme rather than only "\n".
            if character == "\"" {
                inQuotes = true
            } else if character.isNewline {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else if character == delimiter {
                row.append(field)
                field = ""
            } else {
                field.append(character)
            }
            index += 1
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }

        // Drop blank trailing rows and fully empty lines.
        let cleaned = rows.filter { row in
            !(row.count <= 1 && (row.first ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
        }

        return Document(rows: cleaned, delimiter: delimiter)
    }

    /// Chooses the delimiter that appears most often on the first non-empty line,
    /// outside of quotes.
    static func sniffDelimiter(_ text: String) -> Character {
        guard let firstLine = text.split(whereSeparator: { $0.isNewline })
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else {
            return ","
        }

        var inQuotes = false
        var counts: [Character: Int] = [:]
        for character in firstLine {
            if character == "\"" {
                inQuotes.toggle()
                continue
            }
            guard !inQuotes else { continue }
            if candidateDelimiters.contains(character) {
                counts[character, default: 0] += 1
            }
        }

        return candidateDelimiters.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) } ?? ","
    }
}
