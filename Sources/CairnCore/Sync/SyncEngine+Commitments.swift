import Foundation
import SwiftData

public extension SyncEngine {
    func confirmedCommitments() throws -> [ConfirmedCommitment] {
        try modelContext.fetch(FetchDescriptor<ConfirmedCommitment>(sortBy: [SortDescriptor(\.nextDueDate)]))
    }

    func exportCommitmentsCSV() throws -> String {
        let rows = try confirmedCommitments().map {
            CommitmentExportRow(
                name: $0.name,
                amount: Money(minorUnits: $0.amountMinorUnits, currency: $0.currency).formatted(),
                currency: $0.currency.code,
                cadence: String(localized: "\($0.cadence.displayName)"),
                nextDue: $0.nextDueDate,
                state: $0.state.rawValue,
                accountScope: $0.accountScope
            )
        }
        return Exporters.commitmentsCSV(rows: rows)
    }

    func confirm(_ series: RecurringSeries, name: String? = nil, now: Date = .now) throws {
        try reconcileCommitments(with: [series], now: now)
        if try confirmedCommitments().contains(where: { $0.detectorID == series.id }) { return }
        let commitment = ConfirmedCommitment(
            detectorID: series.id,
            name: name ?? series.displayName,
            amountMinorUnits: series.averageAmountMinorUnits,
            currency: series.currency,
            cadence: series.cadence,
            nextDueDate: series.nextExpectedDate,
            accountScope: series.accountID
        )
        commitment.lastObservedDate = series.lastDate
        commitment.lastObservedAmountMinorUnits = series.latestAmountMinorUnits
        commitment.modifiedAt = now
        modelContext.insert(commitment)
        try modelContext.save()
    }

    /// Reconciles observation-only fields with the latest detected evidence and
    /// collapses duplicate confirmations that can arrive from two synced devices.
    /// User-owned name, amount, cadence, state, and scope remain authoritative;
    /// an observed payment advances a due date only after that date has passed.
    func reconcileCommitments(with series: [RecurringSeries], now: Date = .now) throws {
        let commitments = try confirmedCommitments()
        var changed = false

        for group in Dictionary(grouping: commitments.filter { !$0.detectorID.isEmpty }, by: \.detectorID).values {
            guard let target = group.max(by: {
                if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt < $1.modifiedAt }
                return $0.uuid.uuidString < $1.uuid.uuidString
            }) else { continue }

            for duplicate in group where duplicate.persistentModelID != target.persistentModelID {
                if target.name.isEmpty { target.name = duplicate.name }
                if target.accountScope.isEmpty { target.accountScope = duplicate.accountScope }
                if let observed = duplicate.lastObservedDate,
                   observed > (target.lastObservedDate ?? .distantPast) {
                    target.lastObservedDate = observed
                    target.lastObservedAmountMinorUnits = duplicate.lastObservedAmountMinorUnits
                }
                if duplicate.createdAt < target.createdAt { target.createdAt = duplicate.createdAt }
                modelContext.delete(duplicate)
                changed = true
            }

            guard let evidence = series.first(where: { $0.id == target.detectorID }) else { continue }
            if target.lastObservedDate != evidence.lastDate {
                target.lastObservedDate = evidence.lastDate
                target.lastObservedAmountMinorUnits = evidence.latestAmountMinorUnits
                target.modifiedAt = now
                changed = true
            } else if target.lastObservedAmountMinorUnits != evidence.latestAmountMinorUnits {
                target.lastObservedAmountMinorUnits = evidence.latestAmountMinorUnits
                target.modifiedAt = now
                changed = true
            }

            if target.state == .active,
               target.nextDueDate <= evidence.lastDate,
               evidence.nextExpectedDate > target.nextDueDate {
                target.nextDueDate = evidence.nextExpectedDate
                target.modifiedAt = now
                changed = true
            }
        }

        if changed { try modelContext.save() }
    }

    // Each parameter maps directly to an editable commitment field.
    // swiftlint:disable:next function_parameter_count
    func updateCommitment(
        _ commitment: ConfirmedCommitment,
        name: String,
        amountMinorUnits: Int64,
        cadence: RecurringCadence,
        nextDueDate: Date,
        state: CommitmentState,
        accountScope: String,
        now: Date = .now
    ) throws {
        commitment.name = name
        commitment.amountMinorUnits = amountMinorUnits
        commitment.cadenceRaw = cadence.rawValue
        commitment.nextDueDate = nextDueDate
        commitment.stateRaw = state.rawValue
        commitment.accountScope = accountScope
        commitment.modifiedAt = now
        try modelContext.save()
    }

    func forecast(days: Int = 30, now: Date = .now) throws -> [ForecastBalance] {
        let accounts = try modelContext.fetch(FetchDescriptor<Account>())
            .filter { !$0.isHidden }
            .map {
                ForecastAccount(
                    balanceMinorUnits: $0.balanceMinorUnits,
                    currency: $0.currency,
                    asOf: $0.balanceDate ?? $0.lastSyncedAt
                )
            }
        let values = try confirmedCommitments().map {
            ConfirmedCommitmentValue(
                amountMinorUnits: $0.amountMinorUnits,
                currency: $0.currency,
                cadence: $0.cadence,
                nextDueDate: $0.nextDueDate,
                state: $0.state,
                uncertain: $0.state == .active && $0.lastObservedDate == nil
            )
        }
        return CashFlowForecast.balances(accounts: accounts, commitments: values, through: days, now: now)
    }

    func systemSurfaceCommitments(now: Date = .now) throws -> [SystemSurfaceCommitment] {
        try confirmedCommitments().filter { $0.state == .active }.map {
            SystemSurfaceCommitment(
                id: $0.detectorID.isEmpty ? $0.uuid.uuidString : $0.detectorID,
                status: CommitmentStatusEvaluator.status(
                    nextDueDate: $0.nextDueDate,
                    now: now,
                    lastObservedDate: $0.lastObservedDate,
                    expectedAmount: $0.amountMinorUnits,
                    observedAmount: $0.lastObservedDate == nil ? nil : $0.lastObservedAmountMinorUnits,
                    uncertain: $0.state == .active && $0.lastObservedDate == nil
                ),
                dueDate: $0.nextDueDate
            )
        }
    }
}
