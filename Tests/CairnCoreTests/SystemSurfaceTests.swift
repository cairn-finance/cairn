import Foundation
import Testing
@testable import CairnCore

struct SystemSurfaceTests {
    @Test func snapshotRedactsExactBalanceAndUsesForecastStatus() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let forecast = [
            ForecastBalance(date: now, balanceMinorUnits: 5_000, currency: .usd),
            ForecastBalance(date: now.addingTimeInterval(86_400), balanceMinorUnits: -1, currency: .usd)
        ]
        let snapshot = SystemSurfaceSnapshotBuilder.make(forecast: forecast, lastSuccessfulSync: now, now: now)
        #expect(snapshot.status == .needsAttention)
        #expect(snapshot.currencyCode == "USD")
        #expect(snapshot.statusLabel == "Needs attention")
    }

    @Test("Multi-currency forecast risk is not hidden by the first currency")
    func multiCurrencyRisk() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let eur = Currency(code: "EUR")
        let forecast = [
            ForecastBalance(date: now, balanceMinorUnits: 5_000, currency: .usd),
            ForecastBalance(date: now, balanceMinorUnits: -1, currency: eur),
        ]

        let snapshot = SystemSurfaceSnapshotBuilder.make(forecast: forecast, lastSuccessfulSync: now, now: now)
        #expect(snapshot.status == .needsAttention)
        #expect(snapshot.currencyCode == nil)
    }

    @Test("Widget snapshots become unavailable after their freshness window")
    func snapshotFreshness() {
        let generated = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = SystemSurfaceSnapshot(status: .onTrack, generatedAt: generated)
        #expect(snapshot.isFresh(at: generated.addingTimeInterval(60 * 60)))
        #expect(!snapshot.isFresh(at: generated.addingTimeInterval(27 * 60 * 60)))
        #expect(!snapshot.isFresh(at: generated.addingTimeInterval(-1)))
    }

    @Test func plannerUsesStableIdentifiersAndAvoidsMerchantDetail() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let plan = SystemNotificationPlanner.plan(
            snapshot: SystemSurfaceSnapshot(status: .onTrack, asOf: now, generatedAt: now),
            lastSuccessfulSync: now.addingTimeInterval(-200_000),
            commitments: [
                SystemSurfaceCommitment(
                    id: "commitment-1",
                    status: .upcoming,
                    dueDate: now.addingTimeInterval(86_400)
                )
            ],
            now: now
        )
        #expect(plan.map(\.identifier) == ["cairn.stale-connection", "cairn.commitment.commitment-1"])
        #expect(plan.count == 2)
        let lastBody = try #require(plan.last?.body)
        #expect(!lastBody.localizedCaseInsensitiveContains("merchant"))
    }

    @Test("Planner includes due-today items and bounds upcoming alerts")
    func plannerHandlesDueAndWindow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let plan = SystemNotificationPlanner.plan(
            snapshot: SystemSurfaceSnapshot(status: .onTrack, asOf: now, generatedAt: now),
            lastSuccessfulSync: now,
            commitments: [
                SystemSurfaceCommitment(id: "due", status: .due, dueDate: now),
                SystemSurfaceCommitment(
                    id: "soon",
                    status: .upcoming,
                    dueDate: now.addingTimeInterval(3 * 86_400)
                ),
                SystemSurfaceCommitment(
                    id: "later",
                    status: .upcoming,
                    dueDate: now.addingTimeInterval(30 * 86_400)
                ),
            ],
            now: now
        )

        #expect(plan.map(\.identifier) == ["cairn.commitment.due", "cairn.commitment.soon"])
        #expect(plan.first?.date == nil)
        #expect(plan.last?.date == now.addingTimeInterval(3 * 86_400))
    }
}
