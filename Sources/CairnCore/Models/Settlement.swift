import Foundation

public enum SettlementRole: String, Codable, Sendable {
    case none
    case expense
    case reimbursement
}

public enum SettlementStatus: String, Codable, Sendable, CaseIterable {
    case expected
    case partial
    case received
    case settled
    case canceled

    public var displayName: String {
        switch self {
        case .expected: "Expected"
        case .partial: "Partial"
        case .received: "Received"
        case .settled: "Settled"
        case .canceled: "Canceled"
        }
    }
}

public struct SettlementSummary: Equatable, Sendable {
    public let grossExpenseMinorUnits: Int64
    public let reimbursementReceivedMinorUnits: Int64
    public let netPersonalCostMinorUnits: Int64
    public let outstandingMinorUnits: Int64
    public let status: SettlementStatus

    public init(
        grossExpenseMinorUnits: Int64,
        reimbursementReceivedMinorUnits: Int64,
        netPersonalCostMinorUnits: Int64,
        outstandingMinorUnits: Int64,
        status: SettlementStatus
    ) {
        self.grossExpenseMinorUnits = grossExpenseMinorUnits
        self.reimbursementReceivedMinorUnits = reimbursementReceivedMinorUnits
        self.netPersonalCostMinorUnits = netPersonalCostMinorUnits
        self.outstandingMinorUnits = outstandingMinorUnits
        self.status = status
    }
}

public enum SettlementValidationError: Error, Equatable, Sendable {
    case expenseMustBeOutgoing
    case reimbursementMustBeIncoming
    case rowsMustBeDifferent
    case currenciesMustMatch
    case expectedAmountMustBePositive
    case alreadyLinked
}

/// Pure settlement rules. A settlement is deliberately a pair of existing bank
/// rows, not a replacement transaction or a transfer classification.
public enum SettlementCalculator {
    public static func validate(
        expenseAmountMinorUnits: Int64,
        reimbursementAmountMinorUnits: Int64,
        sameRow: Bool = false,
        currenciesMatch: Bool = true,
        expectedAmountMinorUnits: Int64? = nil
    ) throws {
        guard expenseAmountMinorUnits < 0 else { throw SettlementValidationError.expenseMustBeOutgoing }
        guard reimbursementAmountMinorUnits > 0 else { throw SettlementValidationError.reimbursementMustBeIncoming }
        guard !sameRow else { throw SettlementValidationError.rowsMustBeDifferent }
        guard currenciesMatch else { throw SettlementValidationError.currenciesMustMatch }
        if let expectedAmountMinorUnits, expectedAmountMinorUnits <= 0 {
            throw SettlementValidationError.expectedAmountMustBePositive
        }
    }

    public static func summary(
        expenseAmountMinorUnits: Int64,
        reimbursementAmountMinorUnits: Int64 = 0,
        expectedAmountMinorUnits: Int64? = nil,
        status: SettlementStatus
    ) -> SettlementSummary {
        let gross = MinorUnits.absClamped(expenseAmountMinorUnits)
        let received = max(0, reimbursementAmountMinorUnits)
        let net = max(0, MinorUnits.subtractClamped(gross, received))
        let expected = max(0, expectedAmountMinorUnits ?? gross)
        return SettlementSummary(
            grossExpenseMinorUnits: gross,
            reimbursementReceivedMinorUnits: received,
            netPersonalCostMinorUnits: net,
            outstandingMinorUnits: max(0, MinorUnits.subtractClamped(expected, received)),
            status: status
        )
    }
}

public extension LedgerTransaction {
    var settlementRole: SettlementRole {
        get { SettlementRole(rawValue: settlementRoleRaw) ?? .none }
        set { settlementRoleRaw = newValue.rawValue }
    }

    var settlementStatus: SettlementStatus {
        get { SettlementStatus(rawValue: settlementStatusRaw) ?? .expected }
        set { settlementStatusRaw = newValue.rawValue }
    }

    var isSettlementLinked: Bool { settlementID != nil && settlementRole != .none }

    /// Links one outgoing row to one incoming row without changing either bank
    /// amount or marking either row as a transfer.
    static func linkSettlement(
        expense: LedgerTransaction,
        reimbursement: LedgerTransaction,
        counterparty: String?,
        expectedAmountMinorUnits: Int64?,
        status: SettlementStatus = .expected,
        now: Date = .now
    ) throws {
        try SettlementCalculator.validate(
            expenseAmountMinorUnits: expense.amountMinorUnits,
            reimbursementAmountMinorUnits: reimbursement.amountMinorUnits,
            sameRow: expense.persistentModelID == reimbursement.persistentModelID,
            expectedAmountMinorUnits: expectedAmountMinorUnits
        )
        guard !expense.isSettlementLinked && !reimbursement.isSettlementLinked else {
            throw SettlementValidationError.alreadyLinked
        }
        let id = UUID()
        expense.settlementID = id
        expense.settlementRole = .expense
        expense.settlementStatus = status
        expense.settlementCounterparty = counterparty
        expense.settlementExpectedAmountMinorUnits = expectedAmountMinorUnits
        expense.settlementLinkedAmountMinorUnits = reimbursement.amountMinorUnits
        reimbursement.settlementID = id
        reimbursement.settlementRole = .reimbursement
        reimbursement.settlementStatus = status
        reimbursement.settlementCounterparty = counterparty
        reimbursement.settlementExpectedAmountMinorUnits = expectedAmountMinorUnits
        reimbursement.settlementLinkedAmountMinorUnits = reimbursement.amountMinorUnits
        expense.modifiedAt = now
        reimbursement.modifiedAt = now
    }

    static func unlinkSettlement(_ rows: [LedgerTransaction], now: Date = .now) {
        for row in rows {
            row.settlementID = nil
            row.settlementRole = .none
            row.settlementStatus = .expected
            row.settlementCounterparty = nil
            row.settlementExpectedAmountMinorUnits = nil
            row.settlementLinkedAmountMinorUnits = nil
            row.modifiedAt = now
        }
    }
}
