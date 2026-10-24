import Foundation

/// User-entered amounts must not silently lose precision. The bank parser can
/// truncate provider decimals; personal records require the currency's precision.
public enum PersonalTrackingAmount {
    public static func parse(_ text: String, currency: Currency, locale: Locale = .autoupdatingCurrent) -> Int64? {
        guard (0...6).contains(currency.exponent) else { return nil }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = locale.decimalSeparator ?? "."
        let parts = text.contains(separator) ? text.components(separatedBy: separator) : text.components(separatedBy: ".")
        guard parts.count <= 2, (parts.last?.count ?? 0) <= currency.exponent || parts.count == 1 else { return nil }
        return MinorUnits.parse(text, exponent: currency.exponent, locale: locale)
    }
}

public enum PersonalTrackingError: Error, LocalizedError, Equatable, Sendable {
    case missingRecord, invalidName, invalidAmount, invalidSplit, invalidParticipant
    case overpayment, insufficientFunds, invalidDate, invalidCurrency, invalidBankLink, bankRowAlreadyLinked

    public var errorDescription: String? {
        switch self {
        case .missingRecord: String(localized: "This record no longer exists.")
        case .invalidName: String(localized: "Enter a name of up to 80 characters.")
        case .invalidAmount: String(localized: "Enter a valid amount within the supported range.")
        case .invalidSplit: String(localized: "Shares must add up to the total, with exactly one share for you.")
        case .invalidParticipant: String(localized: "Choose a person who is part of this expense.")
        case .overpayment: String(localized: "The payment exceeds this person's outstanding amount.")
        case .insufficientFunds: String(localized: "This change would leave the fund below zero.")
        case .invalidDate: String(localized: "Recorded contributions and payments cannot be dated in the future.")
        case .invalidCurrency: String(localized: "Choose a valid currency. Currency cannot change after activity is recorded.")
        case .invalidBankLink: String(localized: "Choose a posted transaction with the same currency, direction, and amount.")
        case .bankRowAlreadyLinked: String(localized: "That transaction is already attached to a shared expense or payment.")
        }
    }
}

/// An optional reference, never a second ledger transaction. Missing bank rows
/// leave the personal record intact; pending rows cannot be attached.
public struct TrackingBankLink: Codable, Hashable, Sendable {
    public var accountIDIndex: String
    public var bankTransactionID: String

    public init(accountIDIndex: String, bankTransactionID: String) {
        self.accountIDIndex = accountIDIndex
        self.bankTransactionID = bankTransactionID
    }
}

public struct ExpenseParticipant: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var shareMinorUnits: Int64
    public var isMe: Bool

    public init(id: UUID = UUID(), name: String, shareMinorUnits: Int64 = 0, isMe: Bool = false) {
        self.id = id
        self.name = name
        self.shareMinorUnits = shareMinorUnits
        self.isMe = isMe
    }
}

public struct SharedExpenseInput: Codable, Equatable, Sendable {
    public var uuid: UUID
    public var title: String
    public var date: Date
    public var totalMinorUnits: Int64
    public var currency: Currency
    public var participants: [ExpenseParticipant]
    public var payerID: UUID
    public var note: String
    public var bankLink: TrackingBankLink?
    public var isArchived: Bool

    public init(
        uuid: UUID = UUID(), title: String, date: Date = .now, totalMinorUnits: Int64,
        currency: Currency = .usd, participants: [ExpenseParticipant], payerID: UUID,
        note: String = "", bankLink: TrackingBankLink? = nil, isArchived: Bool = false
    ) {
        self.uuid = uuid
        self.title = title
        self.date = date
        self.totalMinorUnits = totalMinorUnits
        self.currency = currency
        self.participants = participants
        self.payerID = payerID
        self.note = note
        self.bankLink = bankLink
        self.isArchived = isArchived
    }
}

public struct SharedPaymentInput: Codable, Equatable, Identifiable, Sendable {
    public var uuid: UUID
    public var expenseID: UUID
    public var participantID: UUID
    public var amountMinorUnits: Int64
    public var date: Date
    public var note: String
    public var bankLink: TrackingBankLink?
    public var id: UUID { uuid }

    public init(
        uuid: UUID = UUID(), expenseID: UUID, participantID: UUID, amountMinorUnits: Int64,
        date: Date = .now, note: String = "", bankLink: TrackingBankLink? = nil
    ) {
        self.uuid = uuid
        self.expenseID = expenseID
        self.participantID = participantID
        self.amountMinorUnits = amountMinorUnits
        self.date = date
        self.note = note
        self.bankLink = bankLink
    }
}

