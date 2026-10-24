import Foundation

public extension SharedExpense {
    var input: SharedExpenseInput {
        get throws {
            SharedExpenseInput(
                uuid: uuid, title: title, date: date, totalMinorUnits: totalMinorUnits,
                currency: try JSONDecoder().decode(Currency.self, from: currencyData),
                participants: try JSONDecoder().decode([ExpenseParticipant].self, from: participantsData),
                payerID: payerID, note: note,
                bankLink: try bankLinkData.map { try JSONDecoder().decode(TrackingBankLink.self, from: $0) },
                isArchived: isArchived
            )
        }
    }
}

public extension SharedExpensePayment {
    var input: SharedPaymentInput {
        get throws {
            SharedPaymentInput(
                uuid: uuid, expenseID: expenseID, participantID: participantID,
                amountMinorUnits: amountMinorUnits, date: date, note: note,
                bankLink: try bankLinkData.map { try JSONDecoder().decode(TrackingBankLink.self, from: $0) }
            )
        }
    }
}

public extension SinkingFund {
    var input: SinkingFundInput {
        get throws {
            guard let state = SinkingFundState(rawValue: stateRaw) else { throw PersonalTrackingError.invalidAmount }
            return SinkingFundInput(
                uuid: uuid, name: name, currency: try JSONDecoder().decode(Currency.self, from: currencyData),
                targetMinorUnits: targetMinorUnits, targetDate: targetDate,
                monthlyContributionMinorUnits: monthlyContributionMinorUnits,
                timeZoneIdentifier: timeZoneIdentifier, state: state, note: note
            )
        }
    }
}

public extension SinkingFundEntry {
    var input: SinkingFundEntryInput {
        get throws {
            guard let kind = SinkingFundEntryKind(rawValue: kindRaw) else { throw PersonalTrackingError.invalidAmount }
            return SinkingFundEntryInput(
                uuid: uuid, fundID: fundID, amountMinorUnits: amountMinorUnits, kind: kind, date: date, note: note
            )
        }
    }
}

public struct PersonalTrackingArchive: Codable, Sendable {
    public var version: Int = 1
    public var expenses: [SharedExpenseInput]
    public var payments: [SharedPaymentInput]
    public var funds: [SinkingFundInput]
    public var entries: [SinkingFundEntryInput]
}
