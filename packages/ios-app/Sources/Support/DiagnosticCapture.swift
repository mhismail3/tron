import Foundation

/// A deliberately narrow, opt-in capture of operation boundaries. This is not
/// telemetry: it exists to explain one user-observed slowdown and is exported
/// only when the user asks Logs to do so.
struct DiagnosticCaptureEvent: Codable, Equatable, Sendable {
    let elapsedMilliseconds: Int
    let kind: String
    let name: String
    let outcome: String?
    let code: String?
    let requestID: String?
    let durationMilliseconds: Int?
    let count: Int?
    let profileID: String?
    let connectionID: Int?
    let lifecycleGeneration: Int?
}

struct DiagnosticCaptureReport: Codable, Equatable, Sendable {
    let startedAt: String
    let stoppedAt: String
    let durationMilliseconds: Int
    let stopReason: String
    let events: [DiagnosticCaptureEvent]
    let droppedEvents: Int
    let incomplete: Bool

    var text: String {
        var lines = [
            "Tron Diagnostic Capture",
            "startedAt=\(startedAt)",
            "stoppedAt=\(stoppedAt)",
            "durationMs=\(durationMilliseconds)",
            "stopReason=\(stopReason)",
            "events=\(events.count)",
            "droppedEvents=\(droppedEvents)",
            "incomplete=\(incomplete)",
            ""
        ]
        var summary: [String: (count: Int, total: Int, maximum: Int)] = [:]
        for event in events {
            let duration = event.durationMilliseconds ?? 0
            let current = summary[event.name] ?? (0, 0, 0)
            summary[event.name] = (current.count + 1, current.total + duration, max(current.maximum, duration))
        }
        lines.append("Summary")
        for name in summary.keys.sorted() {
            let value = summary[name]!
            lines.append("operation=\(name) count=\(value.count) totalMs=\(value.total) maxMs=\(value.maximum)")
        }
        lines.append("")
        lines.append("Events")
        for event in events {
            let fields = [
                "elapsedMs=\(event.elapsedMilliseconds)",
                "kind=\(event.kind)",
                "name=\(event.name)",
                event.outcome.map { "outcome=\($0)" },
                event.code.map { "code=\($0)" },
                event.requestID.map { "requestID=\($0)" },
                event.durationMilliseconds.map { "durationMs=\($0)" },
                event.count.map { "count=\($0)" },
                event.profileID.map { "profile=\($0)" },
                event.connectionID.map { "connection=\($0)" },
                event.lifecycleGeneration.map { "lifecycle=\($0)" }
            ].compactMap { $0 }
            lines.append(fields.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }
}

enum DiagnosticCaptureState: Equatable, Sendable {
    case idle
    case capturing(elapsedMilliseconds: Int, eventCount: Int)
    case completed
}

protocol DiagnosticCaptureRPCSink: Sendable {
    func recordRPC(
        method: String,
        requestID: String,
        outcome: String,
        code: String?,
        durationMilliseconds: Int,
        profileID: String?,
        connectionID: Int?
    )
}

/// Lock-backed because intervals finish on several actor/task owners. Disabled
/// calls do one boolean check and do not create tasks, write files, or retain
/// data.
final class DiagnosticCaptureCoordinator: DiagnosticCaptureRPCSink, @unchecked Sendable {
    static let defaultDuration = Duration.seconds(300)
    static let maximumDuration = Duration.seconds(600)
    static let maximumEvents = 2_000
    static let maximumBytes = 480 * 1024

    private struct Active {
        let started: ContinuousClock.Instant
        let startedText: String
        let deadline: Task<Void, Never>
        var events: [DiagnosticCaptureEvent]
        var bytes: Int
        var dropped: Int
        var intervalTokens: Set<UUID>
        var profileID: String?
        var connectionID: Int?
        var lifecycleGeneration: Int?
    }

    private let lock = NSLock()
    private let clock: MonotonicClock
    private var active: Active?
    private var lastReport: DiagnosticCaptureReport?

    init(clock: MonotonicClock = .continuous) { self.clock = clock }

    var state: DiagnosticCaptureState {
        lock.lock(); defer { lock.unlock() }
        guard let active else { return lastReport == nil ? .idle : .completed }
        return .capturing(elapsedMilliseconds: elapsed(active.started), eventCount: active.events.count)
    }

    var report: DiagnosticCaptureReport {
        lock.lock(); defer { lock.unlock() }
        return lastReport ?? DiagnosticCaptureReport(
            startedAt: "unknown", stoppedAt: "unknown", durationMilliseconds: 0,
            stopReason: "none", events: [], droppedEvents: 0, incomplete: true
        )
    }

    @discardableResult
    func start(
        duration: Duration = defaultDuration,
        profileID: String? = nil,
        connectionID: Int? = nil,
        lifecycleGeneration: Int? = nil,
        onDeadline: (@Sendable () -> Void)? = nil
    ) -> Bool {
        let bounded = min(max(duration, .seconds(1)), Self.maximumDuration)
        lock.lock()
        active?.deadline.cancel()
        let started = clock.now()
        let deadline = Task { [weak self] in
            try? await self?.clock.sleep(bounded)
            guard !Task.isCancelled else { return }
            _ = self?.stop(reason: "deadline")
            onDeadline?()
        }
        active = Active(
            started: started,
            startedText: GatewayTimestamp.preciseString(from: .now),
            deadline: deadline,
            events: [], bytes: 0, dropped: 0, intervalTokens: [],
            profileID: profileID.map { Self.safe($0, maximum: 64) },
            connectionID: connectionID,
            lifecycleGeneration: lifecycleGeneration.map { max(0, $0) }
        )
        lastReport = nil
        lock.unlock()
        return true
    }

    @discardableResult
    func stop(reason: String = "user") -> DiagnosticCaptureReport? {
        lock.lock(); defer { lock.unlock() }
        guard let active else { return lastReport }
        active.deadline.cancel()
        let report = DiagnosticCaptureReport(
            startedAt: active.startedText,
            stoppedAt: GatewayTimestamp.preciseString(from: .now),
            durationMilliseconds: elapsed(active.started),
            stopReason: Self.safe(reason, maximum: 32),
            events: active.events,
            droppedEvents: active.dropped,
            incomplete: active.dropped > 0 || reason == "deadline"
        )
        self.active = nil
        lastReport = report
        return report
    }

    func beginInterval() -> (UUID, ContinuousClock.Instant)? {
        lock.lock(); defer { lock.unlock() }
        guard var active else { return nil }
        let token = UUID()
        active.intervalTokens.insert(token)
        self.active = active
        return (token, clock.now())
    }

    func recordInterval(_ token: UUID, operation: PerformanceOperation, started: ContinuousClock.Instant, result: PerformanceResult, metrics: PerformanceMetrics) {
        lock.lock()
        guard var active, active.intervalTokens.remove(token) != nil else {
            lock.unlock()
            return
        }
        let profileID = active.profileID
        let connectionID = active.connectionID
        let lifecycleGeneration = active.lifecycleGeneration
        self.active = active
        lock.unlock()
        record(
            DiagnosticCaptureEvent(
                elapsedMilliseconds: 0, kind: "operation", name: Self.operationName(operation),
                outcome: String(result.rawValue), code: nil, requestID: nil, durationMilliseconds: elapsed(started),
                count: metrics.itemCount, profileID: profileID, connectionID: connectionID,
                lifecycleGeneration: lifecycleGeneration
            )
        )
    }

    func recordRPC(method: String, requestID: String, outcome: String, code: String?, durationMilliseconds: Int, profileID: String?, connectionID: Int?) {
        // Request IDs are useful correlation within one export and are opaque
        // and bounded; no params, URLs, transcript data, or error text enter.
        lock.lock()
        if var active {
            active.profileID = profileID.map { Self.safe($0, maximum: 64) }
            active.connectionID = connectionID
            self.active = active
        }
        lock.unlock()
        record(DiagnosticCaptureEvent(
            elapsedMilliseconds: 0, kind: "rpc", name: Self.safe(method, maximum: 64),
            outcome: Self.safe(outcome, maximum: 32), code: code.map { Self.safe($0, maximum: 64) },
            requestID: Self.safe(requestID, maximum: 64), durationMilliseconds: max(0, durationMilliseconds), count: 1,
            profileID: profileID.map { Self.safe($0, maximum: 64) }, connectionID: connectionID,
            lifecycleGeneration: nil
        ))
    }

    func recordCausal(name: String, outcome: String? = nil, durationMilliseconds: Int? = nil, count: Int? = nil, profileID: String? = nil, connectionID: Int? = nil, lifecycleGeneration: Int? = nil, requestID: String? = nil) {
        record(DiagnosticCaptureEvent(
            elapsedMilliseconds: 0, kind: "causal", name: Self.safe(name, maximum: 64),
            outcome: outcome.map { Self.safe($0, maximum: 32) }, code: nil,
            requestID: requestID.map { Self.safe($0, maximum: 64) },
            durationMilliseconds: durationMilliseconds.map { max(0, $0) }, count: count.map { max(0, $0) },
            profileID: profileID.map { Self.safe($0, maximum: 64) }, connectionID: connectionID,
            lifecycleGeneration: lifecycleGeneration.map { max(0, $0) }
        ))
    }

    private func record(_ event: DiagnosticCaptureEvent) {
        lock.lock(); defer { lock.unlock() }
        guard var active else { return }
        guard active.events.count < Self.maximumEvents else { active.dropped += 1; self.active = active; return }
        let size = event.name.utf8.count + 96
        guard active.bytes + size <= Self.maximumBytes else { active.dropped += 1; self.active = active; return }
        let elapsed = elapsed(active.started)
        active.events.append(DiagnosticCaptureEvent(
            elapsedMilliseconds: elapsed, kind: event.kind, name: event.name, outcome: event.outcome,
            code: event.code, requestID: event.requestID,
            durationMilliseconds: event.durationMilliseconds, count: event.count,
            profileID: event.profileID, connectionID: event.connectionID,
            lifecycleGeneration: event.lifecycleGeneration
        ))
        active.bytes += size
        self.active = active
    }

    private func elapsed(_ instant: ContinuousClock.Instant) -> Int {
        diagnosticMilliseconds(instant.duration(to: clock.now()))
    }

    private static func operationName(_ operation: PerformanceOperation) -> String {
        String(describing: operation)
    }

    private static func safe(_ value: String, maximum: Int) -> String {
        String(value.unicodeScalars.filter { $0.isASCII && ($0 == "-" || $0 == "_" || $0 == "." || $0 == ":" || $0.isASCII && ($0.value >= 48 && $0.value <= 57) || $0.value >= 65 && $0.value <= 90 || $0.value >= 97 && $0.value <= 122) }.prefix(maximum))
    }
}

final class DiagnosticCaptureSignposts: PerformanceSignposting, @unchecked Sendable {
    private let base: any PerformanceSignposting
    private let capture: DiagnosticCaptureCoordinator

    init(base: any PerformanceSignposting, capture: DiagnosticCaptureCoordinator) {
        self.base = base
        self.capture = capture
    }

    func begin(_ operation: PerformanceOperation) -> PerformanceInterval {
        let interval = base.begin(operation)
        guard let (token, started) = capture.beginInterval() else { return interval }
        return PerformanceInterval(
            operation: operation, state: interval.state,
            captureToken: token, captureStarted: started
        )
    }

    func end(_ interval: PerformanceInterval, result: PerformanceResult, metrics: PerformanceMetrics) {
        base.end(interval, result: result, metrics: metrics)
        guard let token = interval.captureToken else { return }
        // The coordinator rejects intervals admitted by an older capture after
        // stop/start, so late completions cannot contaminate the new report.
        guard let started = interval.captureStarted else { return }
        capture.recordInterval(token, operation: interval.operation, started: started, result: result, metrics: metrics)
    }
}
