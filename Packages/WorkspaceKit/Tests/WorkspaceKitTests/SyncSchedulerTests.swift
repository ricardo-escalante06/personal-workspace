import Foundation
import Testing
@testable import WorkspaceKit

/// Counts calls and can be told to fail or block.
private actor FakeSync {
    var calls = 0
    var failuresLeft = 0
    var holdFor: Duration = .zero

    func setFailures(_ n: Int) { failuresLeft = n }
    func setHold(_ d: Duration) { holdFor = d }

    func run() async throws -> SyncReport {
        calls += 1
        if holdFor > .zero { try? await Task.sleep(for: holdFor) }
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw URLError(.notConnectedToInternet)
        }
        return SyncReport()
    }
}

private func makeScheduler(_ fake: FakeSync) -> SyncScheduler {
    SyncScheduler(
        batchDelay: .milliseconds(50),
        baseRetryDelay: .milliseconds(40),
        maxRetryDelay: .milliseconds(200),
        operation: { try await fake.run() }
    )
}

@Suite struct SyncSchedulerTests {
    @Test func burstOfEditsBecomesOneSync() async throws {
        let fake = FakeSync()
        let scheduler = makeScheduler(fake)
        for _ in 0..<20 { await scheduler.request(.localChange) }
        try await Task.sleep(for: .milliseconds(250))
        #expect(await fake.calls == 1)
    }

    @Test func requestDuringSyncRunsExactlyOnceMore() async throws {
        let fake = FakeSync()
        await fake.setHold(.milliseconds(150))
        let scheduler = makeScheduler(fake)
        await scheduler.request(.manual)
        try await Task.sleep(for: .milliseconds(30))   // first sync is now running
        for _ in 0..<5 { await scheduler.request(.remoteChange) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(await fake.calls == 2)
    }

    @Test func manualSkipsTheBatchDelay() async throws {
        let fake = FakeSync()
        let scheduler = SyncScheduler(batchDelay: .seconds(10), operation: { try await fake.run() })
        await scheduler.request(.manual)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await fake.calls == 1)
    }

    @Test func failuresRetryWithBackoff() async throws {
        let fake = FakeSync()
        await fake.setFailures(2)
        let scheduler = makeScheduler(fake)
        await scheduler.request(.manual)
        // 1st fails → retry in 40ms → 2nd fails → retry in 80ms → 3rd succeeds.
        try await Task.sleep(for: .milliseconds(600))
        #expect(await fake.calls == 3)
        #expect(await scheduler.retryDelay(after: 1) == .milliseconds(40))
        #expect(await scheduler.retryDelay(after: 3) == .milliseconds(160))
        #expect(await scheduler.retryDelay(after: 9) == .milliseconds(200))  // capped
    }

    @Test func stopCancelsScheduledWork() async throws {
        let fake = FakeSync()
        let scheduler = makeScheduler(fake)
        await scheduler.request(.localChange)
        await scheduler.stop()
        await scheduler.request(.localChange)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await fake.calls == 0)
        await scheduler.resume()
        await scheduler.request(.manual)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await fake.calls == 1)
    }
}
