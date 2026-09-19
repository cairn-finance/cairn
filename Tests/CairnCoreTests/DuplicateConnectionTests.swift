import Foundation
import SwiftData
import Testing
@testable import CairnCore

/// Matching SimpleFIN connections by identity, and repairing the duplicate
/// institutions a second claim used to create.
@Suite("Duplicate connections")
@MainActor
struct DuplicateConnectionTests {
    private func makeEngine() throws -> (container: ModelContainer, engine: SyncEngine) {
        let result = try ModelContainerFactory.make(mode: .local, inMemory: true)
        return (result.container, SyncEngine(modelContainer: result.container))
    }

    private func accessURL() -> URL {
        URL(string: "https://demo:demo@example.com/simplefin")!
    }

    private func connection(_ id: String, org: String) -> SimpleFINConnection {
        SimpleFINConnection(id: id, name: id, organizationID: org)
    }

    private func account(
        _ id: String,
        connection: String,
        balance: Int64 = 100,
        transactions: [SimpleFINTransaction] = []
    ) -> SimpleFINAccount {
        SimpleFINAccount(
            id: id,
            name: id,
            connectionID: connection,
            currency: .usd,
            balanceMinorUnits: balance,
            transactions: transactions
        )
    }

    private func txn(_ id: String, amount: Int64 = -100, description: String = "Coffee") -> SimpleFINTransaction {
        SimpleFINTransaction(
            id: id,
            postedDate: Date(timeIntervalSince1970: 1_700_000_000),
            transactedAt: nil,
            amountMinorUnits: amount,
            description: description,
            isPending: false
        )
    }

