import Foundation
import SwiftData
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

        #expect(plan.map(\.identifier) == ["cairn.commitment.due", "cairn.stale-connection", "cairn.commitment.soon"])
        #expect(plan.first?.date == nil)
        #expect(plan.last?.date == now.addingTimeInterval(2 * 86_400))
    }

    @Test("Routes round-trip and old widget links still open the forecast")
    func routes() throws {
        let id = UUID()
        for route in [SystemSurfaceDestination.forecast, .connections, .commitments, .commitment(id)] {
            #expect(SystemSurfaceDestination(url: route.url) == route)
        }
        #expect(SystemSurfaceDestination(url: try #require(URL(string: "cairn://insights"))) == .forecast)
        for raw in ["https://forecast", "cairn://forecast/extra", "cairn://commitments/not-a-uuid", "cairn://forecast?data=1"] {
            #expect(SystemSurfaceDestination(url: try #require(URL(string: raw))) == nil)
        }
        #expect(SystemSurfaceDestination.legacyNotification(identifier: "cairn.stale-connection") == .connections)
        #expect(SystemSurfaceDestination.legacyNotification(identifier: "cairn.commitment.old-detector-id") == .commitments)
        #expect(SystemSurfaceDestination.legacyNotification(identifier: "other.feature") == nil)
    }

    @Test("Delivered or dismissed events do not re-alert; a changed event does")
    func notificationDeduplication() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let id = UUID()
        let plan = SystemNotificationPlanner.plan(
            snapshot: SystemSurfaceSnapshot(status: .onTrack), lastSuccessfulSync: nil,
            commitments: [.init(id: id.uuidString, status: .upcoming, dueDate: now.addingTimeInterval(86_400))],
            now: now
        )
        let item = try #require(plan.first)
        #expect(item.destination == .commitment(id))
        let records = [item.identifier: item.eventKey]
        #expect(SystemNotificationSchedule.requests(plan: plan, pendingEvents: [:], recordedEvents: records).isEmpty)
        #expect(SystemNotificationSchedule.requests(plan: plan, pendingEvents: records, recordedEvents: [:]).isEmpty)
        #expect(SystemNotificationSchedule.requests(plan: plan, pendingEvents: [:], recordedEvents: [:]) == plan)
        let duePlan = SystemNotificationPlanner.plan(
            snapshot: SystemSurfaceSnapshot(status: .onTrack), lastSuccessfulSync: nil,
            commitments: [.init(id: id.uuidString, status: .due, dueDate: now.addingTimeInterval(86_400))], now: now
        )
        #expect(duePlan.first?.kind == .dueCommitment)
        #expect(SystemNotificationSchedule.requests(plan: duePlan, pendingEvents: [:], recordedEvents: records) == duePlan)
        #expect(SystemNotificationSchedule.requests(plan: duePlan, pendingEvents: records, recordedEvents: records) == duePlan)
    }

    @Test("Fresh connections schedule a future stale alert and renew it after sync")
    func proactiveStaleAlert() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func plan(_ lastSync: Date) -> [SystemNotification] {
            SystemNotificationPlanner.plan(
                snapshot: SystemSurfaceSnapshot(status: .onTrack), lastSuccessfulSync: lastSync,
                commitments: [], now: now
            )
        }
        let first = try #require(plan(now).first)
        #expect(first.date == now.addingTimeInterval(36 * 60 * 60))
        #expect(first.destination == .connections)
        #expect(plan(now.addingTimeInterval(60)).first?.eventKey != first.eventKey)
    }

    @Test("Snapshot decoding preserves snapshots written before next-plan metadata")
    func snapshotCompatibility() throws {
        let old = Data(#"{"status":"onTrack","generatedAt":1000}"#.utf8)
        let snapshot = try JSONDecoder().decode(SystemSurfaceSnapshot.self, from: old)
        #expect(snapshot.status == .onTrack)
        #expect(snapshot.nextCommitmentDate == nil)
    }

    @Test("Notification plans stay below the system request limit")
    func notificationLimit() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let plan = SystemNotificationPlanner.plan(
            snapshot: SystemSurfaceSnapshot(status: .needsAttention), lastSuccessfulSync: now,
            commitments: (0..<100).map { .init(id: "\($0)", status: .due, dueDate: now) }, now: now
        )
        #expect(plan.count == 60)
        #expect(plan.contains { $0.kind == .budgetRisk })
        let connectionsOnly = SystemNotificationPlanner.plan(
            snapshot: .init(status: .needsAttention), lastSuccessfulSync: now,
            commitments: (0..<100).map { .init(id: "\($0)", status: .due, dueDate: now) },
            now: now, enabledKinds: [.staleConnection]
        )
        #expect(connectionsOnly.count == 1)
        #expect(connectionsOnly.first?.kind == .staleConnection)
    }

    @Test("Confirmed due dates produce reminders before any observed payment")
    @MainActor
    func unobservedConfirmedPlan() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let container = try ModelContainerFactory.make(mode: .local, inMemory: true).container
        let commitment = ConfirmedCommitment(
            detectorID: "synthetic-private-detector", name: "Synthetic plan", amountMinorUnits: -1_000,
            nextDueDate: now.addingTimeInterval(2 * 86_400)
        )
        container.mainContext.insert(commitment)
        try container.mainContext.save()
        let engine = SyncEngine(modelContainer: container)
        let surfaces = try await engine.systemSurfaceCommitments(now: now)
        #expect(surfaces.first?.status == .upcoming)
        #expect(surfaces.first?.id == commitment.uuid.uuidString)
        #expect(surfaces.first?.id != commitment.detectorID)
        let detached = try await engine.confirmedCommitmentSnapshot(id: commitment.uuid)
        #expect(detached?.name == "Synthetic plan")
        let plan = SystemNotificationPlanner.plan(
            snapshot: .init(status: .review), lastSuccessfulSync: nil, commitments: surfaces, now: now
        )
        #expect(plan.first?.destination == .commitment(commitment.uuid))
        #expect(plan.first?.date == now.addingTimeInterval(86_400))
    }
}
