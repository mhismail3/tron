import Foundation
import Synchronization
import Testing
@testable import TronMobile

/// Failure modes this suite exists to catch, written before the code:
/// 1. the reconnect-stall watchdog ticks while the app is backgrounded;
/// 2. an episode record spans a background transition instead of ending at it;
/// 3. two profiles attempting at once mix their attempts or their episodes;
/// 4. a blocked main actor in the foreground is never recorded, or is recorded
///    again after the episode ended;
/// 5. an attempt record loses one of the fields the export needs.
///
/// A manual clock that jumps can look like a main-actor block to the stall
/// detector, so these tests inject a ping that never blocks except where the
/// main-stall record itself is under test.
@MainActor
@Suite("Phone connection episode recorder", .serialized)
struct GatewayConnectionEpisodeRecorderTests {
    @Test("a background transition ends the episode and stops both watchdogs")
    func backgroundEndsEpisodeAndStopsWatchdogs() async throws {
        let clock = ManualClock()
        let (log, cleanup) = makeAppLog()
        defer { cleanup() }
        let recorder = GatewayConnectionEpisodeRecorder(
            clock: clock.clock, appLog: log, watchdogClock: clock.clock, mainStallPing: {}
        )
        recorder.stallGuard = { .pathUnsatisfied }

        recorder.noteDisconnected(profileID: "gateway", lifecycleGeneration: 1, foreground: true)
        recorder.recordAttempt(attempt(
            profileID: "gateway", lifecycleGeneration: 1, attemptID: "loop-1", retry: 1,
            stageReached: "transport-open", reason: "timeout", succeeded: false,
            startedAt: clock.clock.now()
        ))

        // A holding guard for longer than the bound is recorded once.
        try await clock.waitUntilSleeping(count: 1, duration: GatewayConnectionEpisodeRecorder.watchdogInterval)
        clock.advance(by: .seconds(21))
        try await clock.waitUntilSleeping(count: 1, duration: GatewayConnectionEpisodeRecorder.watchdogInterval)
        clock.advance(by: .seconds(21))
        let stalls = try await waitForRecords(log, event: "reconnect.stalled", count: 1)
        #expect(stalls.count == 1)
        #expect(stalls[0].message.contains("guard=pathUnsatisfied"))
        #expect(stalls[0].message.contains("foreground=true"))

        // The app backgrounds: the episode ends at that instant, and no watchdog
        // may run after it.
        recorder.endEpisode(.background, profileID: "gateway", lifecycleGeneration: 1)
        await Task.yield()
        clock.advance(by: .seconds(300))
        clock.advance(by: .seconds(300))
        await Task.yield()
        #expect(clock.activeSleeperCount() == 0)
        #expect(await recordCount(log, event: "reconnect.stalled") == 1)

        let episodes = try await waitForRecords(log, event: "connection.episode", count: 1)
        #expect(episodes.count == 1)
        #expect(episodes[0].message.contains("endedBy=background"))
        #expect(episodes[0].message.contains("attempts=1"))
        #expect(episodes[0].outcome == "background")
    }