    @discardableResult
    private func insertHolder(
        in context: ModelContext,
        credentialID: UUID,
        name: String = "Holder",
        createdAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> Institution {
        let holder = Institution(bankConnectionID: "", name: name, credentialID: credentialID)
        holder.createdAt = createdAt
        context.insert(holder)
        return holder
    }

    @discardableResult
    private func insertConnection(
        in context: ModelContext,
        credentialID: UUID,
        connectionID: String,
        orgID: String,
        createdAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> Institution {
        let child = Institution(bankConnectionID: connectionID, name: connectionID, credentialID: credentialID)
        child.orgID = orgID
        child.createdAt = createdAt
        context.insert(child)
        return child
    }

    @discardableResult
    private func insertAccount(
        in context: ModelContext,
        bankAccountID: String,
        institution: Institution,
        displayName: String? = nil,
        balance: Int64 = 0,
        transactions: [(id: String, amount: Int64, note: String?)] = []
    ) -> Account {
        let account = Account(bankAccountID: bankAccountID, name: bankAccountID, currency: .usd)
        account.customDisplayName = displayName
        account.balanceMinorUnits = balance
        account.institution = institution
        context.insert(account)
        for item in transactions {
            let row = LedgerTransaction(
                bankTransactionID: item.id,
                payeeDescription: item.id,
                amountMinorUnits: item.amount
            )
            row.note = item.note
            row.accountIDIndex = bankAccountID
            row.account = account
            context.insert(row)
        }
        return account
    }

    // MARK: - Matching

    @Test("A connection is identified by id and organization, not by name")
    func identityIgnoresName() {
        let stored = [
            ConnectionMatcher.StoredConnection(
                identity: ConnectionIdentity(connectionID: "CON-1", organizationID: "ORG-1"),
                credentialID: UUID()
            )
        ]
        let renamed = SimpleFINConnection(id: "CON-1", name: "A New Name", organizationID: "ORG-1")
        #expect(ConnectionMatcher.decide(incoming: [renamed], stored: stored) != .fresh)
    }

    @Test("A different organization is a different connection")
    func identityUsesOrganization() {
        let credentialID = UUID()
        let stored = [
            ConnectionMatcher.StoredConnection(
                identity: ConnectionIdentity(connectionID: "CON-1", organizationID: "ORG-1"),
                credentialID: credentialID
            )
        ]
        let other = SimpleFINConnection(id: "CON-1", name: "Same id, other org", organizationID: "ORG-2")
        #expect(ConnectionMatcher.decide(incoming: [other], stored: stored) == .fresh)
    }

    @Test("Connections spanning two stored credentials are ambiguous")
    func decideAmbiguous() {
        let a = UUID()
        let b = UUID()
        let stored = [
            ConnectionMatcher.StoredConnection(
                identity: ConnectionIdentity(connectionID: "CON-1", organizationID: "ORG-1"),
                credentialID: a
            ),
            ConnectionMatcher.StoredConnection(
                identity: ConnectionIdentity(connectionID: "CON-1", organizationID: "ORG-1"),
                credentialID: b
            ),
        ]
        #expect(
            ConnectionMatcher.decide(incoming: [connection("CON-1", org: "ORG-1")], stored: stored)
                == .ambiguous(credentialIDs: [a, b].sorted { $0.uuidString < $1.uuidString })
        )
    }

    @Test("The survivor rule is deterministic and refuses to guess on a tie")
    func survivorRule() {
        let early = ConnectionSurvivor.Candidate(
            credentialID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let late = ConnectionSurvivor.Candidate(
            credentialID: UUID(),
            createdAt: Date(timeIntervalSince1970: 2)
        )
        #expect(ConnectionSurvivor.choose([late, early]) == 1)
        #expect(ConnectionSurvivor.choose([early, late]) == 0)

        // Two candidates identical on every stored value cannot be told apart,
        // so a repair must leave them rather than let devices delete each other.
        let twin = ConnectionSurvivor.Candidate(credentialID: early.credentialID, createdAt: early.createdAt)
        #expect(ConnectionSurvivor.choose([early, twin]) == nil)
    }

    @Test("Only duplicated credentials are reported as redundant")
    func redundantCredentialDetection() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let shared = ConnectionIdentity(connectionID: "CON-1", organizationID: "ORG-1")
        let lone = ConnectionIdentity(connectionID: "CON-2", organizationID: "ORG-2")
        let stored = [
            ConnectionMatcher.StoredConnection(identity: shared, credentialID: a),
            ConnectionMatcher.StoredConnection(identity: shared, credentialID: b),
            ConnectionMatcher.StoredConnection(identity: lone, credentialID: c),
        ]
        #expect(ConnectionMatcher.redundantCredentialIDs(stored: stored) == [a, b])
    }

    // MARK: - Claiming

    @Test("Claiming the same user twice keeps one set of institutions and one credential")
    func secondClaimAdoptsExisting() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let credentialID = UUID()
        insertHolder(in: context, credentialID: credentialID)
        let child = insertConnection(
            in: context, credentialID: credentialID, connectionID: "CON-1", orgID: "ORG-1"
        )
        insertAccount(in: context, bankAccountID: "1", institution: child)
        try context.save()

        let incoming = [connection("CON-1", org: "ORG-1")]
        let stored = try await engine.storedConnections()
        let adoption = ConnectionMatcher.decide(incoming: incoming, stored: stored)
        #expect(adoption == .adopt(credentialID: credentialID))

        let probe = SyncEngine.ConnectionProbe(
            accountSet: SimpleFINAccountSet(connections: incoming, accounts: [account("1", connection: "CON-1")]),
            adoption: adoption,
            credentialID: credentialID
        )
        _ = try await engine.applyClaim(probe, accessURL: accessURL(), now: .now)

        let institutions = try context.fetch(FetchDescriptor<Institution>())
        let accounts = try context.fetch(FetchDescriptor<Account>())
        #expect(institutions.count == 2)
        #expect(Set(institutions.map(\.credentialID)) == [credentialID])
        #expect(institutions.filter { !$0.bankConnectionID.isEmpty }.count == 1)
        #expect(accounts.count == 1)
        #expect(accounts.first?.institution?.bankConnectionID == "CON-1")
    }

    @Test("A token for a different user gets its own credential and holder")
    func freshUserGetsOwnCredential() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let existingID = UUID()
        insertHolder(in: context, credentialID: existingID)
        insertConnection(in: context, credentialID: existingID, connectionID: "CON-1", orgID: "ORG-1")
        try context.save()

        let incoming = [connection("CON-9", org: "ORG-9")]
        let stored = try await engine.storedConnections()
        #expect(ConnectionMatcher.decide(incoming: incoming, stored: stored) == .fresh)

