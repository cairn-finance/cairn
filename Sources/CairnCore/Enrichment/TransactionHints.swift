import Foundation

/// Cheap, deterministic hints that keep obvious money movement and obvious
/// charges away from the spending categories.
///
/// The important distinction: the word "overdraft" describes *why* money moved,
/// not a charge. "Overdraft to checking" is a transfer between the person's own
/// accounts; an actual charge is named ("overdraft fee", "service charge"). A
/// language model should never have to infer that, and neither should rules.
public enum TransactionHints {
    /// Signals that a row is money moving between the person's own accounts, a
    /// credit-card payment, or a peer-to-peer payment — not spending.
    private static let transferSubstrings: [String] = [
        "transfer", "xfer",
        "overdraft protection", "overdraft to", "overdraft from",
        "to savings", "from savings", "to checking", "from checking",
        "internal transfer", "account transfer", "online banking transfer",
        "sweep to", "sweep from", "rebalance",
        "credit card payment", "card payment", "payment to card", "payment - thank you",
        "autopay", "auto payment", "automatic payment", "e-payment", "epayment",
        "bill pay", "billpay",
        "zelle", "venmo", "cash app", "cashapp", "apple cash",
        "withdrawal to", "deposit from",
    ]

    /// Words that name an actual charge. Deliberately requires an explicit
    /// charge word, and uses a leading space on "fee"/"fees" so "coffee" never
    /// trips it.
    private static let feeSubstrings: [String] = [
        " fee", "fees", "service charge", "maintenance charge",
        "monthly maintenance", "overdraft fee", "nsf fee",
        "insufficient funds", "returned item", "atm fee",
        "foreign transaction", "interest charge", "finance charge",
        "annual fee", "late fee", "convenience fee", "wire fee",
    ]

    public static func isInternalTransfer(description: String, merchant: String = "") -> Bool {
        guard !isExplicitFee(description: description) else { return false }
        let haystack = normalized(description: description, merchant: merchant)
        guard !haystack.isEmpty else { return false }
        return transferSubstrings.contains { haystack.contains($0) }
    }

    public static func isExplicitFee(description: String) -> Bool {
        let haystack = normalized(description: description, merchant: "")
        guard !haystack.isEmpty else { return false }
        if haystack == "fee" || haystack.hasPrefix("fee ") { return true }
        if haystack == "nsf" || haystack.hasPrefix("nsf ") { return true }
        return feeSubstrings.contains { haystack.contains($0) }
    }

    private static func normalized(description: String, merchant: String) -> String {
        let combined = merchant.isEmpty ? description : "\(description) \(merchant)"
        return combined
            .lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
    }
}
