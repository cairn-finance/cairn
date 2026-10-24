import Foundation
import SwiftData

extension SyncEngine {
    public func saveSharedExpense(_ input: SharedExpenseInput, now: Date = .now) throws {
        try SharedExpenseCalculator.validate(input)
        let existing = try trackingExpense(input.uuid)
        let payments = try modelContext.fetch(FetchDescriptor<SharedExpensePayment>())
            .filter { $0.expenseID == input.uuid }.map { try $0.input }
        if let existing, !payments.isEmpty, try existing.input.currency != input.currency {
            throw PersonalTrackingError.invalidCurrency
        }
        if let existing, !payments.isEmpty {
            let previous = try existing.input
            guard previous.payerID == input.payerID,
                  previous.participants.first(where: \.isMe)?.id == input.participants.first(where: \.isMe)?.id else {
                throw PersonalTrackingError.invalidParticipant
            }
        }
        _ = try SharedExpenseCalculator.balances(for: input, payments: payments)
        if input.bankLink != nil {
            guard input.participants.first(where: { $0.id == input.payerID })?.isMe == true else {
                throw PersonalTrackingError.invalidBankLink
            }
        }
        if let link = input.bankLink, try existing?.input.bankLink != link {
            try validateTrackingLink(link, currency: input.currency, amount: -input.totalMinorUnits, excluding: input.uuid)
        }
        // An attached row describes a fixed currency and amount; edits must detach it first.
        if let existing, input.bankLink != nil, try existing.input.bankLink == input.bankLink {
            guard existing.totalMinorUnits == input.totalMinorUnits, try existing.input.currency == input.currency,
                  existing.payerID == input.payerID else { throw PersonalTrackingError.invalidBankLink }
        }
        let currency = try JSONEncoder().encode(input.currency)
        let participants = try JSONEncoder().encode(input.participants)
        let link = try input.bankLink.map { try JSONEncoder().encode($0) }
        try saveTrackingChanges {
            let row = existing ?? SharedExpense(uuid: input.uuid)
            if existing == nil { row.createdAt = now; modelContext.insert(row) }
            row.title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
            row.date = input.date
            row.totalMinorUnits = input.totalMinorUnits
            row.currencyData = currency
            row.participantsData = participants
            row.payerID = input.payerID
            row.note = input.note
            row.bankLinkData = link
            row.isArchived = input.isArchived
            row.modifiedAt = now
        }
    }

    public func addSharedPayment(_ input: SharedPaymentInput, now: Date = .now) throws {
        guard let expense = try trackingExpense(input.expenseID) else { throw PersonalTrackingError.missingRecord }
        let value = try expense.input
        guard !value.isArchived else { throw PersonalTrackingError.missingRecord }
        guard input.date <= now else { throw PersonalTrackingError.invalidDate }
        let rows = try modelContext.fetch(FetchDescriptor<SharedExpensePayment>())
        if let existing = rows.first(where: { $0.uuid == input.uuid }) {
            guard try existing.input == input else { throw PersonalTrackingError.invalidAmount }
            return
        }
        let payments = try rows.filter { $0.expenseID == input.expenseID }.map { try $0.input } + [input]
        _ = try SharedExpenseCalculator.balances(for: value, payments: payments)
        if let link = input.bankLink {
            let paidByMe = value.participants.first(where: { $0.id == value.payerID })?.isMe == true
            try validateTrackingLink(
                link, currency: value.currency, amount: paidByMe ? input.amountMinorUnits : -input.amountMinorUnits,
                excluding: input.uuid
            )
        }
        let link = try input.bankLink.map { try JSONEncoder().encode($0) }
        try saveTrackingChanges {
            let row = SharedExpensePayment(uuid: input.uuid)
            row.expenseID = input.expenseID
            row.participantID = input.participantID
            row.amountMinorUnits = input.amountMinorUnits
            row.date = input.date
            row.note = input.note
            row.bankLinkData = link
            row.createdAt = now
            modelContext.insert(row)
        }
    }

