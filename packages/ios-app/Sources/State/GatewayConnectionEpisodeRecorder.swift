import Foundation

/// Which lifecycle guard is holding recovery while an episode has no attempt in
/// flight or scheduled. `GatewayLifecycleCoordinator` answers with the guard it
/// is actually holding, so one field names the cause of a stalled episode.
enum GatewayReconnectStallGuard: String, Sendable {
    case pathUnsatisfied
    case nonRetryable
    case connectionAdmissionTask
    case committedConnectionTask
    case reconnectTaskBusy
    case other
}

/// How an episode ended. `connected` recovered the connection; `background` is
/// scene retirement, which parks recovery until the next foreground; `stopped`
/// is any terminal stop (a non-retryable failure, a profile switch, teardown).
enum GatewayEpisodeEnd: String, Sendable {
    case connected
    case background
    case stopped
}

/// One finished connection attempt, in exactly the fields `gateway.attempt`
/// records. `stageReached` is the furthest handshake stage it reached;
/// `delayBeforeMs` is the wait between scheduling it and starting it.
struct GatewayConnectionAttempt: Sendable {
    let profileID: String?
    let lifecycleGeneration: Int
    let connectionID: Int?
    let attemptID: String
    let retry: Int
    let stageReached: String
    let reason: String?
    let interfaces: String?
    let pathSatisfied: Bool
    let foreground: Bool
    let delayBeforeMs: Int
    let startedAt: ContinuousClock.Instant
    let gatewayConnectionID: String?
    let succeeded: Bool
}

/// Aggregates phone reconnect attempts into one `gateway.attempt` record each
/// and one `connection.episode` record when the outage ends, and owns the two
/// watchdogs that run only while an episode is open in the foreground:
/// `reconnect.stalled` (no attempt in flight or scheduled for the stall bound)
/// and `app.main-stall` (the main actor did not answer a ping inside its bound).
/// Recording only: it never schedules, cancels or accelerates recovery.
@MainActor
final class GatewayConnectionEpisodeRecorder {
    /// An episode with no attempt in flight or scheduled for this long is
    /// stalled. It exceeds the 15 s transport-open deadline plus one backoff
    /// interval, so a healthy retry never trips it.
    static let reconnectStallBound = Duration.seconds(20)
    /// A main actor that cannot answer a ping within this bound is stalled.
    static let mainStallBound = Duration.seconds(2)
    /// Both watchdogs tick on this grid; the logging contract forbids samplers
    /// faster than 1 s.
    static let watchdogInterval = Duration.seconds(1)
    /// A distinct cause per attempt is enough to attribute an episode; more
    /// would only lengthen the record.
    static let maximumRecordedCauses = 6

    nonisolated let clock: MonotonicClock
    nonisolated let appLog: AppLog
    /// When the watchdog checks run. It is separate from `clock` so a test that
    /// drives the lifecycle timeline on a manual clock does not have to service
    /// watchdog ticks; every bound is still measured on `clock`. Production
    /// passes the same wall clock for both.
    nonisolated let watchdogClock: MonotonicClock
    private let networkInterfaces: @Sendable () -> String?
    private let mainStallPing: @Sendable () async -> Void

    /// Answers which guard is holding recovery, or `nil` while an attempt is in
    /// flight or scheduled. The lifecycle owner sets it; the watchdog only reads.
    var stallGuard: @MainActor () -> GatewayReconnectStallGuard? = { nil }

    private struct Episode {
        let startedAt: ContinuousClock.Instant
        let startedAtWallClock: Date
        let profileID: String?
        let lifecycleGeneration: Int
        var attempts = 0
        /// When recovery last made progress: the episode's open plus every
        /// attempt start. The stall bound measures from here.
        var lastProgressAt: ContinuousClock.Instant
        /// When the current holding guard began holding, or nil while recovery
        /// is progressing.
        var guardHeldSince: ContinuousClock.Instant?
        var maximumGapMs = 0
        var causes: [String] = []
        var reportedStall = false
    }

    private var episode: Episode?
    private var watchdogTask: Task<Void, Never>?
    private var mainStallTask: Task<Void, Never>?
    /// Records are chained through one task so an attempt is always written
    /// before the episode it belongs to, whatever order the log actor serves.
    private var pendingRecord: Task<Void, Never>?

    init(
        clock: MonotonicClock,
        appLog: AppLog = .shared,
        watchdogClock: MonotonicClock? = nil,
        networkInterfaces: @escaping @Sendable () -> String? = { GatewayNetworkPathSnapshot.shared.current },
        mainStallPing: @escaping @Sendable () async -> Void = { await MainActor.run {} }
    ) {
        self.clock = clock
        self.appLog = appLog
        self.watchdogClock = watchdogClock ?? clock
        self.networkInterfaces = networkInterfaces
        self.mainStallPing = mainStallPing
    }

