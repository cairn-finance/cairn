import Foundation
import SwiftData
import Testing
@testable import CairnCore

@Suite("Investment detection")
@MainActor
struct InvestmentDetectionTests {
    private func makeEngine() throws -> (container: ModelContainer, engine: SyncEngine) {
        let result = try ModelContainerFactory.make(mode: .local, inMemory: true)
        return (result.container, SyncEngine(modelContainer: result.container))
    }

    private func makeOwner(in context: ModelContext) throws -> Institution {
        let owner = Institution(bankConnectionID: "", name: "Connecting…", credentialID: UUID())
        context.insert(owner)
        try context.save()
        return owner
    }

    private func apply(
        _ set: SimpleFINAccountSet,
        owner: Institution,
        engine: SyncEngine
    ) async throws {
        _ = try await engine.applyAccountSet(
            set,
            institutionID: owner.persistentModelID,
            accessURL: URL(string: "https://demo:demo@example.com/simplefin")!,
            now: .now
        )
    }

    @Test("Positions mark an account as an investment regardless of its name")
    func positionsImplyInvestment() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let owner = try makeOwner(in: context)

        // A savings-named account that actually holds a position, like the
        // SimpleFIN demo.
        let set = SimpleFINAccountSet(
            connections: [SimpleFINConnection(id: "CON-A", name: "Broker", organizationID: "ORG-A")],
            accounts: [
                SimpleFINAccount(
                    id: "1",
                    name: "SimpleFIN Savings",
                    connectionID: "CON-A",
                    currency: .usd,
                    balanceMinorUnits: 10_000,
                    holdings: [
                        SimpleFINHolding(
                            id: "H1",
                            symbol: "AAPL",
                            name: "Shares of Apple",
                            sharesRaw: "5",
                            currency: .usd,
                            marketValueMinorUnits: 100_000,
                            costBasisMinorUnits: 50_000
                        )
                    ]
                )
            ]
        )
        try await apply(set, owner: owner, engine: engine)

        let account = try #require(try context.fetch(FetchDescriptor<Account>()).first)
        #expect(account.accountType == .investment)
        let holding = try #require(account.holdings?.first)
        #expect(holding.symbol == "AAPL")
        #expect(holding.marketValueMinorUnits == 100_000)
        #expect(holding.hasCostBasis)
        #expect(holding.gain?.minorUnits == 50_000)
        #expect(holding.shares == Decimal(5))
    }

    @Test("Re-syncing updates positions in place and removes those gone")
    func holdingsReconcile() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let owner = try makeOwner(in: context)

        func makeSet(holdings: [SimpleFINHolding]) -> SimpleFINAccountSet {
            SimpleFINAccountSet(
                connections: [SimpleFINConnection(id: "CON-A", name: "Broker", organizationID: "ORG-A")],
                accounts: [
                    SimpleFINAccount(
                        id: "1",
                        name: "Brokerage",
                        connectionID: "CON-A",
                        currency: .usd,
                        balanceMinorUnits: 200_000,
                        holdings: holdings
                    )
                ]
            )
        }

        func holding(_ id: String, market: Int64) -> SimpleFINHolding {
            SimpleFINHolding(id: id, symbol: id, name: id, currency: .usd, marketValueMinorUnits: market)
        }

        try await apply(makeSet(holdings: [holding("H1", market: 100_000), holding("H2", market: 50_000)]),
                        owner: owner, engine: engine)
        // Second pass drops H2 and changes H1's value.
        try await apply(makeSet(holdings: [holding("H1", market: 120_000)]),
                        owner: owner, engine: engine)

        let account = try #require(try context.fetch(FetchDescriptor<Account>()).first)
        let holdings = try #require(account.holdings)
        #expect(holdings.count == 1)
        #expect(holdings.first?.holdingID == "H1")
        #expect(holdings.first?.marketValueMinorUnits == 120_000)
    }

    @Test("Accounts without positions fall back to name inference")
    func nameFallback() async throws {
        let (container, engine) = try makeEngine()
        let context = container.mainContext
        let owner = try makeOwner(in: context)

        func account(_ id: String, _ name: String) -> SimpleFINAccount {
            SimpleFINAccount(id: id, name: name, connectionID: "CON-A", currency: .usd, balanceMinorUnits: 0)
        }

        let set = SimpleFINAccountSet(
            connections: [SimpleFINConnection(id: "CON-A", name: "Bank", organizationID: "ORG-A")],
            accounts: [
                account("1", "Roth IRA"),
                account("2", "SimpleFIN Savings"),
                account("3", "Everyday Checking"),
                account("4", "Brokerage"),
                account("5", "401(k) Plan"),
                account("6", "Aspiration Savings"),
            ]
        )
        try await apply(set, owner: owner, engine: engine)

        let accounts = try context.fetch(FetchDescriptor<Account>())
        let byName = Dictionary(uniqueKeysWithValues: accounts.map { ($0.name, $0.accountType) })
        #expect(byName["Roth IRA"] == .investment)
        #expect(byName["SimpleFIN Savings"] == .savings)
        #expect(byName["Everyday Checking"] == .checking)
        #expect(byName["Brokerage"] == .investment)
        #expect(byName["401(k) Plan"] == .investment)
        // "ira" must match whole words only, so "Aspiration" stays savings.
        #expect(byName["Aspiration Savings"] == .savings)
    }
}
