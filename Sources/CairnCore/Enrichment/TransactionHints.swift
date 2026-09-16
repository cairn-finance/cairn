import Foundation

/// Cheap, deterministic hints that keep obvious money movement and obvious
/// charges away from the spending categories.
///
/// The important distinction: the word "overdraft" describes *why* money moved,
/// not a charge. "Overdraft to checking" is a transfer between the person's own
/// accounts; an actual charge is named ("overdraft fee", "service charge"). A
/// language model should never have to infer that, and neither should rules.
public enum TransactionHints {
    /// What a money-movement row actually is. Money movement is never spending,
    /// but card and loan payments deserve a label of their own rather than the
    /// generic "Transfer".
    public enum MoneyMovementKind: Sendable, Equatable {
        case transfer
        case creditCardPayment
        case loanPayment

        /// The default category this kind maps to, or nil for a plain transfer.
        public var categoryName: String? {
            switch self {
            case .transfer: nil
            case .creditCardPayment: "Credit Card Payments"
            case .loanPayment: "Loan Payments"
            }
        }
    }

    /// Signals that a row is money moving between the person's own accounts, a
    /// credit-card payment, or a peer-to-peer payment — not spending.
    private static let transferSubstrings: [String] = [
        "transfer", "xfer",
        "overdraft protection", "overdraft to", "overdraft from",
        "to savings", "from savings", "to checking", "from checking",
        "internal transfer", "account transfer", "online banking transfer",
        "sweep to", "sweep from", "rebalance",
        "credit card payment", "card payment", "payment to card", "payment - thank you",
        "payment thank you", "payment thankyou", "cardmember payment",
        "zelle", "venmo", "cash app", "cashapp", "apple cash",
        "withdrawal to", "deposit from",
        // Brokerage activity moves cash into or out of an investment, it isn't
        // spending. A dividend payout stays Income; a reinvestment or a buy does
        // not.
        "reinvestment", "you bought", "you sold", "you purchased",
        "buy order", "sell order", "stock purchase", "share purchase",
    ]

    /// Phrases that name a payment *to* a credit card, so it can be labeled
    /// "Credit Card Payments" instead of the generic "Transfer". Auto-payment
    /// wording only counts when a card is named: "AUTOPAY" alone is how people
    /// pay utility bills, which is spending, not money movement.
    private static let creditCardPaymentSubstrings: [String] = [
        "credit card payment", "card payment", "payment to card", "payment to credit card",
        "cardmember payment", "payment thank you", "payment thankyou",
        "payment - thank you", "card autopay", "credit card autopay",
        "autopay to card", "credit crd",
    ]

