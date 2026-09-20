import Foundation
import CairnCore

/// Manual-account editing reached from the UI. Kept in its own file so the main
/// `AppModel` stays focused on sync and coordination.
@MainActor
extension AppModel {
    /// Adds a transaction the person typed into a manual account.
    @discardableResult
    func addManualTransaction(_ entry: ManualEntry, to account: Account) async -> Bool {
        do {
            _ = try await engine.addManualTransaction(entry, toAccountID: account.persistentModelID)
            await refreshRecurring()
            return true
        } catch {
            reportManualError(error)
            return false
        }
    }

    /// Applies an edit to an existing manual transaction.
    @discardableResult
    func updateManualTransaction(_ entry: ManualEntry, transaction: LedgerTransaction) async -> Bool {
        do {
            try await engine.updateManualTransaction(entry, transactionID: transaction.persistentModelID)
            await refreshRecurring()
            return true
        } catch {
            reportManualError(error)
            return false
        }
    }

    /// Deletes a manual transaction.
    @discardableResult
    func deleteManualTransaction(_ transaction: LedgerTransaction) async -> Bool {
        do {
            try await engine.deleteManualTransaction(transactionID: transaction.persistentModelID)
            await refreshRecurring()
            return true
        } catch {
            reportManualError(error)
            return false
        }
    }

    /// Renames a manual account.
    @discardableResult
    func renameManualAccount(_ account: Account, to name: String) async -> Bool {
        do {
            try await engine.renameManualAccount(accountID: account.persistentModelID, name: name)
            return true
        } catch {
            reportManualError(error)
            return false
        }
    }

    /// Deletes a manual account and everything in it.
    @discardableResult
    func deleteManualAccount(_ account: Account) async -> Bool {
        do {
            try await engine.deleteManualAccount(accountID: account.persistentModelID)
            await refreshRecurring()
            return true
        } catch {
            reportManualError(error)
            return false
        }
    }

    private func reportManualError(_ error: any Error) {
        let message = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        banner = message
        Task { await cairnLog(.warning, "Manual editing failed: \(message)") }
    }
}