    @Test("one episode explains every attempt and the gap between them")
    func episodeCarriesAttemptsAndGaps() async throws {
        let clock = ManualClock()
        let (log, cleanup) = makeAppLog()
        defer { cleanup() }
        let recorder = GatewayConnectionEpisodeRecorder(
            clock: clock.clock, appLog: log, watchdogClock: clock.clock, mainStallPing: {}
        )
        recorder.stallGuard = { .other }

        recorder.noteDisconnected(profileID: "gateway", lifecycleGeneration: 3, foreground: true)
        clock.advance(by: .seconds(4))
        recorder.recordAttempt(attempt(
            profileID: "gateway", lifecycleGeneration: 3, attemptID: "loop-9", retry: 1,
            stageReached: "transport-open", reason: "timeout", succeeded: false,
            startedAt: clock.clock.now()
        ))
        clock.advance(by: .seconds(7))
        recorder.recordAttempt(attempt(
            profileID: "gateway", lifecycleGeneration: 3, attemptID: "loop-9", retry: 2,
            stageReached: "connected", reason: nil, succeeded: true,
            gatewayConnectionID: "88b1f0f0-0000-4000-8000-000000000001",
            startedAt: clock.clock.now(), connectionID: 12
        ))

        let attempts = try await waitForRecords(log, event: "gateway.attempt", count: 2)
        #expect(attempts.map(\.outcome) == ["failure", "success"])
        #expect(attempts[0].message.contains("attemptId=loop-9"))
        #expect(attempts[0].message.contains("retry=1"))
        #expect(attempts[0].message.contains("stageReached=transport-open"))
        #expect(attempts[0].message.contains("reason=timeout"))
        #expect(attempts[0].message.contains("interfaces=wifi,other"))
        #expect(attempts[0].message.contains("pathSatisfied=true"))
        #expect(attempts[0].message.contains("delayBeforeMs=0"))
        #expect(attempts[0].message.contains("foreground=true"))
        #expect(attempts[1].message.contains("stageReached=connected"))
        #expect(attempts[1].message.contains("gatewayConnectionId=88b1f0f0-0000-4000-8000-000000000001"))

        let episodes = try await waitForRecords(log, event: "connection.episode", count: 1)
        #expect(episodes.count == 1)
        let episode = episodes[0]
        #expect(episode.message.contains("attempts=2"))
        #expect(episode.message.contains("causes=timeout"))
        // The gap from the loss to the first attempt is 4 s; the gap between the
        // two attempt starts is 7 s.
        #expect(episode.message.contains("maxGapBetweenAttemptsMs=7000"))
        #expect(episode.message.contains("foregroundMs=11000"))
        #expect(episode.message.contains("endedBy=connected"))
        #expect(episode.message.contains("startedAt="))
        #expect(episode.message.contains("endedAt="))
    }

    @Test("two profiles attempting at once keep their own attempts and episodes")
    func concurrentProfilesStaySeparated() async throws {
        let clock = ManualClock()
        let (log, cleanup) = makeAppLog()
        defer { cleanup() }
        let first = GatewayConnectionEpisodeRecorder(
            clock: clock.clock, appLog: log, watchdogClock: clock.clock, mainStallPing: {}
        )
        let second = GatewayConnectionEpisodeRecorder(
            clock: clock.clock, appLog: log, watchdogClock: clock.clock, mainStallPing: {}
        )
        first.stallGuard = { .other }
        second.stallGuard = { .other }

        first.recordAttempt(attempt(
            profileID: "gateway-a", lifecycleGeneration: 1, attemptID: "loop-a", retry: 1,
            stageReached: "transport-open", reason: "timeout", succeeded: false,
            startedAt: clock.clock.now()
        ))
        second.recordAttempt(attempt(
            profileID: "gateway-b", lifecycleGeneration: 2, attemptID: "loop-b", retry: 1,
            stageReached: "transport-open", reason: "transport", succeeded: false,
            startedAt: clock.clock.now()
        ))
        first.recordAttempt(attempt(
            profileID: "gateway-a", lifecycleGeneration: 1, attemptID: "loop-a", retry: 2,
            stageReached: "connected", reason: nil, succeeded: true,
            startedAt: clock.clock.now(), connectionID: 4
        ))

        let attempts = try await waitForRecords(log, event: "gateway.attempt", count: 3)
        #expect(attempts.filter { $0.profileID == "gateway-a" }.count == 2)
        #expect(attempts.filter { $0.profileID == "gateway-b" }.count == 1)
        let episodes = try await waitForRecords(log, event: "connection.episode", count: 1)
        #expect(episodes.count == 1)
        #expect(episodes[0].profileID == "gateway-a")
        #expect(episodes[0].message.contains("causes=timeout"))
        #expect(await recordCount(log, event: "connection.episode") == 1)
    }