    /// Opens an episode at the moment a transport loss is admitted, so the
    /// silent gap before the first attempt is measurable even when no attempt
    /// ever starts. A foreground scene owns the episode; a backgrounded app
    /// parks recovery and has nothing to explain.
    func noteDisconnected(profileID: String?, lifecycleGeneration: Int, foreground: Bool) {
        guard foreground, episode == nil else { return }
        openEpisode(profileID: profileID, lifecycleGeneration: lifecycleGeneration)
    }

    func recordAttempt(_ attempt: GatewayConnectionAttempt) {
        emit(
            name: "gateway.attempt", level: "info",
            outcome: attempt.succeeded ? "success" : "failure",
            durationMilliseconds: diagnosticMilliseconds(attempt.startedAt.duration(to: clock.now())),
            profileID: attempt.profileID, connectionID: attempt.connectionID,
            lifecycleGeneration: attempt.lifecycleGeneration,
            details: [
                "profile=\(attempt.profileID ?? "unknown")",
                "attemptId=\(attempt.attemptID)",
                "retry=\(max(0, attempt.retry))",
                "stageReached=\(attempt.stageReached)",
                "reason=\(attempt.reason ?? "none")",
                "interfaces=\(attempt.interfaces ?? networkInterfaces() ?? "unknown")",
                "pathSatisfied=\(attempt.pathSatisfied)",
                "delayBeforeMs=\(max(0, attempt.delayBeforeMs))",
                "foreground=\(attempt.foreground)",
                "gatewayConnectionId=\(attempt.gatewayConnectionID ?? "none")",
            ].joined(separator: " ")
        )
        guard attempt.succeeded else {
            if episode == nil {
                openEpisode(
                    profileID: attempt.profileID,
                    lifecycleGeneration: attempt.lifecycleGeneration,
                    at: attempt.startedAt
                )
            }
            noteAttemptProgress(
                at: attempt.startedAt, reason: attempt.reason
            )
            return
        }
        guard episode != nil else { return }
        noteAttemptProgress(at: attempt.startedAt, reason: nil)
        endEpisode(.connected, connectionID: attempt.connectionID)
    }

    /// Ends an open episode with the attempt count, causes and gaps it
    /// accumulated. Called with each terminal transition of the episode.
    func endEpisode(
        _ endedBy: GatewayEpisodeEnd,
        connectionID: Int? = nil,
        profileID: String? = nil,
        lifecycleGeneration: Int? = nil
    ) {
        stopWatchdogs()
        guard let finished = episode else { return }
        episode = nil
        let endedAt = clock.now()
        let durationMs = diagnosticMilliseconds(finished.startedAt.duration(to: endedAt))
        emit(
            name: "connection.episode", level: "info", outcome: endedBy.rawValue,
            durationMilliseconds: durationMs,
            profileID: profileID ?? finished.profileID, connectionID: connectionID,
            lifecycleGeneration: lifecycleGeneration ?? finished.lifecycleGeneration,
            details: [
                "profile=\(profileID ?? finished.profileID ?? "unknown")",
                "startedAt=\(GatewayTimestamp.preciseString(from: finished.startedAtWallClock))",
                "endedAt=\(GatewayTimestamp.preciseString(from: Date()))",
                "attempts=\(finished.attempts)",
                "causes=\(finished.causes.isEmpty ? "none" : finished.causes.joined(separator: ","))",
                // Episodes only exist in the foreground: a background transition
                // ends them, so the foreground share is the whole duration.
                "foregroundMs=\(durationMs)",
                "maxGapBetweenAttemptsMs=\(finished.maximumGapMs)",
                "endedBy=\(endedBy.rawValue)",
            ].joined(separator: " ")
        )
    }

    private func openEpisode(
        profileID: String?,
        lifecycleGeneration: Int,
        at startedAt: ContinuousClock.Instant? = nil
    ) {
        let openedAt = startedAt ?? clock.now()
        episode = Episode(
            startedAt: openedAt,
            startedAtWallClock: Date(),
            profileID: profileID,
            lifecycleGeneration: lifecycleGeneration,
            lastProgressAt: openedAt
        )
        startWatchdogs(profileID: profileID, lifecycleGeneration: lifecycleGeneration)
    }