public struct SharedExpenseBalance: Identifiable, Equatable, Sendable {
    public let participantID: UUID
    public let name: String
    public let owedToMe: Bool
    public let expectedMinorUnits: Int64
    public let paidMinorUnits: Int64
    public var id: UUID { participantID }
    public var outstandingMinorUnits: Int64 { max(0, expectedMinorUnits - paidMinorUnits) }
}

public enum SharedExpenseCalculator {
    /// Exact, deterministic rounding; earlier participants receive the extra minor units.
    public static func equalShares(total: Int64, count: Int) throws -> [Int64] {
        guard total > 0, (2...20).contains(count) else { throw PersonalTrackingError.invalidSplit }
        return (0..<count).map { total / Int64(count) + (Int64($0) < total % Int64(count) ? 1 : 0) }
    }

    public static func validate(_ expense: SharedExpenseInput) throws {
        try PersonalTrackingValidation.name(expense.title)
        try PersonalTrackingValidation.currency(expense.currency)
        guard expense.totalMinorUnits > 0 else { throw PersonalTrackingError.invalidAmount }
        let participants = expense.participants
        guard (2...20).contains(participants.count), participants.filter(\.isMe).count == 1,
              Set(participants.map(\.id)).count == participants.count,
              participants.contains(where: { $0.id == expense.payerID }) else {
            throw PersonalTrackingError.invalidSplit
        }
        var total: Int64 = 0
        for participant in participants {
            try PersonalTrackingValidation.name(participant.name)
            guard participant.shareMinorUnits >= 0 else { throw PersonalTrackingError.invalidSplit }
            total = try PersonalTrackingValidation.add(total, participant.shareMinorUnits)
        }
        guard total == expense.totalMinorUnits else { throw PersonalTrackingError.invalidSplit }
    }

    public static func balances(
        for expense: SharedExpenseInput, payments: [SharedPaymentInput]
    ) throws -> [SharedExpenseBalance] {
        try validate(expense)
        guard let payer = expense.participants.first(where: { $0.id == expense.payerID }) else {
            throw PersonalTrackingError.invalidParticipant
        }
        let counterparties = payer.isMe ? expense.participants.filter { !$0.isMe } : [payer]
        let myShare = expense.participants.first(where: \.isMe)?.shareMinorUnits ?? 0
        let relevant = payments.filter { $0.expenseID == expense.uuid }
        guard Set(relevant.map(\.uuid)).count == relevant.count,
              relevant.allSatisfy({ payment in counterparties.contains { $0.id == payment.participantID } }) else {
            throw PersonalTrackingError.invalidParticipant
        }
        return try counterparties.map { person in
            var paid: Int64 = 0
            for payment in relevant where payment.participantID == person.id {
                guard payment.amountMinorUnits > 0 else { throw PersonalTrackingError.invalidAmount }
                paid = try PersonalTrackingValidation.add(paid, payment.amountMinorUnits)
            }
            let expected = payer.isMe ? person.shareMinorUnits : myShare
            guard paid <= expected else { throw PersonalTrackingError.overpayment }
            return SharedExpenseBalance(
                participantID: person.id, name: person.name, owedToMe: payer.isMe,
                expectedMinorUnits: expected, paidMinorUnits: paid
            )
        }
    }
}

public enum SinkingFundState: String, Codable, Sendable, CaseIterable {
    case active, paused, completed, archived

    public var title: LocalizedStringResource {
        switch self {
        case .active: "Active"
        case .paused: "Paused"
        case .completed: "Completed"
        case .archived: "Archived"
        }
    }
}

public enum SinkingFundEntryKind: String, Codable, Sendable, CaseIterable {
    case opening, contribution, withdrawal, correction

    public var title: LocalizedStringResource {
        switch self {
        case .opening: "Opening amount"
        case .contribution: "Contribution"
        case .withdrawal: "Withdrawal"
        case .correction: "Correction"
        }
    }
}

public struct SinkingFundInput: Codable, Equatable, Sendable {
    public var uuid: UUID
    public var name: String
    public var currency: Currency
    public var targetMinorUnits: Int64
    public var targetDate: Date?
    public var monthlyContributionMinorUnits: Int64
    public var timeZoneIdentifier: String
    public var state: SinkingFundState
    public var note: String

    public init(
        uuid: UUID = UUID(), name: String, currency: Currency = .usd, targetMinorUnits: Int64,
        targetDate: Date? = nil, monthlyContributionMinorUnits: Int64 = 0,
        timeZoneIdentifier: String = TimeZone.current.identifier, state: SinkingFundState = .active, note: String = ""
    ) {
        self.uuid = uuid
        self.name = name
        self.currency = currency
        self.targetMinorUnits = targetMinorUnits
        self.targetDate = targetDate
        self.monthlyContributionMinorUnits = monthlyContributionMinorUnits
        self.timeZoneIdentifier = timeZoneIdentifier
        self.state = state
        self.note = note
    }
}