    public func deleteSharedPayment(_ id: UUID) throws {
        let rows = try modelContext.fetch(FetchDescriptor<SharedExpensePayment>()).filter { $0.uuid == id }
        try saveTrackingChanges { for row in rows { modelContext.delete(row) } }
    }

    public func attachSharedPayment(_ id: UUID, to link: TrackingBankLink?) throws {
        let rows = try modelContext.fetch(FetchDescriptor<SharedExpensePayment>())
        guard let payment = rows.first(where: { $0.uuid == id }),
              let expense = try trackingExpense(payment.expenseID) else { throw PersonalTrackingError.missingRecord }
        guard payment.amountMinorUnits > 0 else { throw PersonalTrackingError.invalidAmount }
        let value = try expense.input
        if let link {
            let paidByMe = value.participants.first(where: { $0.id == value.payerID })?.isMe == true
            try validateTrackingLink(link, currency: value.currency,
                                     amount: paidByMe ? payment.amountMinorUnits : -payment.amountMinorUnits, excluding: id)
        }
        let data = try link.map { try JSONEncoder().encode($0) }
        try saveTrackingChanges { payment.bankLinkData = data }
    }

    public func deleteSharedExpense(_ id: UUID) throws {
        let payments = try modelContext.fetch(FetchDescriptor<SharedExpensePayment>()).filter { $0.expenseID == id }
        let expenses = try modelContext.fetch(FetchDescriptor<SharedExpense>()).filter { $0.uuid == id }
        try saveTrackingChanges {
            for row in payments { modelContext.delete(row) }
            for row in expenses { modelContext.delete(row) }
        }
    }

    public func saveSinkingFund(_ input: SinkingFundInput, openingMinorUnits: Int64 = 0, now: Date = .now) throws {
        try SinkingFundCalculator.validate(input)
        guard openingMinorUnits >= 0 else { throw PersonalTrackingError.invalidAmount }
        let existing = try trackingFund(input.uuid)
        let entries = try modelContext.fetch(FetchDescriptor<SinkingFundEntry>())
            .filter { $0.fundID == input.uuid }.map { try $0.input }
        if let existing, !entries.isEmpty, try existing.input.currency != input.currency {
            throw PersonalTrackingError.invalidCurrency
        }
        _ = try SinkingFundCalculator.summary(for: input, entries: entries, now: now)
        let currency = try JSONEncoder().encode(input.currency)
        try saveTrackingChanges {
            let row = existing ?? SinkingFund(uuid: input.uuid)
            if existing == nil {
                row.createdAt = now
                modelContext.insert(row)
                if openingMinorUnits > 0 {
                    let opening = SinkingFundEntry()
                    opening.fundID = input.uuid
                    opening.amountMinorUnits = openingMinorUnits
                    opening.kindRaw = SinkingFundEntryKind.opening.rawValue
                    opening.date = now
                    opening.createdAt = now
                    modelContext.insert(opening)
                }
            }
            row.name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
            row.currencyData = currency
            row.targetMinorUnits = input.targetMinorUnits
            row.targetDate = input.targetDate
            row.monthlyContributionMinorUnits = input.monthlyContributionMinorUnits
            row.timeZoneIdentifier = input.timeZoneIdentifier
            row.stateRaw = input.state.rawValue
            row.note = input.note
            row.modifiedAt = now
        }
    }

    public func addSinkingFundEntry(_ input: SinkingFundEntryInput, now: Date = .now) throws {
        guard let fund = try trackingFund(input.fundID) else { throw PersonalTrackingError.missingRecord }
        let value = try fund.input
        guard value.state == .active || value.state == .paused, input.kind != .opening else {
            throw PersonalTrackingError.invalidAmount
        }
        let rows = try modelContext.fetch(FetchDescriptor<SinkingFundEntry>())
        if let existing = rows.first(where: { $0.uuid == input.uuid }) {
            guard try existing.input == input else { throw PersonalTrackingError.invalidAmount }
            return
        }
        let entries = try rows.filter { $0.fundID == input.fundID }.map { try $0.input } + [input]
        _ = try SinkingFundCalculator.summary(for: value, entries: entries, now: now)
        try saveTrackingChanges {
            let row = SinkingFundEntry(uuid: input.uuid)
            row.fundID = input.fundID
            row.amountMinorUnits = input.amountMinorUnits
            row.kindRaw = input.kind.rawValue
            row.date = input.date
            row.note = input.note
            row.createdAt = now
            modelContext.insert(row)
        }
    }

