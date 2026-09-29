import Foundation

public enum BudgetExpenseSmoothingError: Error, LocalizedError, Sendable {
    case transactionNotFound
    case transactionNotEligible
    case invalidName
    case invalidDuration
    case invalidMonth

    public var errorDescription: String? {
        switch self {
        case .transactionNotFound:
            "That transaction is no longer available."
        case .transactionNotEligible:
            "Only posted expenses that count toward budgets and are not ignored, transfers, or shared expenses can be spread across budget months."
        case .invalidName:
            "Give this schedule a name of up to 80 characters."
        case .invalidDuration:
            "Choose a schedule between 2 and 60 months."
        case .invalidMonth:
            "Choose a start month on or after the purchase month."
        }
    }
}

public struct BudgetExpenseSmoothingInput: Sendable, Hashable {
    public let accountIDIndex: String
    public let bankTransactionID: String
    public let name: String
    public let startMonthKey: String
    public let durationMonths: Int
    public let timeZoneIdentifier: String

    public init(
        accountIDIndex: String,
        bankTransactionID: String,
        name: String,
        startMonthKey: String,
        durationMonths: Int,
        timeZoneIdentifier: String
    ) {
        self.accountIDIndex = accountIDIndex
        self.bankTransactionID = bankTransactionID
        self.name = name
        self.startMonthKey = startMonthKey
        self.durationMonths = durationMonths
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

public struct BudgetSmoothingAllocation: Sendable, Hashable, Identifiable {
    public let planID: UUID
    public let name: String
    public let payeeDescription: String
    /// The same account/transaction composite key used by transaction rows.
    public let sourceTransactionID: String
    public let monthKey: String
    public let installmentNumber: Int
    public let installmentCount: Int
    public let amountMinorUnits: Int64
    public let totalMinorUnits: Int64

    public var id: String { "\(planID.uuidString)-\(monthKey)" }

    public init(
        planID: UUID,
        name: String,
        payeeDescription: String,
        sourceTransactionID: String,
        monthKey: String,
        installmentNumber: Int,
        installmentCount: Int,
        amountMinorUnits: Int64,
        totalMinorUnits: Int64
    ) {
        self.planID = planID
        self.name = name
        self.payeeDescription = payeeDescription
        self.sourceTransactionID = sourceTransactionID
        self.monthKey = monthKey
        self.installmentNumber = installmentNumber
        self.installmentCount = installmentCount
        self.amountMinorUnits = amountMinorUnits
        self.totalMinorUnits = totalMinorUnits
    }
}

struct BudgetSmoothingTransactionKey: Hashable, Sendable {
    let accountIDIndex: String
    let bankTransactionID: String

    init(accountIDIndex: String, bankTransactionID: String) {
        self.accountIDIndex = accountIDIndex
        self.bankTransactionID = bankTransactionID
    }
}

public enum BudgetExpenseSmoothingCalculator {
    public static let minimumMonths = 2
    public static let maximumMonths = 60
    public static let maximumNameLength = 80

    /// Distributes every minor unit across the schedule. Any remainder goes to
    /// the earliest months so the sum always equals the posted amount.
    public static func allocationAmount(
        totalMinorUnits: Int64,
        monthIndex: Int,
        monthCount: Int
    ) -> Int64? {
        guard totalMinorUnits >= 0,
              (minimumMonths...maximumMonths).contains(monthCount),
              (0..<monthCount).contains(monthIndex) else {
            return nil
        }
        let divisor = Int64(monthCount)
        let base = totalMinorUnits / divisor
        let remainder = totalMinorUnits % divisor
        return base + (Int64(monthIndex) < remainder ? 1 : 0)
    }
}

public extension CairnSchemaV4.LedgerTransaction {
    var isEligibleForBudgetExpenseSmoothing: Bool {
        amountMinorUnits < 0
            && !isPending
            && !isIgnored
            && !countsAsTransfer
            && settlementID == nil
            && !BudgetCalculator.isExcludedCategory(effectiveCategory?.name)
    }
}
