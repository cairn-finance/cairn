import Foundation
import SwiftData
import Testing
@testable import CairnCore

/// The write paths run on a `@ModelActor` that suspends at `await`, so a row it
/// is holding can be deleted out from under it. Writing to a deleted SwiftData
/// row is a fatal error, not a thrown one, so these paths have to ask the store
/// whether the row still exists rather than trusting the context's cache.
@Suite("Sync deletion safety")
@MainActor
struct SyncDeletionSafetyTests {
    private func makeEngine() throws -> (container: ModelContainer, engine: SyncEngine) {
        let result = try ModelContainerFactory.make(mode: .local, inMemory: true)
        return (result.container, SyncEngine(modelContainer: result.container))
    }

    private func makeAccountSet() -> SimpleFINAccountSet {
        SimpleFINAccountSet(
            connections: [SimpleFINConnection(id: "CON-A", name: "Sample Bank", organizationID: "ORG-A")],
            accounts: [
                SimpleFINAccount(
                    id: "1",
                    name: "Checking",
                    connectionID: "CON-A",
                    currency: .usd,
                    balanceMinorUnits: 100
                )
            ],
            errors: []
        )
    }

    @Test("A connection batch-deleted mid-sync refuses the write instead of crashing")
    func institutionDeletedDuringSync() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let institution = Institution(
            bankConnectionID: "CON-A",
            name: "Sample Bank",
            credentialID: UUID()
        )
        context.insert(institution)
        try context.save()
        let institutionID = institution.persistentModelID

        let set = makeAccountSet()
        let accessURL = URL(string: "https://demo:demo@example.com/simplefin")!

        // A first pass loads the row into the engine's own context, the way a
        // real sync does before it goes to the network.
        _ = try await engine.applyAccountSet(
            set,
            institutionID: institutionID,
            accessURL: accessURL,
            now: .now
        )

        // Delete All Data and "remove connection" both batch-delete. That does
        // not mark rows another context already loaded as deleted, so the
        // engine's copy still looks alive.
        try context.delete(
            model: Institution.self,
            where: #Predicate { $0.bankConnectionID == "CON-A" }
        )
        try context.save()

        // The next pass has to notice the row is gone. Touching the stale object
        // would trap the process rather than throw.
        await #expect(throws: (any Error).self) {
            _ = try await engine.applyAccountSet(
                set,
                institutionID: institutionID,
                accessURL: accessURL,
                now: .now
            )
        }
        await #expect(throws: (any Error).self) {
            _ = try await engine.decideSync(institutionID: institutionID, force: true, now: .now)
        }

        // Nothing was resurrected by the refused writes.
        #expect(try context.fetch(FetchDescriptor<Institution>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Account>()).isEmpty)
    }
}