    @Test("a blocked main actor is reported once it answers, and only in the foreground")
    func mainStallIsMeasuredAndGated() async throws {
        let clock = ManualClock()
        let (log, cleanup) = makeAppLog()
        defer { cleanup() }
        let gate = MainStallGate()
        let recorder = GatewayConnectionEpisodeRecorder(
            clock: clock.clock, appLog: log, watchdogClock: clock.clock, mainStallPing: { await gate.ping() }
        )
        recorder.stallGuard = { .other }

        recorder.recordAttempt(attempt(
            profileID: "gateway", lifecycleGeneration: 1, attemptID: "loop-1", retry: 1,
            stageReached: "transport-open", reason: "timeout", succeeded: false,
            startedAt: clock.clock.now()
        ))
        let monitor = Task {
            // Both watchdogs tick on this clock: the stall checker and the
            // main-actor monitor.
            try await clock.waitUntilSleeping(
                count: 2, duration: GatewayConnectionEpisodeRecorder.watchdogInterval
            )
            clock.advance(by: GatewayConnectionEpisodeRecorder.watchdogInterval)
            await gate.waitUntilCalled()
            clock.advance(by: GatewayConnectionEpisodeRecorder.mainStallBound)
            gate.release()
        }
        let stalls = try await waitForRecords(log, event: "app.main-stall", count: 1)
        try await monitor.value
        #expect(stalls.count == 1)
        #expect(stalls[0].durationMs == 2000)
        #expect(stalls[0].message.contains("boundMs=2000"))
        #expect(stalls[0].message.contains("foreground=true"))

        // An episode that ends at background stops the monitor: a later block is
        // not recorded.
        recorder.endEpisode(.background, profileID: "gateway", lifecycleGeneration: 1)
        gate.release()
        await Task.yield()
        clock.advance(by: .seconds(60))
        clock.advance(by: .seconds(60))
        await Task.yield()
        #expect(clock.activeSleeperCount() == 0)
        #expect(await recordCount(log, event: "app.main-stall") == 1)
    }

    private func attempt(
        profileID: String,
        lifecycleGeneration: Int,
        attemptID: String,
        retry: Int,
        stageReached: String,
        reason: String?,
        succeeded: Bool,
        startedAt: ContinuousClock.Instant,
        connectionID: Int? = nil,
        gatewayConnectionID: String? = nil
    ) -> GatewayConnectionAttempt {
        GatewayConnectionAttempt(
            profileID: profileID,
            lifecycleGeneration: lifecycleGeneration,
            connectionID: connectionID,
            attemptID: attemptID,
            retry: retry,
            stageReached: stageReached,
            reason: reason,
            interfaces: "wifi,other",
            pathSatisfied: true,
            foreground: true,
            delayBeforeMs: 0,
            startedAt: startedAt,
            gatewayConnectionID: gatewayConnectionID,
            succeeded: succeeded
        )
    }

    private func makeAppLog() -> (AppLog, () -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "episode-recorder-\(UUID().uuidString).jsonl")
        let cleanup = {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("1"))
        }
        return (AppLog(fileURL: url), cleanup)
    }

    private func recordCount(_ log: AppLog, event: String) async -> Int {
        await log.snapshot().filter { $0.event == event }.count
    }

    private func waitForRecords(
        _ log: AppLog, event: String, count: Int
    ) async throws -> [AppLogRecord] {
        for _ in 0..<600 {
            let values = await log.snapshot().filter { $0.event == event }
            if values.count >= count { return values }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for \(count) \(event) record(s)")
        return await log.snapshot().filter { $0.event == event }
    }
}

/// A main-actor ping a test can hold: the recorder measures the block between
/// the ping and its release.
private final class MainStallGate: Sendable {
    private struct State {
        var called = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var release: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    func ping() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.called = true
                state.release = continuation
                let waiters = state.waiters
                state.waiters = []
                return waiters
            }
            for waiter in waiters { waiter.resume() }
        }
    }

    func waitUntilCalled() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let already = state.withLock { state -> Bool in
                guard !state.called else { return true }
                state.waiters.append(continuation)
                return false
            }
            if already { continuation.resume() }
        }
    }

    func release() {
        let release = state.withLock { state -> CheckedContinuation<Void, Never>? in
            defer { state.release = nil }
            return state.release
        }
        release?.resume()
    }
}
