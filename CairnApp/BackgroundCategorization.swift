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
    ///
    /// It also owns the once-only gate. Completing a task twice traps, so every
    /// exit — the work finishing, or the system reclaiming the task — funnels
    /// through `finish`. Holding the gate in a class rather than a local closure
    /// keeps it shareable across both exits: a nested function that captured
    /// these locals had to be *sent* into each of them, which the compiler
    /// rejects as a potential data race.
    private final class TaskGate: @unchecked Sendable {
        private let task: BGProcessingTask
        private let done = Mutex(false)

        init(_ task: BGProcessingTask) { self.task = task }

        func finish(success: Bool) {
            let alreadyDone = done.withLock { done -> Bool in
                if done { return true }
                done = true
                return false
            }
            guard !alreadyDone else { return }
            task.setTaskCompleted(success: success)
        }
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

        let gate = TaskGate(processing)
        let work = Mutex<Task<Void, Never>?>(nil)

        // Being reclaimed means "stop now". Cancel the pass and report it as
        // unfinished, rather than leaving it running past the deadline and never
        // completing the task.
        processing.expirationHandler = {
            work.withLock { $0 }?.cancel()
            gate.finish(success: false)
        }

        let running = Task { @MainActor in
            await run?()
            gate.finish(success: true)
        }
        work.withLock { $0 = running }
    }
    #else
    static func register() {}

    static func schedule(requiresPower: Bool, earliest: TimeInterval = 0) {
        lastRequiresPower.withLock { $0 = requiresPower }
    }
    #endif
}
