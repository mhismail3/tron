import Foundation
import os

/// Local-only phase evidence for historical chat presentation.
///
/// The server remains authoritative. These timings describe client work and
/// contain only durations, cache outcome, and bounded counts—never session IDs
/// or message content. An injected monotonic clock keeps acceptance tests
/// deterministic without adding analytics or engine state.
@MainActor
final class SessionLoadDiagnostics {
    struct Clock {
        let now: () -> TimeInterval

        @MainActor static let live = Clock {
            ProcessInfo.processInfo.systemUptime
        }
    }

    struct Snapshot: Equatable {
        var shellMs: Int?
        var cacheMs: Int?
        var cacheHit: Bool?
        var cachedEventCount: Int?
        var cachedMessageCount: Int?
        var authoritativeMs: Int?
        var authoritativeEventCount: Int?
        var authoritativeMessageCount: Int?
        var interactiveMs: Int?
    }

    private static let signpostLog = OSLog(
        subsystem: "com.tron.mobile",
        category: "SessionLoad"
    )

    private let clock: Clock
    private let log: (String) -> Void
    private let startedAt: TimeInterval
    private var cacheRecorded = false
    private var intervalEnded = false
    private(set) var snapshot = Snapshot()

    init(
        clock: Clock = .live,
        log: @escaping (String) -> Void = { message in
            TronLogger.shared.info(message, category: .session)
        }
    ) {
        self.clock = clock
        self.log = log
        self.startedAt = clock.now()
        os_signpost(.begin, log: Self.signpostLog, name: "HistoricalSessionLoad")
    }

    func recordShellPresented() {
        guard snapshot.shellMs == nil else { return }
        snapshot.shellMs = elapsedMilliseconds()
        emit("shell", fields: "elapsedMs=\(snapshot.shellMs ?? 0)")
    }

    func recordCache(hit: Bool, eventCount: Int, messageCount: Int) {
        guard !cacheRecorded else { return }
        cacheRecorded = true
        snapshot.cacheMs = elapsedMilliseconds()
        snapshot.cacheHit = hit
        snapshot.cachedEventCount = eventCount
        snapshot.cachedMessageCount = messageCount
        emit(
            "cache",
            fields: "elapsedMs=\(snapshot.cacheMs ?? 0) hit=\(hit) events=\(eventCount) messages=\(messageCount)"
        )
    }

    func recordAuthoritative(eventCount: Int, messageCount: Int) {
        snapshot.authoritativeMs = elapsedMilliseconds()
        snapshot.authoritativeEventCount = eventCount
        snapshot.authoritativeMessageCount = messageCount
        emit(
            "authoritative",
            fields: "elapsedMs=\(snapshot.authoritativeMs ?? 0) events=\(eventCount) messages=\(messageCount)"
        )
    }

    func recordInteractive() {
        guard snapshot.interactiveMs == nil else { return }
        snapshot.interactiveMs = elapsedMilliseconds()
        emit("interactive", fields: "elapsedMs=\(snapshot.interactiveMs ?? 0)")
        guard !intervalEnded else { return }
        intervalEnded = true
        os_signpost(.end, log: Self.signpostLog, name: "HistoricalSessionLoad")
    }

    private func elapsedMilliseconds() -> Int {
        max(0, Int(((clock.now() - startedAt) * 1_000).rounded()))
    }

    private func emit(_ phase: String, fields: String) {
        os_signpost(.event, log: Self.signpostLog, name: "SessionLoadPhase")
        log("[SESSION_LOAD] phase=\(phase) \(fields)")
    }
}
