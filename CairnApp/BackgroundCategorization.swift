import Foundation
import Synchronization
#if os(iOS)
import BackgroundTasks
#endif

/// Registers and schedules the background categorization pass.
///
/// The on-device model is the only expensive part of a sync, so a large backlog
/// finishes in a `BGProcessingTask` — ideally while the device is charging —
/// instead of heating up the app while the person is using it. A short
/// foreground pass still runs so the most recent activity is categorized
/// immediately.
enum BackgroundCategorization {
    static var identifier: String {
        let bundle = Bundle.main.bundleIdentifier ?? "com.sehej.cairn"
        return "\(bundle).processing"
    }

    /// Set by `AppModel` so the background task drives the same engine.
    @MainActor static var run: (@MainActor () async -> Void)?

    /// The power requirement of the last scheduled request, so a task can
    /// reschedule itself the same way. Guarded because the system invokes the
    /// task handler off the main actor.
    private static let lastRequiresPower = Mutex(true)

    #if os(iOS)
    /// A `BGTask` may only be completed from the handler, but it isn't
    /// `Sendable`; this box lets the completion hop to the main actor safely.
    private final class TaskBox: @unchecked Sendable {
        let task: BGProcessingTask
        init(_ task: BGProcessingTask) { self.task = task }
    }

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            handle(task)
        }
    }

    static func schedule(
        requiresPower: Bool,
        earliest: TimeInterval = 15 * 60
    ) {
        lastRequiresPower.withLock { $0 = requiresPower }
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresExternalPower = requiresPower
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliest)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGTask) {
        guard let processing = task as? BGProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }
        // Queue the next run up front, so a crash or an early exit can't stop
        // the chain.
        let requiresPower = lastRequiresPower.withLock { $0 }
        schedule(requiresPower: requiresPower)

        // The next batch simply won't start when the system reclaims the task;
        // whatever completed is already saved.
        processing.expirationHandler = {}

        let box = TaskBox(processing)
        Task { @MainActor in
            await run?()
            box.task.setTaskCompleted(success: true)
        }
    }
    #else
    static func register() {}

    static func schedule(requiresPower: Bool, earliest: TimeInterval = 0) {
        lastRequiresPower.withLock { $0 = requiresPower }
    }
    #endif
}
