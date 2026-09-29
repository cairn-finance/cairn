import Foundation

/// A detached view of a commitment that can cross the store actor boundary.
public struct ConfirmedCommitmentSnapshot: Sendable, Equatable, Identifiable {
    public let uuid: UUID
    public let detectorID: String
    public let name: String
    public let amountMinorUnits: Int64
    public let currency: Currency
    public let cadence: RecurringCadence
    public let nextDueDate: Date
    public let accountScope: String
    public let state: CommitmentState

    public var id: UUID { uuid }

    public init(_ commitment: ConfirmedCommitment) {
        uuid = commitment.uuid
        detectorID = commitment.detectorID
        name = commitment.name
        amountMinorUnits = commitment.amountMinorUnits
        currency = commitment.currency
        cadence = commitment.cadence
        nextDueDate = commitment.nextDueDate
        accountScope = commitment.accountScope
        state = commitment.state
    }
}