    public func deleteSinkingFundEntry(_ id: UUID, now: Date = .now) throws {
        let rows = try modelContext.fetch(FetchDescriptor<SinkingFundEntry>())
        guard let row = rows.first(where: { $0.uuid == id }), let fund = try trackingFund(row.fundID) else {
            throw PersonalTrackingError.missingRecord
        }
        let remaining = try rows.filter { $0.fundID == row.fundID && $0.uuid != id }.map { try $0.input }
        _ = try SinkingFundCalculator.summary(for: fund.input, entries: remaining, now: now)
        try saveTrackingChanges { for row in rows where row.uuid == id { modelContext.delete(row) } }
    }

    public func deleteSinkingFund(_ id: UUID) throws {
        let entries = try modelContext.fetch(FetchDescriptor<SinkingFundEntry>()).filter { $0.fundID == id }
        let funds = try modelContext.fetch(FetchDescriptor<SinkingFund>()).filter { $0.uuid == id }
        try saveTrackingChanges {
            for row in entries { modelContext.delete(row) }
            for row in funds { modelContext.delete(row) }
        }
    }

    /// Complete personal records, including participant identities and history.
    /// This export is separate from the bank-ledger export.
    public func exportPersonalTrackingJSON() throws -> Data {
        let archive = PersonalTrackingArchive(
            expenses: try modelContext.fetch(FetchDescriptor<SharedExpense>()).map { try $0.input },
            payments: try modelContext.fetch(FetchDescriptor<SharedExpensePayment>()).map { try $0.input },
            funds: try modelContext.fetch(FetchDescriptor<SinkingFund>()).map { try $0.input },
            entries: try modelContext.fetch(FetchDescriptor<SinkingFundEntry>()).map { try $0.input }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(archive)
    }

    private func trackingExpense(_ id: UUID) throws -> SharedExpense? {
        try modelContext.fetch(FetchDescriptor<SharedExpense>(predicate: #Predicate { $0.uuid == id })).first
    }

    private func trackingFund(_ id: UUID) throws -> SinkingFund? {
        try modelContext.fetch(FetchDescriptor<SinkingFund>(predicate: #Predicate { $0.uuid == id })).first
    }

    private func validateTrackingLink(_ link: TrackingBankLink, currency: Currency, amount: Int64, excluding id: UUID) throws {
        let accountID = link.accountIDIndex
        let transactionID = link.bankTransactionID
        let rows = try modelContext.fetch(FetchDescriptor<LedgerTransaction>(predicate: #Predicate {
            $0.accountIDIndex == accountID && $0.bankTransactionID == transactionID
        }))
        guard let row = rows.first, row.account != nil, !row.isPending,
              row.amount.currency == currency, row.amountMinorUnits == amount else {
            throw PersonalTrackingError.invalidBankLink
        }
        let expenses = try modelContext.fetch(FetchDescriptor<SharedExpense>())
        let payments = try modelContext.fetch(FetchDescriptor<SharedExpensePayment>())
        let expenseLinks = try expenses.filter { $0.uuid != id }.compactMap { try $0.input.bankLink }
        let paymentLinks = try payments.filter { $0.uuid != id }.compactMap { try $0.input.bankLink }
        guard !expenseLinks.contains(link), !paymentLinks.contains(link) else {
            throw PersonalTrackingError.bankRowAlreadyLinked
        }
    }

    private func saveTrackingChanges(_ changes: () throws -> Void) throws {
        do { try modelContext.transaction(block: changes) } catch {
            modelContext.rollback()
            throw error
        }
    }
}
