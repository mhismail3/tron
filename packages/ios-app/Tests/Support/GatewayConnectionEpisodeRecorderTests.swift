import Foundation
import Synchronization
import Testing
@testable import TronMobile

/// Failure modes this suite exists to catch, written before the code:
/// 1. the reconnect-stall watchdog ticks while the app is backgrounded;
/// 2. an episode record spans a background transition instead of ending at it;
/// 3. a second recorder writing to the same always-on log (a second lifecycle,
///    or the dashboard pool entry C-5 owns) mixes its attempts into this
///    recorder's episode, or breaks attempt-before-episode order;
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
            startedAt: clock.clock.now(), connectionID: 12,
            gatewayConnectionID: "88b1f0f0-0000-4000-8000-000000000001"
        ))

        let attempts = try await waitForRecords(log, event: "gateway.attempt", count: 2)
        #expect(attempts.map(\.outcome) == ["failure", "success"])
        #expect(attempts[0].message.contains("attemptId=loop-9"))
        #expect(attempts[0].message.contains("owner=selected"))
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
        // two attempt starts is 7 s, and 7 s is the maximum.
        #expect(episode.message.contains("maxGapBetweenAttemptsMs=7000"))
        #expect(episode.message.contains("foregroundMs=11000"))
        #expect(episode.message.contains("endedBy=connected"))
        #expect(episode.message.contains("startedAt="))
        #expect(episode.message.contains("endedAt="))
    }

    @Test("two recorders on one always-on log stay attributable and ordered")
    func concurrentRecordersStaySeparated() async throws {
        let clock = ManualClock()
        let (log, cleanup) = makeAppLog()
        defer { cleanup() }
        // Production shape: one recorder per lifecycle owner, all writing to the
        // one always-on log. The second recorder here is the shape a second
        // lifecycle (or the dashboard pool entry C-5 owns) would have.
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
        // Only the recorder whose episode ended writes one, and it carries its
        // own profile and causes; the other recorder's attempt never joins it.
        #expect(episodes.count == 1)
        #expect(episodes[0].profileID == "gateway-a")
        #expect(episodes[0].message.contains("causes=timeout"))
        #expect(episodes[0].message.contains("attempts=2"))
        #expect(await recordCount(log, event: "connection.episode") == 1)
    }

    @Test("a synchronously blocked main actor is reported with the block it served")
    func blockedMainActorIsMeasuredAndReported() async throws {
        let (log, cleanup) = makeAppLog()
        defer { cleanup() }
        // The production ping and the production clocks: the watchdog measures a
        // real hop to the main actor. A watchdog that inherited the recorder's
        // main-actor isolation would queue its own wake-up behind the block and
        // report microseconds, or nothing at all.
        let recorder = GatewayConnectionEpisodeRecorder(
            clock: .continuous, appLog: log, watchdogClock: .continuous
        )
        recorder.stallGuard = { .other }
        recorder.noteDisconnected(profileID: "gateway", lifecycleGeneration: 1, foreground: true)

        // The block starts inside the same main-actor stretch that opened the
        // episode, so the ticks that fire while it is held are served by it. The
        // tick grid can consume one interval of the block and the detached loop's
        // first wake-up a further one; everything else in the record is the block
        // itself, which a stalled main actor could not have produced.
        let blockedFrom = ContinuousClock().now
        blockMainThread(for: .seconds(5))
        let blockedMs = diagnosticMilliseconds(blockedFrom.duration(to: ContinuousClock().now))
        let intervalMs = diagnosticMilliseconds(GatewayConnectionEpisodeRecorder.watchdogInterval)
        let boundMs = diagnosticMilliseconds(GatewayConnectionEpisodeRecorder.mainStallBound)

        let stalls = try await waitForRecords(log, event: "app.main-stall", count: 1)
        #expect(stalls.count == 1)
        #expect((stalls[0].durationMs ?? 0) >= boundMs)
        #expect((stalls[0].durationMs ?? 0) >= blockedMs - 2 * intervalMs)
        #expect(stalls[0].message.contains("boundMs=2000"))
        #expect(stalls[0].message.contains("foreground=true"))
        #expect(stalls[0].level == "warning")
        #expect(stalls[0].outcome == "failure")

        // An episode that ends stops the watchdog: the same block is not recorded
        // again under a lifecycle that no longer owns it. A watchdog that was
        // never stopped finishes its ping and writes through its own task after
        // the block ends, so give a would-be record a bounded window to land
        // before counting.
        recorder.endEpisode(.background, profileID: "gateway", lifecycleGeneration: 1)
        await Task.yield()
        blockMainThread(for: .seconds(2.5))
        try await Task.sleep(for: .milliseconds(500))
        #expect(await recordCount(log, event: "app.main-stall") == 1)
    }

    @Test("a dropped connection after a handshake is dated at the drop, not as a second attempt")
    func postConnectFailureDoesNotReworkTheConnectedEpisode() async throws {
        let clock = ManualClock()
        let (log, cleanup) = makeAppLog()
        defer { cleanup() }
        let recorder = GatewayConnectionEpisodeRecorder(
            clock: clock.clock, appLog: log, watchdogClock: clock.clock, mainStallPing: {}
        )
        recorder.stallGuard = { .other }

        // One failed attempt, then the attempt whose handshake succeeds.
        recorder.recordAttempt(attempt(
            profileID: "gateway", lifecycleGeneration: 1, attemptID: "loop-3", retry: 1,
            stageReached: "transport-open", reason: "timeout", succeeded: false,
            startedAt: clock.clock.now()
        ))
        clock.advance(by: .seconds(4))
        let connectingAttemptStart = clock.clock.now()
        recorder.recordAttempt(attempt(
            profileID: "gateway", lifecycleGeneration: 1, attemptID: "loop-3", retry: 2,
            stageReached: "connected", reason: nil, succeeded: true,
            startedAt: connectingAttemptStart, connectionID: 21
        ))
        // Projection runs for 6 s on the connection that handshake established,
        // and then that same connection drops.
        clock.advance(by: .seconds(6))
        recorder.recordAttempt(attempt(
            profileID: "gateway", lifecycleGeneration: 1, attemptID: "loop-3#postConnect", retry: 2,
            stageReached: GatewayConnectionEpisodeRecorder.postConnectStage,
            reason: "disconnected", succeeded: false, startedAt: connectingAttemptStart
        ))
        clock.advance(by: .seconds(2))
        recorder.recordAttempt(attempt(
            profileID: "gateway", lifecycleGeneration: 1, attemptID: "loop-3", retry: 3,
            stageReached: "connected", reason: nil, succeeded: true,
            startedAt: clock.clock.now(), connectionID: 22
        ))

        let attempts = try await waitForRecords(log, event: "gateway.attempt", count: 4)
        #expect(attempts.map(\.outcome) == ["failure", "success", "failure", "success"])
        #expect(attempts[2].message.contains("attemptId=loop-3#postConnect"))
        #expect(attempts[2].message.contains("stageReached=postConnect"))
        let episodes = try await waitForRecords(log, event: "connection.episode", count: 2)
        #expect(episodes.map(\.outcome) == ["connected", "connected"])
        // The first episode is the outage the two attempts resolved.
        #expect(episodes[0].message.contains("attempts=2"))
        #expect(episodes[0].message.contains("foregroundMs=4000"))
        // The post-connect failure is the same attempt's established connection
        // dropping, not a further attempt: the episode it opens is dated at the
        // drop (no 6 s of the episode that just ended is counted again) and it
        // counts only the attempt that followed.
        let resolved = episodes[1]
        #expect(resolved.message.contains("attempts=1"))
        #expect(resolved.message.contains("causes=disconnected"))
        #expect(resolved.message.contains("foregroundMs=2000"))
        let firstEndedAt = try #require(episodeDate("endedAt", in: episodes[0]))
        let secondStartedAt = try #require(episodeDate("startedAt", in: resolved))
        #expect(secondStartedAt >= firstEndedAt)
    }

    /// Parses one `connection.episode` wall-clock field, so an assertion compares
    /// instants rather than the ISO text.
    private func episodeDate(_ key: String, in record: AppLogRecord) -> Date? {
        guard let range = record.message.range(of: "\(key)=") else { return nil }
        let value = record.message[range.upperBound...].prefix { !$0.isWhitespace }
        return GatewayTimestamp.parse(String(value))
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
        gatewayConnectionID: String? = nil,
        owner: GatewayConnectionAttemptOwner = .selected
    ) -> GatewayConnectionAttempt {
        GatewayConnectionAttempt(
            owner: owner,
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

/// Blocks the calling thread synchronously — the main thread, in a `@MainActor`
/// test. That is what a blocked main actor is: no suspension point for the
/// runtime to drain its queue at. `Thread.sleep` is unavailable from an async
/// context, so the block lives in this synchronous helper.
private func blockMainThread(for duration: Duration) {
    Thread.sleep(forTimeInterval: Double(duration.components.seconds)
        + Double(duration.components.attoseconds) / 1e18)
}
