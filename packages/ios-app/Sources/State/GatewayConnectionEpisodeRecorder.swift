import Foundation
import TronMobileCore

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

/// Which owner made an attempt. Both write to the one always-on log, and a
/// profile switch moves a profile between them, so the profile ID alone cannot
/// say which one an attempt came from.
enum GatewayConnectionAttemptOwner: String, Sendable {
    case selected
    case pool
}

/// One finished connection attempt, in exactly the fields `gateway.attempt`
/// records. `stageReached` is the furthest handshake stage it reached;
/// `delayBeforeMs` is the wait between scheduling it and starting it.
struct GatewayConnectionAttempt: Sendable {
    let owner: GatewayConnectionAttemptOwner
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
    /// stalled. Attempts in flight and pending backoff waits both read as
    /// progress, so a healthy retry holds no guard at all; the bound only has
    /// to exceed the longest single wait a healthy timeline can have, which is
    /// the 15 s backoff cap.
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
        /// When recovery last made progress: the episode's open and every
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
    /// parks recovery and has nothing to explain. `cause` names a loss that
    /// produced no failed handshake of its own, such as a Gateway restart.
    func noteDisconnected(
        profileID: String?,
        lifecycleGeneration: Int,
        foreground: Bool,
        cause: String? = nil
    ) {
        guard foreground, episode == nil else { return }
        openEpisode(
            profileID: profileID, lifecycleGeneration: lifecycleGeneration, cause: cause
        )
    }

    deinit {
        // The watchdogs hold the recorder weakly, so they outlive it unless the
        // owning recorder cancels them here.
        watchdogTask?.cancel()
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
                "owner=\(attempt.owner.rawValue)",
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
            noteAttemptProgress(at: attempt.startedAt, reason: attempt.reason)
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
        at startedAt: ContinuousClock.Instant? = nil,
        cause: String? = nil
    ) {
        let openedAt = startedAt ?? clock.now()
        // The wall-clock start is `now` minus the time the monotonic clock has
        // already counted: an attempt failure opens the episode at that
        // attempt's own start, so writing `Date()` here would date the episode's
        // start up to a whole transport deadline after its first attempt.
        let elapsedMs = max(0, diagnosticMilliseconds(openedAt.duration(to: clock.now())))
        episode = Episode(
            startedAt: openedAt,
            startedAtWallClock: Date().addingTimeInterval(-Double(elapsedMs) / 1_000),
            profileID: profileID,
            lifecycleGeneration: lifecycleGeneration,
            lastProgressAt: openedAt,
            causes: cause.map { [$0] } ?? []
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

    /// Both watchdogs share one task: the stall check reads the guard on the
    /// main actor, and a main-stall ping is measured across the hop off it, so
    /// one grid serves both and one cancellation stops both. The task keeps the
    /// recorder weakly, so a recorder freed with an episode still open leaves
    /// nothing ticking.
    ///
    /// The task is detached on purpose, and the loop runs in a `nonisolated`
    /// function reached through a closure with no main-actor access at all. A
    /// task created from this `@MainActor` owner otherwise inherits main-actor
    /// isolation — closure isolation is inferred from what the body touches, and
    /// travels with the closure even when it is typed `@Sendable` — so the
    /// watchdog's own wake-up would queue behind the very block the ping exists
    /// to measure: it would only start timing after the block ended and report
    /// microseconds. Off the main actor, it keeps ticking while the main actor is
    /// blocked and hops to it only for the guard check (and, through the default
    /// ping, to be delayed).
    private func startWatchdogs(profileID: String?, lifecycleGeneration: Int) {
        stopWatchdogs()
        let tickClock = watchdogClock
        let ping = mainStallPing
        let interval = Self.watchdogInterval
        let boundMilliseconds = diagnosticMilliseconds(Self.mainStallBound)
        let report = mainStallReport(
            profileID: profileID, lifecycleGeneration: lifecycleGeneration,
            boundMilliseconds: boundMilliseconds
        )
        // The owner is re-acquired weakly on every tick, so a recorder freed with
        // an episode still open leaves nothing ticking.
        let owner: @Sendable () -> GatewayConnectionEpisodeRecorder? = { [weak self] in self }
        let loop: @Sendable () async -> Void = {
            await Self.runWatchdogs(
                owner: owner, tickClock: tickClock, ping: ping, interval: interval,
                boundMilliseconds: boundMilliseconds, report: report
            )
        }
        watchdogTask = Task.detached(operation: loop)
    }

    /// The shared 1 s grid, off the main actor: it measures the main-stall ping
    /// across its hop, then asks the owner which guard is holding recovery.
    nonisolated private static func runWatchdogs(
        owner: @escaping @Sendable () -> GatewayConnectionEpisodeRecorder?,
        tickClock: MonotonicClock,
        ping: @escaping @Sendable () async -> Void,
        interval: Duration,
        boundMilliseconds: Int,
        report: @escaping @Sendable (Int) -> Void
    ) async {
        while !Task.isCancelled {
            do { try await tickClock.sleep(interval) } catch { return }
            guard !Task.isCancelled else { return }
            // The owner is gone; there is nothing left to report for.
            guard let recorder = owner() else { return }
            let pingStartedAt = tickClock.now()
            await ping()
            guard !Task.isCancelled else { return }
            let blockedMs = diagnosticMilliseconds(pingStartedAt.duration(to: tickClock.now()))
            if blockedMs >= boundMilliseconds { report(blockedMs) }
            await recorder.checkStall()
        }
    }

    private func stopWatchdogs() {
        watchdogTask?.cancel()
        watchdogTask = nil
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
    /// main actor is reported with the block it actually served. The watchdog
    /// task runs off the main actor, so it can measure the block and report it
    /// once the actor answers; it exists only while an episode is open.
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
                    lifecycleGeneration: lifecycleGeneration, level: "warning",
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
