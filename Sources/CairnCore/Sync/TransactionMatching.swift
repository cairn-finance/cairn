import Foundation

/// A pending transaction considered for promotion to a posted one.
public struct PendingTransactionCandidate: Sendable, Hashable {
    public let id: String
    public let accountID: String
    public let amountMinorUnits: Int64
    public let description: String
    public let transactedAt: Date?

    public init(id: String, accountID: String, amountMinorUnits: Int64, description: String, transactedAt: Date?) {
        self.id = id
        self.accountID = accountID
        self.amountMinorUnits = amountMinorUnits
        self.description = description
        self.transactedAt = transactedAt
    }
}

/// A posted transaction that a pending one may correspond to.
public struct PostedTransactionCandidate: Sendable, Hashable {
    public let id: String
    public let accountID: String
    public let amountMinorUnits: Int64
    public let description: String
    public let postedDate: Date?

    public init(id: String, accountID: String, amountMinorUnits: Int64, description: String, postedDate: Date?) {
        self.id = id
        self.accountID = accountID
        self.amountMinorUnits = amountMinorUnits
        self.description = description
        self.postedDate = postedDate
    }
}

/// Matches pending transactions to their posted counterparts.
///
/// Many banks do not reuse the transaction id when a charge posts — the pending
/// record disappears and a brand-new posted record appears. Promotion therefore
/// cannot rely on ids alone and uses amount, timing, and description similarity.
///
/// This is deliberately a pure function so it can be exhaustively unit-tested
/// against real-world fixture pairs.
public enum TransactionMatching {
    public static let defaultWindowDays = 5
    public static let similarityThreshold = 0.45

    /// Returns the id of the best matching posted transaction, or `nil`.
    public static func findMatch(
        for pending: PendingTransactionCandidate,
        among posted: [PostedTransactionCandidate],
        windowDays: Int = defaultWindowDays,
        calendar: Calendar = .current
    ) -> String? {
        let sameAccount = posted.filter {
            $0.accountID == pending.accountID && $0.amountMinorUnits == pending.amountMinorUnits
        }
        guard !sameAccount.isEmpty else { return nil }

        var best: (id: String, score: Double)?

        for candidate in sameAccount {
            if let transactedAt = pending.transactedAt, let postedDate = candidate.postedDate {
                let distance = abs(postedDate.timeIntervalSince(transactedAt))
                let window = Double(windowDays) * 86_400
                // A small negative tolerance handles timezone/rounding drift.
                if distance > window + 3_600 { continue }
            }

            var score = TextSimilarity.ratio(pending.description, candidate.description)
            // An exact amount plus a containment relationship is strong enough
            // even when wording differs a little.
            if score < similarityThreshold,
               let a = normalized(pending.description),
               let b = normalized(candidate.description),
               !a.isEmpty, !b.isEmpty,
               a.contains(b) || b.contains(a) {
                score = max(score, similarityThreshold + 0.1)
            }

            if score >= similarityThreshold, score > (best?.score ?? 0) {
                best = (candidate.id, score)
            }
        }

        return best?.id
    }

    private static func normalized(_ text: String) -> String? {
        let stripped = TextSimilarity.normalize(text)
        return stripped.isEmpty ? nil : stripped
    }
}

/// Levenshtein-based string similarity, used to compare bank descriptions.
public enum TextSimilarity {
    /// Normalizes to lowercase alphanumeric tokens separated by single spaces.
    public static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }
        let joined = String(scalars)
        return joined.split(separator: " ").joined(separator: " ")
    }

    /// Returns a value in `0...1`, where 1 means identical after normalization.
    public static func ratio(_ lhs: String, _ rhs: String) -> Double {
        let a = normalize(lhs)
        let b = normalize(rhs)
        if a == b { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }

        let distance = levenshtein(Array(a), Array(b))
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 0 }
        return 1 - (Double(distance) / Double(longest))
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,        // deletion
                    current[j - 1] + 1,     // insertion
                    previous[j - 1] + cost  // substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