        let proposed = UUID()
        let probe = SyncEngine.ConnectionProbe(
            accountSet: SimpleFINAccountSet(
                connections: incoming,
                accounts: [account("9", connection: "CON-9")]
            ),
            adoption: .fresh,
            credentialID: proposed
        )
        _ = try await engine.applyClaim(probe, accessURL: accessURL(), now: .now)

        let institutions = try context.fetch(FetchDescriptor<Institution>())
        #expect(Set(institutions.map(\.credentialID)) == [existingID, proposed])
        // Both connections still have exactly one institution each.
        let children = institutions.filter { !$0.bankConnectionID.isEmpty }
        #expect(children.count == 2)
        #expect(Set(children.map(\.bankConnectionID)) == ["CON-1", "CON-9"])
    }

    @Test("Two credentials for different users both sync without merging")
    func twoDifferentUsersBothSync() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let a = UUID()
        let b = UUID()
        insertHolder(in: context, credentialID: a)
        let childA = insertConnection(in: context, credentialID: a, connectionID: "CON-A", orgID: "ORG-A")
        insertHolder(in: context, credentialID: b)
        let childB = insertConnection(in: context, credentialID: b, connectionID: "CON-B", orgID: "ORG-B")
        try context.save()

        for (holder, connectionID, orgID, accountID) in [
            (childA, "CON-A", "ORG-A", "1"),
            (childB, "CON-B", "ORG-B", "2"),
        ] {
            _ = try await engine.applyAccountSet(
                SimpleFINAccountSet(
                    connections: [connection(connectionID, org: orgID)],
                    accounts: [account(accountID, connection: connectionID)]
                ),
                institutionID: holder.persistentModelID,
                accessURL: accessURL(),
                now: .now
            )
        }

        let institutions = try context.fetch(FetchDescriptor<Institution>())
        #expect(institutions.count == 4)
        let accounts = try context.fetch(FetchDescriptor<Account>())
        #expect(accounts.count == 2)
        #expect(accounts.first { $0.bankAccountID == "1" }?.institution?.credentialID == a)
        #expect(accounts.first { $0.bankAccountID == "2" }?.institution?.credentialID == b)
    }

    @Test("A partial overlap reuses the known connection and creates only the new one")
    func partialOverlapCreatesOnlyNew() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let credentialID = UUID()
        insertHolder(in: context, credentialID: credentialID)
        let known = insertConnection(
            in: context, credentialID: credentialID, connectionID: "CON-1", orgID: "ORG-1"
        )
        insertAccount(in: context, bankAccountID: "1", institution: known)
        try context.save()

        let incoming = [connection("CON-1", org: "ORG-1"), connection("CON-2", org: "ORG-2")]
        let stored = try await engine.storedConnections()
        let adoption = ConnectionMatcher.decide(incoming: incoming, stored: stored)
        #expect(adoption == .adopt(credentialID: credentialID))

        let probe = SyncEngine.ConnectionProbe(
            accountSet: SimpleFINAccountSet(
                connections: incoming,
                accounts: [
                    account("1", connection: "CON-1"),
                    account("2", connection: "CON-2", balance: 250),
                ]
            ),
            adoption: adoption,
            credentialID: credentialID
        )
        _ = try await engine.applyClaim(probe, accessURL: accessURL(), now: .now)

        let institutions = try context.fetch(FetchDescriptor<Institution>())
        #expect(institutions.count == 3)
        #expect(institutions.filter(\.isCredentialHolder).count == 1)
        let children = institutions.filter { !$0.bankConnectionID.isEmpty }
        #expect(Set(children.map(\.bankConnectionID)) == ["CON-1", "CON-2"])
        #expect(Set(children.map(\.credentialID)) == [credentialID])
        // The existing account stayed on the existing child.
        let accounts = try context.fetch(FetchDescriptor<Account>())
        #expect(accounts.first { $0.bankAccountID == "1" }?.institution?.bankConnectionID == "CON-1")
        #expect(accounts.first { $0.bankAccountID == "2" }?.institution?.bankConnectionID == "CON-2")
    }

    @Test("An overlap with two credentials resolves the sync to the survivor")
    func ambiguousOverlapResolvesToSurvivor() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let a = UUID()
        let b = UUID()
        insertHolder(in: context, credentialID: a)
        let childA = insertConnection(
            in: context, credentialID: a, connectionID: "CON-1", orgID: "ORG-1",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        insertAccount(in: context, bankAccountID: "1", institution: childA)
        insertHolder(in: context, credentialID: b)
        let childB = insertConnection(
            in: context, credentialID: b, connectionID: "CON-1", orgID: "ORG-1",
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
        insertAccount(in: context, bankAccountID: "1", institution: childB, balance: 100)
        try context.save()

        let incoming = [connection("CON-1", org: "ORG-1")]
        let stored = try await engine.storedConnections()
        let adoption = ConnectionMatcher.decide(incoming: incoming, stored: stored)
        #expect(adoption == .ambiguous(credentialIDs: [a, b].sorted { $0.uuidString < $1.uuidString }))

        let proposed = UUID()
        let probe = SyncEngine.ConnectionProbe(
            accountSet: SimpleFINAccountSet(
                connections: incoming,
                accounts: [account("1", connection: "CON-1", balance: 999)]
            ),
            adoption: adoption,
            credentialID: proposed
        )
        let outcome = try await engine.applyClaim(probe, accessURL: accessURL(), now: .now)
        #expect(outcome.ambiguousConnections == 1)

        // No third child was created, and the imported balance landed on the
        // older survivor. The other row waits for the repair, untouched.
        let institutions = try context.fetch(FetchDescriptor<Institution>())
        let children = institutions.filter { !$0.bankConnectionID.isEmpty }
        #expect(children.count == 2)
        #expect(Set(children.map(\.credentialID)) == [a, b])
        #expect(childA.accounts?.first?.balanceMinorUnits == 999)
        #expect(childB.accounts?.first?.balanceMinorUnits == 100)
    }

    // MARK: - Repair

    private struct DuplicateSeed {
        var credentialA = UUID()
        var credentialB = UUID()
    }

    /// Seeds two credentials holding the same connection and account. Credential
    /// A is older, so its connection is the survivor. Pass the same `seed` to two
    /// containers to model two devices seeing identical stored values.
    @discardableResult
    private func seedDuplicates(
        in context: ModelContext,
        seed: DuplicateSeed = DuplicateSeed()
    ) throws -> DuplicateSeed {
        insertHolder(in: context, credentialID: seed.credentialA, createdAt: Date(timeIntervalSince1970: 10))
        let childA = insertConnection(
            in: context, credentialID: seed.credentialA, connectionID: "CON-1", orgID: "ORG-1",
            createdAt: Date(timeIntervalSince1970: 11)
        )
        insertAccount(
            in: context, bankAccountID: "1", institution: childA,
            transactions: [
                ("T1", -100, "shared"),
                ("T2", -200, "kept on A"),
            ]
        )
        insertHolder(in: context, credentialID: seed.credentialB, createdAt: Date(timeIntervalSince1970: 20))
        let childB = insertConnection(
            in: context, credentialID: seed.credentialB, connectionID: "CON-1", orgID: "ORG-1",
            createdAt: Date(timeIntervalSince1970: 21)
        )
        insertAccount(
            in: context, bankAccountID: "1", institution: childB,
            transactions: [
                ("T1", -100, nil),
                ("T3", -300, "kept on B"),
            ]
        )
        try context.save()
        return seed
    }

    @Test("The repair keeps every account and transaction and re-keys the retired credential")
    func repairMergesDuplicates() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let seed = try seedDuplicates(in: context)

        let outcome = try await engine.repairDuplicateConnections()
        #expect(outcome.duplicateGroups == 1)
        #expect(outcome.retiredCredentials[seed.credentialB] == seed.credentialA)

        // One connection, one account, all three transactions.
        let institutions = try context.fetch(FetchDescriptor<Institution>())
        let children = institutions.filter { !$0.bankConnectionID.isEmpty }
        #expect(children.count == 1)
        #expect(children.first?.credentialID == seed.credentialA)
        let accounts = try context.fetch(FetchDescriptor<Account>())
        #expect(accounts.count == 1)
        let transactions = try context.fetch(FetchDescriptor<LedgerTransaction>())
        #expect(Set(transactions.map(\.bankTransactionID)) == ["T1", "T2", "T3"])
        #expect(transactions.first { $0.bankTransactionID == "T2" }?.note == "kept on A")
        #expect(transactions.first { $0.bankTransactionID == "T3" }?.note == "kept on B")
        // The retired holder is gone and no institution keeps credential B.
        #expect(!institutions.contains { $0.credentialID == seed.credentialB })
    }

    @Test("Running the repair twice changes nothing the second time")
    func repairIsIdempotent() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        _ = try seedDuplicates(in: context)

        _ = try await engine.repairDuplicateConnections()
        let second = try await engine.repairDuplicateConnections()
        #expect(second.duplicateGroups == 0)
        #expect(!second.didChange)

        #expect(try context.fetch(FetchDescriptor<Institution>()).count == 2)
        #expect(try context.fetch(FetchDescriptor<Account>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<LedgerTransaction>()).count == 3)
    }

    @Test("Two devices with different secrets choose the same survivor")
    func repairConvergesAcrossDevices() async throws {
        // Device 1 and device 2 see the same stored values but hold different
        // Keychain secrets; the engine never reads a secret, so both pick the
        // same row.
        let (container1, engine1) = try makeEngine()
        let seed = DuplicateSeed()
        _ = try seedDuplicates(in: container1.mainContext, seed: seed)
        let (container2, engine2) = try makeEngine()
        _ = try seedDuplicates(in: container2.mainContext, seed: seed)

        let outcome1 = try await engine1.repairDuplicateConnections()
        let outcome2 = try await engine2.repairDuplicateConnections()
        #expect(outcome1.retiredCredentials[seed.credentialB] == seed.credentialA)
        #expect(outcome2.retiredCredentials[seed.credentialB] == seed.credentialA)

        let survivors1 = try container1.mainContext.fetch(FetchDescriptor<Institution>())
            .filter { !$0.bankConnectionID.isEmpty }
        let survivors2 = try container2.mainContext.fetch(FetchDescriptor<Institution>())
            .filter { !$0.bankConnectionID.isEmpty }
        #expect(survivors1.first?.credentialID == survivors2.first?.credentialID)
    }

    @Test("An unsafe account merge leaves both rows and the duplicate institution")
    func repairLeavesUnsafeMerge() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let a = UUID()
        let b = UUID()
        insertHolder(in: context, credentialID: a, createdAt: Date(timeIntervalSince1970: 10))
        let childA = insertConnection(
            in: context, credentialID: a, connectionID: "CON-1", orgID: "ORG-1",
            createdAt: Date(timeIntervalSince1970: 11)
        )
        insertAccount(in: context, bankAccountID: "1", institution: childA, displayName: "Alpha")
        insertHolder(in: context, credentialID: b, createdAt: Date(timeIntervalSince1970: 20))
        let childB = insertConnection(
            in: context, credentialID: b, connectionID: "CON-1", orgID: "ORG-1",
            createdAt: Date(timeIntervalSince1970: 21)
        )
        insertAccount(in: context, bankAccountID: "1", institution: childB, displayName: "Beta")
        try context.save()

        let outcome = try await engine.repairDuplicateConnections()
        #expect(outcome.unsafeMerges == 1)
        #expect(outcome.retiredCredentials.isEmpty)
        #expect(try context.fetch(FetchDescriptor<Account>()).count == 2)
        #expect(try context.fetch(FetchDescriptor<Institution>()).count == 4)

        // Nothing more to do on a second pass.
        let second = try await engine.repairDuplicateConnections()
        #expect(!second.didChange)
    }

    @Test("Sync keeps importing to the survivor while an unsafe duplicate awaits a merge")
    func syncKeepsImportingWhileDuplicateUnmerged() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let a = UUID()
        let b = UUID()
        insertHolder(in: context, credentialID: a)
        let childA = insertConnection(
            in: context, credentialID: a, connectionID: "CON-1", orgID: "ORG-1",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        insertAccount(
            in: context, bankAccountID: "1", institution: childA, displayName: "Alpha"
        )
        insertHolder(in: context, credentialID: b)
        let childB = insertConnection(
            in: context, credentialID: b, connectionID: "CON-1", orgID: "ORG-1",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        insertAccount(
            in: context, bankAccountID: "1", institution: childB, displayName: "Beta", balance: 100
        )
        try context.save()

        // The chosen names conflict, so the repair leaves both rows in place.
        let repair = try await engine.repairDuplicateConnections()
        #expect(repair.unsafeMerges == 1)
        #expect(repair.retiredCredentials.isEmpty)

        let incoming = connection("CON-1", org: "ORG-1")
        let first = SimpleFINAccountSet(
            connections: [incoming],
            accounts: [account(
                "1", connection: "CON-1", balance: 250,
                transactions: [txn("T1"), txn("T2")]
            )]
        )
        let second = SimpleFINAccountSet(
            connections: [incoming],
            accounts: [account(
                "1", connection: "CON-1", balance: 300,
                transactions: [txn("T1"), txn("T2"), txn("T3")]
            )]
        )

        // Alternate which credential syncs, as two devices would.
        for (holderID, set) in [(a, first), (b, first), (a, second), (b, second)] {
            let holder = try #require(try context.fetch(FetchDescriptor<Institution>())
                .first { $0.credentialID == holderID && $0.bankConnectionID.isEmpty })
            _ = try await engine.applyAccountSet(
                set,
                institutionID: holder.persistentModelID,
                accessURL: accessURL(),
                now: .now
            )
        }

        // Every transaction kept importing, onto the survivor's account.
        let transactions = try context.fetch(FetchDescriptor<LedgerTransaction>())
        #expect(Set(transactions.map(\.bankTransactionID)) == ["T1", "T2", "T3"])
        #expect(transactions.allSatisfy { $0.account?.institution?.credentialID == a })
        // Both account rows stayed put with their chosen names untouched; the
        // imported balance landed on the survivor.
        let accounts = try context.fetch(FetchDescriptor<Account>())
        #expect(accounts.count == 2)
        let survivorAccount = try #require(accounts.first { $0.institution?.credentialID == a })
        let otherAccount = try #require(accounts.first { $0.institution?.credentialID == b })
        #expect(survivorAccount.balanceMinorUnits == 300)
        #expect(survivorAccount.customDisplayName == "Alpha")
        #expect(otherAccount.balanceMinorUnits == 100)
        #expect(otherAccount.customDisplayName == "Beta")
    }

    @Test("An indeterminate duplicate still imports to one deterministic row")
    func syncImportsWhenSurvivorIsIndeterminate() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let credentialID = UUID()
        insertHolder(in: context, credentialID: credentialID)
        // Same credential and same creation date: ConnectionSurvivor refuses
        // to choose, so the sync has to fall back instead of skipping.
        insertConnection(
            in: context, credentialID: credentialID, connectionID: "CON-1", orgID: "ORG-1",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        insertConnection(
            in: context, credentialID: credentialID, connectionID: "CON-1", orgID: "ORG-1",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        try context.save()

        let holder = try #require(try context.fetch(FetchDescriptor<Institution>())
            .first { $0.isCredentialHolder })
        _ = try await engine.applyAccountSet(
            SimpleFINAccountSet(
                connections: [connection("CON-1", org: "ORG-1")],
                accounts: [account(
                    "1", connection: "CON-1",
                    transactions: [txn("T1"), txn("T2")]
                )]
            ),
            institutionID: holder.persistentModelID,
            accessURL: accessURL(),
            now: .now
        )

        let transactions = try context.fetch(FetchDescriptor<LedgerTransaction>())
        #expect(transactions.count == 2)
        let children = try context.fetch(FetchDescriptor<Institution>())
            .filter { !$0.bankConnectionID.isEmpty }
        let owners = children.filter { !($0.accounts ?? []).isEmpty }
        #expect(owners.count == 1)
    }

    // MARK: - Removal

    @Test("Removing a set whose connection another credential reaches keeps the accounts")
    func removalMovesAccountsToSurvivor() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let a = UUID()
        let b = UUID()
        insertHolder(in: context, credentialID: a)
        let childA = insertConnection(in: context, credentialID: a, connectionID: "CON-1", orgID: "ORG-1")
        insertAccount(in: context, bankAccountID: "1", institution: childA)
        insertHolder(in: context, credentialID: b)
        insertConnection(in: context, credentialID: b, connectionID: "CON-1", orgID: "ORG-1")
        try context.save()

        let outcome = try await engine.removeConnections(credentialIDs: [a])
        #expect(outcome.retiredCredentialIDs == [a])
        #expect(outcome.movedAccounts == 1)

        let institutions = try context.fetch(FetchDescriptor<Institution>())
        #expect(institutions.count == 2)
        #expect(!institutions.contains { $0.credentialID == a })
        let account = try context.fetch(FetchDescriptor<Account>()).first
        #expect(account?.institution?.credentialID == b)
    }

    @Test("Removal keeps a credential whose account cannot be merged away safely")
    func removalKeepsUnsafeAccount() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let a = UUID()
        let b = UUID()
        insertHolder(in: context, credentialID: a)
        let childA = insertConnection(in: context, credentialID: a, connectionID: "CON-1", orgID: "ORG-1")
        insertAccount(in: context, bankAccountID: "1", institution: childA, displayName: "Alpha")
        insertHolder(in: context, credentialID: b)
        let childB = insertConnection(in: context, credentialID: b, connectionID: "CON-1", orgID: "ORG-1")
        insertAccount(in: context, bankAccountID: "1", institution: childB, displayName: "Beta")
        try context.save()

        let outcome = try await engine.removeConnections(credentialIDs: [a])
        #expect(outcome.retiredCredentialIDs.isEmpty)
        #expect(outcome.retainedInstitutions == 1)
        // Both accounts survive, so the credential stays too.
        #expect(try context.fetch(FetchDescriptor<Account>()).count == 2)
        #expect(try context.fetch(FetchDescriptor<Institution>()).contains { $0.credentialID == a })
    }

    // MARK: - Re-keying

    @Test("Re-keying deletes the old item only after the new write succeeds")
    func reKeyKeepsOldOnFailure() throws {
        let old = UUID()
        let new = UUID()
        let secret = "https://demo:demo@example.com/simplefin"

        let store = InMemoryCredentialStore()
        try store.store(secret, id: old, synchronizable: false)
        #expect(try CredentialReKey.move(store: store, from: old, to: new, synchronizable: false))
        #expect(try store.secret(for: new) == secret)
        #expect(try store.secret(for: old) == nil)

        let failing = InMemoryCredentialStore()
        try failing.store(secret, id: old, synchronizable: false)
        let guarded = WriteFailingStore(backing: failing)
        #expect(throws: (any Error).self) {
            try CredentialReKey.move(store: guarded, from: old, to: new, synchronizable: false)
        }
        #expect(try failing.secret(for: old) == secret)
        #expect(try failing.secret(for: new) == nil)
    }

    @Test("Re-keying a credential whose survivor already has a secret drops the old copy")
    func reKeyWhenSurvivorHasSecret() throws {
        let old = UUID()
        let new = UUID()
        let store = InMemoryCredentialStore()
        try store.store("https://old.example/simplefin", id: old, synchronizable: false)
        try store.store("https://new.example/simplefin", id: new, synchronizable: false)

        #expect(try CredentialReKey.move(store: store, from: old, to: new, synchronizable: false))
        #expect(try store.secret(for: new) == "https://new.example/simplefin")
        #expect(try store.secret(for: old) == nil)
    }
}

/// A credential store whose write always fails, so a re-key can prove it leaves
/// the old item alone rather than deleting it early.
private final class WriteFailingStore: CredentialStore, @unchecked Sendable {
    struct WriteFailure: Error {}

    private let backing: InMemoryCredentialStore

    init(backing: InMemoryCredentialStore) {
        self.backing = backing
    }

    func store(_ secret: String, id: UUID, synchronizable: Bool) throws {
        throw WriteFailure()
    }

    func secret(for id: UUID) throws -> String? {
        try backing.secret(for: id)
    }

    func accessibility(for id: UUID, synchronizable: Bool) throws -> CredentialAccessibility? {
        try backing.accessibility(for: id, synchronizable: synchronizable)
    }

    func allIDs() throws -> [UUID] {
        try backing.allIDs()
    }

    func delete(id: UUID) throws {
        try backing.delete(id: id)
    }

    func deleteAll() throws {
        try backing.deleteAll()
    }
}