import Foundation
import TronMobileCore

enum GatewayReconnectStallGuard: String, Sendable {
    case pathUnsatisfied
    case nonRetryable
    case connectionAdmissionTask
    case committedConnectionTask
    case reconnectTaskBusy
    case other
}

enum GatewayEpisodeEnd: String, Sendable {
    case connected
    case background
    case stopped
}

enum GatewayConnectionAttemptOwner: String, Sendable {
    case selected
    case pool
}

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

@MainActor
final class GatewayConnectionEpisodeRecorder {
    static let reconnectStallBound = Duration.seconds(20)
    static let mainStallBound = Duration.seconds(2)
    static let watchdogInterval = Duration.seconds(1)
    static let maximumRecordedCauses = 6

    nonisolated let clock: MonotonicClock
    nonisolated let appLog: AppLog
    nonisolated let watchdogClock: MonotonicClock
    private let networkInterfaces: @Sendable () -> String?
    private let mainStallPing: @Sendable () async -> Void

    var stallGuard: @MainActor () -> GatewayReconnectStallGuard? = { nil }

    private struct Episode {
        let startedAt: ContinuousClock.Instant
        let startedAtWallClock: Date
        let profileID: String?
        let lifecycleGeneration: Int
        var attempts = 0
        var lastProgressAt: ContinuousClock.Instant
        var guardHeldSince: ContinuousClock.Instant?
        var maximumGapMs = 0
        var causes: [String] = []
        var reportedStall = false
    }

    private var episode: Episode?
    private var watchdogTask: Task<Void, Never>?
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
        let owner: @Sendable () -> GatewayConnectionEpisodeRecorder? = { [weak self] in self }
        let loop: @Sendable () async -> Void = {
            await Self.runWatchdogs(
                owner: owner, tickClock: tickClock, ping: ping, interval: interval,
                boundMilliseconds: boundMilliseconds, report: report
            )
        }
        watchdogTask = Task.detached(operation: loop)
    }

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