public struct SinkingFundEntryInput: Codable, Equatable, Sendable {
    public var uuid: UUID
    public var fundID: UUID
    public var amountMinorUnits: Int64
    public var kind: SinkingFundEntryKind
    public var date: Date
    public var note: String

    public init(
        uuid: UUID = UUID(), fundID: UUID, amountMinorUnits: Int64, kind: SinkingFundEntryKind = .contribution,
        date: Date = .now, note: String = ""
    ) {
        self.uuid = uuid
        self.fundID = fundID
        self.amountMinorUnits = amountMinorUnits
        self.kind = kind
        self.date = date
        self.note = note
    }
}

public struct SinkingFundSummary: Equatable, Sendable {
    public let fundedMinorUnits: Int64
    public let remainingMinorUnits: Int64
    public let suggestedMonthlyMinorUnits: Int64?
    public let contributedThisMonthMinorUnits: Int64
    public var progress: Double { Double(fundedMinorUnits) / Double(max(1, fundedMinorUnits + remainingMinorUnits)) }
}

public enum SinkingFundCalculator {
    public static func validate(_ fund: SinkingFundInput) throws {
        try PersonalTrackingValidation.name(fund.name)
        try PersonalTrackingValidation.currency(fund.currency)
        guard fund.targetMinorUnits > 0, fund.monthlyContributionMinorUnits >= 0 else {
            throw PersonalTrackingError.invalidAmount
        }
        guard TimeZone(identifier: fund.timeZoneIdentifier) != nil else { throw PersonalTrackingError.invalidDate }
    }

    public static func summary(
        for fund: SinkingFundInput, entries: [SinkingFundEntryInput], now: Date = .now
    ) throws -> SinkingFundSummary {
        try validate(fund)
        let relevant = entries.filter { $0.fundID == fund.uuid }.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            // Credits precede debits on the same instant, independent of sync order.
            if ($0.amountMinorUnits > 0) != ($1.amountMinorUnits > 0) { return $0.amountMinorUnits > 0 }
            return $0.uuid.uuidString < $1.uuid.uuidString
        }
        guard Set(relevant.map(\.uuid)).count == relevant.count,
              relevant.filter({ $0.kind == .opening }).count <= 1 else { throw PersonalTrackingError.invalidAmount }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: fund.timeZoneIdentifier) ?? .gmt
        var balance: Int64 = 0
        var monthly: Int64 = 0
        for entry in relevant {
            guard entry.date <= now else { throw PersonalTrackingError.invalidDate }
            switch entry.kind {
            case .opening: guard entry.amountMinorUnits >= 0 else { throw PersonalTrackingError.invalidAmount }
            case .contribution: guard entry.amountMinorUnits > 0 else { throw PersonalTrackingError.invalidAmount }
            case .withdrawal: guard entry.amountMinorUnits < 0 else { throw PersonalTrackingError.invalidAmount }
            case .correction: guard entry.amountMinorUnits != 0 else { throw PersonalTrackingError.invalidAmount }
            }
            balance = try PersonalTrackingValidation.add(balance, entry.amountMinorUnits)
            guard balance >= 0 else { throw PersonalTrackingError.insufficientFunds }
            if entry.kind == .contribution, calendar.isDate(entry.date, equalTo: now, toGranularity: .month) {
                monthly = try PersonalTrackingValidation.add(monthly, entry.amountMinorUnits)
            }
        }
        let remaining = max(0, fund.targetMinorUnits - balance)
        var suggested: Int64?
        if let target = fund.targetDate {
            let start = calendar.dateInterval(of: .month, for: now)?.start ?? now
            let end = calendar.dateInterval(of: .month, for: target)?.start ?? target
            let months = max(1, (calendar.dateComponents([.month], from: start, to: end).month ?? 0) + 1)
            let divisor = Int64(months)
            suggested = remaining / divisor + (remaining % divisor > 0 ? 1 : 0)
        }
        return SinkingFundSummary(
            fundedMinorUnits: balance, remainingMinorUnits: remaining, suggestedMonthlyMinorUnits: suggested,
            contributedThisMonthMinorUnits: monthly
        )
    }
}

enum PersonalTrackingValidation {
    static func name(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { throw PersonalTrackingError.invalidName }
    }

    static func currency(_ currency: Currency) throws {
        guard (0...6).contains(currency.exponent), !currency.code.isEmpty else {
            throw PersonalTrackingError.invalidCurrency
        }
        if !currency.isCustom {
            guard currency.code.count == 3, currency.code.allSatisfy({ $0.isASCII && $0.isLetter }) else {
                throw PersonalTrackingError.invalidCurrency
            }
        }
    }

    static func add(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw PersonalTrackingError.invalidAmount }
        return sum
    }
}
