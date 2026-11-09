import Foundation

/// Decides *when* to sync, so the app never needs a manual sync button.
///
/// Callers just report that something happened (`request(_:)`): a local edit,
/// a Realtime change notification, the app becoming active, a timer tick.
/// The scheduler:
///  - batches bursts: the first request starts a short delay, and every
///    request during that delay rides along with the same sync;
///  - never runs two syncs at once: a request during a sync queues exactly
///    one follow-up run;
///  - retries failures with exponential backoff (2s, 4s, 8s… up to 2 min).
public actor SyncScheduler {
    public enum Reason: String, Sendable {
        case localChange, remoteChange, appActive, networkRestored, timer, manual, retry
    }

    public enum Event: Sendable, Equatable {
        case started
        case finished(SyncReport)
        case failed(String, retryIn: Duration)
    }

    public typealias Operation = @Sendable () async throws -> SyncReport
    public typealias Observer = @Sendable (Event) async -> Void

    private let operation: Operation
    private let observer: Observer
    private let batchDelay: Duration
    private let baseRetryDelay: Duration
    private let maxRetryDelay: Duration

    private var pending: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var isRunning = false
    private var runAgain = false
    private var consecutiveFailures = 0
    private var isStopped = false

    public private(set) var runCount = 0

    public init(
        batchDelay: Duration = .milliseconds(1500),
        baseRetryDelay: Duration = .seconds(2),
        maxRetryDelay: Duration = .seconds(120),
        operation: @escaping Operation,
        observer: @escaping Observer = { _ in }
    ) {
        self.batchDelay = batchDelay
        self.baseRetryDelay = baseRetryDelay
        self.maxRetryDelay = maxRetryDelay
        self.operation = operation
        self.observer = observer
    }

    /// Asks for a sync soon. Cheap to call often.
    public func request(_ reason: Reason) {
        guard !isStopped else { return }
        if isRunning {
            runAgain = true
            return
        }
        if reason == .manual {
            // Explicit request: skip the batching delay.
            pending?.cancel()
            pending = nil
            Task { await self.runNow() }
            return
        }
        guard pending == nil else { return }  // already scheduled; this request rides along
        let delay = batchDelay
        pending = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self.runNow()
        }
    }

    /// Stops all scheduled work (e.g. on sign-out). Requests are ignored until `resume()`.
    public func stop() {
        isStopped = true
        pending?.cancel()
        pending = nil
        retryTask?.cancel()
        retryTask = nil
        runAgain = false
    }

    public func resume() {
        isStopped = false
        consecutiveFailures = 0
    }

    private func runNow() async {
        pending = nil
        guard !isRunning, !isStopped else { return }
        isRunning = true
        retryTask?.cancel()
        retryTask = nil

        repeat {
            runAgain = false
            runCount += 1
            await observer(.started)
            do {
                let report = try await operation()
                consecutiveFailures = 0
                await observer(.finished(report))
            } catch {
                consecutiveFailures += 1
                let delay = retryDelay(after: consecutiveFailures)
                await observer(.failed(error.localizedDescription, retryIn: delay))
                scheduleRetry(after: delay)
                runAgain = false  // the retry covers anything requested meanwhile
            }
        } while runAgain && !isStopped

        isRunning = false
    }

    private func scheduleRetry(after delay: Duration) {
        retryTask?.cancel()
        retryTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self.request(.retry)
        }
    }

    func retryDelay(after failures: Int) -> Duration {
        let factor = 1 << min(failures - 1, 10)
        return min(baseRetryDelay * factor, maxRetryDelay)
    }
}