    /// Phrases that name a payment toward a loan or mortgage.
    private static let loanPaymentSubstrings: [String] = [
        "loan payment", "loan pmt", "loan due", "loan installment",
        "auto loan", "car loan", "student loan", "mortgage payment", "mortgage",
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

    /// Words that name money arriving rather than leaving. Kept to explicit
    /// labels so a refund is never mistaken for pay.
    private static let incomeSubstrings: [String] = [
        "payroll", "salary", "wage", "direct dep", "direct deposit",
        "interest payment", "interest earned", "interest credit",
        "dividend", "tax refund", "tax return", "treasury", "irs treas",
        "social security", "ssa treas", "benefit payment", "pension",
        "annuity", "reimbursement",
    ]

    /// Counterparties that are themselves financial institutions. Money sent to
    /// a card issuer, bank, credit union, or brokerage moves between the
    /// person's own accounts rather than buying something.
    private static let financialCounterparties: [String] = [
        "robinhood", "vanguard", "fidelity", "schwab", "e*trade", "etrade",
        "betterment", "wealthfront", "acorns", "stash", "m1 finance",
        "coinbase", "kraken", "gemini", "merrill", "morgan stanley",
        "bilt", "amex", "american express", "chase", "capital one",
        "discover card", "discover bank", "citi", "wells fargo",
        "bank of america", "citibank", "us bank", "td bank", "pnc bank",
        "truist", "fifth third", "keybank", "usaa", "navy federal",
        "sofi", "ally bank", "marcus", "credit union",
        "brokerage", "investments", "mortgage",
        "loan payment", "auto loan", "student loan",
    ]

    public static func isInternalTransfer(description: String, merchant: String = "") -> Bool {
        guard !isExplicitFee(description: description) else { return false }
        let haystack = normalized(description: description, merchant: merchant)
        guard !haystack.isEmpty else { return false }
        return transferSubstrings.contains { haystack.contains($0) }
    }

    /// Money movement that the generic keywords miss: a counterparty that is one
    /// of the person's own accounts or institutions, or a well-known card issuer,
    /// bank, credit union, or brokerage.
    public static func isTransferToInstitution(
        description: String,
        merchant: String = "",
        counterparties: [String] = []
    ) -> Bool {
        guard !isExplicitFee(description: description) else { return false }
        let haystack = normalized(description: description, merchant: merchant)
        guard !haystack.isEmpty else { return false }
        if financialCounterparties.contains(where: { containsWord($0, in: haystack) }) { return true }
        return counterparties.contains { matchesCounterparty(haystack, name: $0) }
    }

    /// A payment to a credit card, so it can carry the "Credit Card Payments"
    /// label rather than the generic transfer label.
    public static func isCreditCardPayment(description: String, merchant: String = "") -> Bool {
        guard !isExplicitFee(description: description) else { return false }
        let haystack = normalized(description: description, merchant: merchant)
        guard !haystack.isEmpty else { return false }
        return creditCardPaymentSubstrings.contains { haystack.contains($0) }
    }

    /// A payment toward a loan or mortgage.
    public static func isLoanPayment(description: String, merchant: String = "") -> Bool {
        guard !isExplicitFee(description: description) else { return false }
        let haystack = normalized(description: description, merchant: merchant)
        guard !haystack.isEmpty else { return false }
        return loanPaymentSubstrings.contains { haystack.contains($0) }
    }

    /// Either kind of money movement, in one call.
    public static func isMoneyMovement(
        description: String,
        merchant: String = "",
        counterparties: [String] = []
    ) -> Bool {
        isInternalTransfer(description: description, merchant: merchant)
            || isTransferToInstitution(description: description, merchant: merchant, counterparties: counterparties)
    }

    /// Classifies money movement as a card payment, a loan payment, or a plain
    /// transfer. The specific kinds are checked first so a card or loan payment
    /// is never collapsed into the generic "Transfer".
    public static func moneyMovement(
        description: String,
        merchant: String = "",
        counterparties: [String] = []
    ) -> MoneyMovementKind? {
        if isLoanPayment(description: description, merchant: merchant) { return .loanPayment }
        if isCreditCardPayment(description: description, merchant: merchant) { return .creditCardPayment }
        if isMoneyMovement(description: description, merchant: merchant, counterparties: counterparties) {
            return .transfer
        }
        return nil
    }

    public static func isExplicitFee(description: String) -> Bool {
        let haystack = normalized(description: description, merchant: "")
        guard !haystack.isEmpty else { return false }
        if haystack == "fee" || haystack.hasPrefix("fee ") { return true }
        if haystack == "nsf" || haystack.hasPrefix("nsf ") { return true }
        return feeSubstrings.contains { haystack.contains($0) }
    }

    /// A fee is always money leaving the account. A credit (or a zero amount)
    /// can never be a fee, no matter what the description says — banks label
    /// reversals and adjustments "fee" too.
    public static func isExplicitFee(description: String, amountMinorUnits: Int64) -> Bool {
        guard amountMinorUnits < 0 else { return false }
        return isExplicitFee(description: description)
    }

    /// A deposit that is clearly pay rather than a transfer or a refund.
    /// Requires a positive amount and an explicit income label.
    public static func isIncome(description: String, amountMinorUnits: Int64) -> Bool {
        guard amountMinorUnits > 0 else { return false }
        guard !isExplicitFee(description: description) else { return false }
        let haystack = normalized(description: description, merchant: "")
        guard !haystack.isEmpty else { return false }
        return incomeSubstrings.contains { haystack.contains($0) }
    }

    /// A counterparty name only counts when the whole normalized name appears on
    /// word boundaries, so "American Express" matches but "American" alone never
    /// does — and an account named "Chase" no longer matches "pur**chase**".
    /// Partial brand matching is handled by `financialCounterparties` instead.
    private static func matchesCounterparty(_ haystack: String, name: String) -> Bool {
        let key = normalized(description: name, merchant: "")
        guard key.count >= 4 else { return false }
        return containsWord(key, in: haystack)
    }

    /// Whether `needle` appears in `haystack` on word boundaries.
    ///
    /// Plain substring matching is unsafe for institution names: the bank
    /// "Chase" is a substring of "pur**chase**", so a card purchase such as
    /// "PURCHASE AUTHORIZED ON…" would be misread as a transfer to Chase and
    /// drop out of spending, Insights, and subscription detection. Boundaries
    /// also stop "citi" from matching "citizen".
    private static func containsWord(_ needle: String, in haystack: String) -> Bool {
        guard !needle.isEmpty else { return false }
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            let before = range.lowerBound == haystack.startIndex
                ? nil
                : haystack[haystack.index(before: range.lowerBound)]
            let after = range.upperBound == haystack.endIndex
                ? nil
                : haystack[range.upperBound]
            let leftClean = before.map { !$0.isLetter && !$0.isNumber } ?? true
            let rightClean = after.map { !$0.isLetter && !$0.isNumber } ?? true
            if leftClean, rightClean { return true }
            searchStart = range.upperBound
        }
        return false
    }

    private static func normalized(description: String, merchant: String) -> String {
        let combined = merchant.isEmpty ? description : "\(description) \(merchant)"
        return combined
            .lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
    }
}
