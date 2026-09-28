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

    @Test func plannerUsesStableIdentifiersAndAvoidsMerchantDetail() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let plan = SystemNotificationPlanner.plan(
            snapshot: SystemSurfaceSnapshot(status: .onTrack, asOf: now, generatedAt: now),
            lastSuccessfulSync: now.addingTimeInterval(-200_000),
            commitments: [(id: "commitment-1", status: .upcoming, dueDate: now.addingTimeInterval(86_400))],
            now: now
        )
        #expect(plan.map(\.identifier) == ["cairn.stale-connection", "cairn.commitment.commitment-1"])
        #expect(plan.count == 2)
        #expect(!plan.last!.body.localizedCaseInsensitiveContains("merchant"))
    }
}