    private func noteAttemptProgress(
        at startedAt: ContinuousClock.Instant,
        reason: String?
    ) {
        guard var current = episode else { return }
        current.attempts += 1
        current.maximumGapMs = max(
            current.maximumGapMs,
            diagnosticMilliseconds(current.lastProgressAt.duration(to: startedAt))
        )
        current.lastProgressAt = max(current.lastProgressAt, startedAt)
        current.guardHeldSince = nil
        current.reportedStall = false
        if let reason, current.causes.count < Self.maximumRecordedCauses, !current.causes.contains(reason) {
            current.causes.append(reason)
        }
        episode = current
    }

    private func startWatchdogs(profileID: String?, lifecycleGeneration: Int) {
        stopWatchdogs()
        let tickClock = watchdogClock
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await tickClock.sleep(Self.watchdogInterval) } catch { return }
                guard !Task.isCancelled else { return }
                self?.checkStall()
            }
        }
        mainStallTask = Self.startMainStallMonitor(
            clock: tickClock,
            interval: Self.watchdogInterval,
            boundMilliseconds: diagnosticMilliseconds(Self.mainStallBound),
            ping: mainStallPing,
            report: mainStallReport(
                profileID: profileID, lifecycleGeneration: lifecycleGeneration,
                boundMilliseconds: diagnosticMilliseconds(Self.mainStallBound)
            )
        )
    }

    private func stopWatchdogs() {
        watchdogTask?.cancel()
        watchdogTask = nil
        mainStallTask?.cancel()
        mainStallTask = nil
    }

    private func checkStall() {
        guard var current = episode else { return }
        guard let holding = stallGuard() else {
            current.guardHeldSince = nil
            current.reportedStall = false
            episode = current
            return
        }
        guard let heldSince = current.guardHeldSince else {
            current.guardHeldSince = clock.now()
            episode = current
            return
        }
        let heldMs = diagnosticMilliseconds(heldSince.duration(to: clock.now()))
        guard heldMs >= diagnosticMilliseconds(Self.reconnectStallBound), !current.reportedStall else { return }
        current.reportedStall = true
        episode = current
        emit(
            name: "reconnect.stalled", level: "error", outcome: "stalled",
            durationMilliseconds: heldMs,
            profileID: current.profileID, connectionID: nil,
            lifecycleGeneration: current.lifecycleGeneration,
            details: [
                "guard=\(holding.rawValue)",
                "heldForMs=\(heldMs)",
                "silentForMs=\(diagnosticMilliseconds(current.lastProgressAt.duration(to: clock.now())))",
                "attempts=\(current.attempts)",
                "foreground=true",
                "boundMs=\(diagnosticMilliseconds(Self.reconnectStallBound))",
            ].joined(separator: " ")
        )
    }

    /// A main-stall ping is measured between two reads of `clock`, so a stalled
    /// main actor is reported with the block it actually served. The monitor
    /// runs off the main actor so it can measure the block and report it once
    /// the actor answers; it exists only while an episode is open.
    nonisolated private static func startMainStallMonitor(
        clock: MonotonicClock,
        interval: Duration,
        boundMilliseconds: Int,
        ping: @escaping @Sendable () async -> Void,
        report: @escaping @Sendable (Int) -> Void
    ) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                do { try await clock.sleep(interval) } catch { return }
                guard !Task.isCancelled else { return }
                let started = clock.now()
                await ping()
                guard !Task.isCancelled else { return }
                let elapsed = diagnosticMilliseconds(started.duration(to: clock.now()))
                if elapsed >= boundMilliseconds { report(elapsed) }
            }
        }
    }

    nonisolated private func mainStallReport(
        profileID: String?,
        lifecycleGeneration: Int,
        boundMilliseconds: Int
    ) -> @Sendable (Int) -> Void {
        let log = appLog
        return { durationMs in
            Task {
                await log.recordCausal(
                    name: "app.main-stall", outcome: "failure",
                    durationMilliseconds: durationMs, profileID: profileID,
                    lifecycleGeneration: lifecycleGeneration, level: "error",
                    details: "durationMs=\(durationMs) boundMs=\(boundMilliseconds) foreground=true"
                )
            }
        }
    }

    private func emit(
        name: String,
        level: String,
        outcome: String? = nil,
        durationMilliseconds: Int? = nil,
        profileID: String?,
        connectionID: Int?,
        lifecycleGeneration: Int,
        details: String
    ) {
        let log = appLog
        let previous = pendingRecord
        pendingRecord = Task {
            await previous?.value
            await log.recordCausal(
                name: name, outcome: outcome, durationMilliseconds: durationMilliseconds,
                profileID: profileID, connectionID: connectionID,
                lifecycleGeneration: lifecycleGeneration, level: level, details: details
            )
        }
    }
}
