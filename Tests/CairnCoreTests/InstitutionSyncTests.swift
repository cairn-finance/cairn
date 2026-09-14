import Foundation
import SwiftData
import Testing
@testable import CairnCore

@Suite("Multi-connection sync")
@MainActor
struct InstitutionSyncTests {
    private func makeEngine() throws -> (container: ModelContainer, engine: SyncEngine) {
        let result = try ModelContainerFactory.make(mode: .local, inMemory: true)
        return (result.container, SyncEngine(modelContainer: result.container))
    }

    @Test("One Access URL fans out into one institution per connection")
    func fansOutConnections() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let credentialID = UUID()
        let owner = Institution(bankConnectionID: "", name: "Connecting…", credentialID: credentialID)
        context.insert(owner)
        try context.save()

        let set = SimpleFINAccountSet(
            connections: [
                SimpleFINConnection(id: "CON-A", name: "Bank A", organizationID: "ORG-A"),
                SimpleFINConnection(id: "CON-B", name: "Bank B", organizationID: "ORG-B"),
            ],
            accounts: [
                SimpleFINAccount(id: "1", name: "A Checking", connectionID: "CON-A", currency: .usd, balanceMinorUnits: 100),
                SimpleFINAccount(id: "2", name: "A Savings", connectionID: "CON-A", currency: .usd, balanceMinorUnits: 200),
                SimpleFINAccount(id: "3", name: "B Checking", connectionID: "CON-B", currency: .usd, balanceMinorUnits: 300),
            ],
            errors: []
        )

        _ = try await engine.applyAccountSet(
            set,
            institutionID: owner.persistentModelID,
            accessURL: URL(string: "https://demo:demo@example.com/simplefin")!,
            now: .now
        )

        let institutions = try context.fetch(FetchDescriptor<Institution>())
        // One hidden credential holder plus one institution per connection.
        #expect(institutions.count == 3)
        let connections = institutions.filter { !$0.bankConnectionID.isEmpty }
        #expect(connections.count == 2)
        let holder = institutions.first { $0.bankConnectionID.isEmpty }
        #expect(holder?.accounts?.isEmpty ?? true)
        let byName = Dictionary(uniqueKeysWithValues: connections.map { ($0.name, $0) })
        #expect(byName["Bank A"]?.accounts?.count == 2)
        #expect(byName["Bank B"]?.accounts?.count == 1)
        // Both institutions share the single Access URL's credential.
        #expect(byName["Bank A"]?.credentialID == credentialID)
        #expect(byName["Bank B"]?.credentialID == credentialID)
    }

    @Test("Re-syncing reuses institutions and accounts instead of duplicating")
    func resyncIsIdempotent() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let credentialID = UUID()
        let owner = Institution(bankConnectionID: "", name: "Connecting…", credentialID: credentialID)
        context.insert(owner)
        try context.save()

        let set = SimpleFINAccountSet(
            connections: [
                SimpleFINConnection(id: "CON-A", name: "Bank A", organizationID: "ORG-A"),
                SimpleFINConnection(id: "CON-B", name: "Bank B", organizationID: "ORG-B"),
            ],
            accounts: [
                SimpleFINAccount(id: "1", name: "A Checking", connectionID: "CON-A", currency: .usd, balanceMinorUnits: 100),
                SimpleFINAccount(id: "1", name: "B Checking", connectionID: "CON-B", currency: .usd, balanceMinorUnits: 300),
            ],
            errors: []
        )

        _ = try await engine.applyAccountSet(
            set, institutionID: owner.persistentModelID,
            accessURL: URL(string: "https://demo:demo@example.com/simplefin")!, now: .now
        )
        // Second pass: the same ids must not create new institutions or accounts,
        // even though both connections reuse account id "1".
        _ = try await engine.applyAccountSet(
            set, institutionID: owner.persistentModelID,
            accessURL: URL(string: "https://demo:demo@example.com/simplefin")!, now: .now
        )

        let institutions = try context.fetch(FetchDescriptor<Institution>())
        let accounts = try context.fetch(FetchDescriptor<Account>())
        // Two connections, one hidden credential holder.
        #expect(institutions.count == 3)
        #expect(accounts.count == 2)
        let byName = Dictionary(uniqueKeysWithValues: institutions
            .filter { !$0.bankConnectionID.isEmpty }
            .map { ($0.name, $0) })
        #expect(byName["Bank A"]?.accounts?.count == 1)
        #expect(byName["Bank B"]?.accounts?.count == 1)
        #expect(byName["Bank A"]?.accounts?.first?.name == "A Checking")
        #expect(byName["Bank B"]?.accounts?.first?.name == "B Checking")
    }
}
