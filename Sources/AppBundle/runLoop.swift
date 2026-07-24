import Common
import Foundation

extension Thread {
    @discardableResult
    func runInLoopAsync(
        job: RunLoopJob,
        autoCheckCancelled: Bool = true,
        _ body: @Sendable @escaping (RunLoopJob) -> (),
    ) -> RunLoopJob {
        let action = RunLoopAction(job: job, autoCheckCancelled: autoCheckCancelled, body)
        // Alternative: CFRunLoopPerformBlock + CFRunLoopWakeUp
        action.perform(#selector(action.action), on: self, with: nil, waitUntilDone: false)
        return job
    }

    func runInLoop<T>(
        _ cm: CancellationMode,
        timeout: Duration? = nil,
        _ body: @Sendable @escaping (RunLoopJob) throws -> T,
    ) async throws -> T { // todo try to convert to typed throws
        try checkCancellation(cm)
        let job = RunLoopJob(cm)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                // The continuation may be raced by the timeout watchdog below, and
                // cont.resume must be invoked exactly once — the claim guard arbitrates
                let claim = OneShotClaim()
                // Timeout-with-abandon (#1615): a wedged app blocks its AX thread inside a
                // single AX call for up to the AX messaging timeout (6s) — per call — and no
                // cooperative cancellation check can run while it's blocked. The watchdog
                // abandons the await so the caller can degrade; the closure still finishes
                // on the AX thread eventually and its side effects apply (self-healing),
                // but its resume becomes a no-op via the claim guard
                let watchdog: Task<(), any Error>? = if let timeout, cm == .cancellable {
                    Task {
                        try await Task.sleep(for: timeout)
                        if claim.tryClaim() {
                            job.cancel()
                            cont.resume(throwing: AxTimeoutError())
                        }
                    }
                } else {
                    nil
                }
                self.runInLoopAsync(job: job, autoCheckCancelled: false) { job in
                    do {
                        try job.checkCancellation()
                        let result = try body(job)
                        if claim.tryClaim() {
                            watchdog?.cancel()
                            cont.resume(returning: result)
                        }
                    } catch {
                        if cm == .nonCancellable { die() }
                        if claim.tryClaim() {
                            watchdog?.cancel()
                            cont.resume(throwing: error)
                        }
                    }
                }
            }
        } onCancel: {
            job.cancel()
        }
    }
}

/// An AX request to an unresponsive app exceeded the configured deadline (ax-app-timeout-ms).
/// Distinct from CancellationError so callers can degrade instead of aborting the session
struct AxTimeoutError: Error {}

// Read from AX marshalling paths off the main actor; written only on config (re)load.
// Initial values match the Config defaults so behavior is consistent before the first sync
nonisolated(unsafe) private(set) var axAppTimeout: Duration? = .milliseconds(2000)
/// Deadline for the window enumeration probe, which gates every reflow. See Config.axRefreshTimeoutMs
nonisolated(unsafe) private(set) var axRefreshTimeout: Duration? = .milliseconds(250)

@MainActor func syncAxAppTimeout(_ config: Config) {
    let appTimeout: Duration? = config.axAppTimeoutMs > 0 ? .milliseconds(config.axAppTimeoutMs) : nil
    unsafe axAppTimeout = appTimeout
    // Stock mode (ax-app-timeout-ms = 0) means "no deadlines at all", so it disables the
    // refresh deadline too — otherwise it would silently reintroduce timeout-with-abandon
    unsafe axRefreshTimeout = appTimeout == nil
        ? nil
        : (config.axRefreshTimeoutMs > 0 ? .milliseconds(config.axRefreshTimeoutMs) : appTimeout)
}

private final class OneShotClaim: Sendable {
    nonisolated(unsafe) private var _claimed: Int32 = 0
    func tryClaim() -> Bool { unsafe OSAtomicCompareAndSwapInt(0, 1, &_claimed) }
}

private final class RunLoopAction: NSObject, Sendable {
    private let _action: @Sendable (RunLoopJob) -> ()
    let job: RunLoopJob
    private let autoCheckCancelled: Bool
    private let _refreshSessionEvent: RefreshSessionEvent?
    init(job: RunLoopJob, autoCheckCancelled: Bool, _ action: @escaping @Sendable (RunLoopJob) -> ()) {
        self.job = job
        self.autoCheckCancelled = autoCheckCancelled
        _action = action
        _refreshSessionEvent = refreshSessionEvent
    }
    @objc func action() {
        if autoCheckCancelled && job.isCancelled { return }
        $refreshSessionEvent.withValue(_refreshSessionEvent) {
            _action(job)
        }
    }
}

final class RunLoopJob: Sendable, AeroAny {
    // Alternative 1. In macOS 15, it's possible to use `Atomic<Bool>` from `Synchronization` module
    // Alternative 2. https://github.com/apple/swift-atomics/tree/main but I don't want to add one more dependency just for
    //                AtomicBool
    nonisolated(unsafe) private var _isCancelled: Int32 = 0
    var isCancelled: Bool { unsafe _isCancelled == 1 }
    func cancel() {
        if cm == .nonCancellable { return }
        while !isCancelled {
            unsafe OSAtomicCompareAndSwapInt(0, 1, &_isCancelled)
        }
    }

    let cm: CancellationMode
    public init(_ cm: CancellationMode) { self.cm = cm }

    static let cancelled: RunLoopJob = RunLoopJob(.cancellable).also { $0.cancel() }

    func checkCancellation() throws {
        if cm == .cancellable && isCancelled {
            throw CancellationError()
        }
    }
}
