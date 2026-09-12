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

    var textLine: String {
        [
            "elapsedMs=\(elapsedMilliseconds)",
            "kind=\(kind)",
            "name=\(name)",
            outcome.map { "outcome=\($0)" },
            code.map { "code=\($0)" },
            requestID.map { "requestID=\($0)" },
            durationMilliseconds.map { "durationMs=\($0)" },
            count.map { "count=\($0)" },
            profileID.map { "profile=\($0)" },
            connectionID.map { "connection=\($0)" },
            lifecycleGeneration.map { "lifecycle=\($0)" }
        ].compactMap { $0 }.joined(separator: " ")
    }
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
            lines.append(event.textLine)
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
    var isCapturing: Bool { get }

    func recordRPC(
        method: String,
        requestID: String,
        requestStartedAt: ContinuousClock.Instant,
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
    static let maximumDurationMilliseconds = 600_000
    static let maximumEvents = 2_000
    static let maximumPendingIntervals = 2_000
    static let maximumBytes = 480 * 1024

    private struct Active {
        let id: UUID
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
        // Report text includes a summary in addition to event lines. Keeping
        // its growth budget here makes the byte cap conservative rather than
        // relying on an estimate of one event's stored properties.
        var summaryNames: Set<String>
    }

    private let lock = NSLock()
    private let clock: MonotonicClock
    private var active: Active?
    private var lastReport: DiagnosticCaptureReport?

    init(clock: MonotonicClock = .continuous) { self.clock = clock }

    var isCapturing: Bool {
        lock.lock(); defer { lock.unlock() }
        return active != nil
    }

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
        let captureID = UUID()
        let started = clock.now()
        let deadline = Task { [weak self] in
            try? await self?.clock.sleep(bounded)
            guard !Task.isCancelled else { return }
            guard self?.stop(captureID: captureID, reason: "deadline") != nil else { return }
            onDeadline?()
        }
        active = Active(
            id: captureID,
            started: started,
            startedText: GatewayTimestamp.preciseString(from: .now),
            deadline: deadline,
            events: [], bytes: 0, dropped: 0, intervalTokens: [],
            profileID: profileID.map { Self.safe($0, maximum: 64) },
            connectionID: connectionID,
            lifecycleGeneration: lifecycleGeneration.map { max(0, $0) },
            summaryNames: []
        )
        lastReport = nil
        lock.unlock()
        return true
    }

    @discardableResult
    func stop(reason: String = "user") -> DiagnosticCaptureReport? {
        stop(captureID: nil, reason: reason)
    }

    private func stop(captureID: UUID?, reason: String) -> DiagnosticCaptureReport? {
        lock.lock(); defer { lock.unlock() }
        guard let active,
              captureID == nil || active.id == captureID else { return nil }
        active.deadline.cancel()
        let report = DiagnosticCaptureReport(
            startedAt: active.startedText,
            stoppedAt: GatewayTimestamp.preciseString(from: .now),
            durationMilliseconds: elapsed(active.started),
            stopReason: Self.safe(reason, maximum: 32),
            events: active.events,
            droppedEvents: active.dropped,
            incomplete: active.dropped > 0 || !active.intervalTokens.isEmpty || reason == "deadline"
        )
        self.active = nil
        lastReport = report
        return report
    }

    func beginInterval() -> (UUID, ContinuousClock.Instant)? {
        lock.lock(); defer { lock.unlock() }
        guard var active else { return nil }
        guard active.intervalTokens.count < Self.maximumPendingIntervals else {
            active.dropped += 1
            self.active = active
            return nil
        }
        let token = UUID()
        active.intervalTokens.insert(token)
        self.active = active
        return (token, clock.now())
    }

    func recordInterval(_ token: UUID, operation: PerformanceOperation, started: ContinuousClock.Instant, result: PerformanceResult, metrics: PerformanceMetrics) {
        lock.lock(); defer { lock.unlock() }
        guard var active, active.intervalTokens.remove(token) != nil else { return }
        let event = DiagnosticCaptureEvent(
            elapsedMilliseconds: 0, kind: "operation", name: Self.operationName(operation),
            outcome: String(result.rawValue), code: nil, requestID: nil,
            durationMilliseconds: Self.boundedDuration(elapsed(started)),
            count: metrics.itemCount, profileID: active.profileID, connectionID: active.connectionID,
            lifecycleGeneration: active.lifecycleGeneration
        )
        appendLocked(event, to: &active)
        self.active = active
    }

    func recordRPC(method: String, requestID: String, requestStartedAt: ContinuousClock.Instant, outcome: String, code: String?, durationMilliseconds: Int, profileID: String?, connectionID: Int?) {
        // Request IDs are useful correlation within one export and are opaque
        // and bounded; no params, URLs, transcript data, or error text enter.
        lock.lock(); defer { lock.unlock() }
        guard var active, requestStartedAt >= active.started else { return }
        active.profileID = profileID.map { Self.safe($0, maximum: 64) }
        active.connectionID = connectionID
        appendLocked(DiagnosticCaptureEvent(
            elapsedMilliseconds: 0, kind: "rpc", name: Self.safe(method, maximum: 64),
            outcome: Self.safe(outcome, maximum: 32), code: code.map { Self.safe($0, maximum: 64) },
            requestID: Self.safe(requestID, maximum: 64),
            durationMilliseconds: Self.boundedDuration(durationMilliseconds), count: 1,
            profileID: profileID.map { Self.safe($0, maximum: 64) }, connectionID: connectionID,
            lifecycleGeneration: nil
        ), to: &active)
        self.active = active
    }

    func recordCausal(name: String, outcome: String? = nil, durationMilliseconds: Int? = nil, count: Int? = nil, profileID: String? = nil, connectionID: Int? = nil, lifecycleGeneration: Int? = nil, requestID: String? = nil) {
        record(DiagnosticCaptureEvent(
            elapsedMilliseconds: 0, kind: "causal", name: Self.safe(name, maximum: 64),
            outcome: outcome.map { Self.safe($0, maximum: 32) }, code: nil,
            requestID: requestID.map { Self.safe($0, maximum: 64) },
            durationMilliseconds: durationMilliseconds.map(Self.boundedDuration), count: count.map { max(0, $0) },
            profileID: profileID.map { Self.safe($0, maximum: 64) }, connectionID: connectionID,
            lifecycleGeneration: lifecycleGeneration.map { max(0, $0) }
        ))
    }

    private func record(_ event: DiagnosticCaptureEvent) {
        lock.lock(); defer { lock.unlock() }
        guard var active else { return }
        appendLocked(event, to: &active)
        self.active = active
    }

    private func appendLocked(_ event: DiagnosticCaptureEvent, to active: inout Active) {
        guard active.events.count < Self.maximumEvents else { active.dropped += 1; return }
        let elapsed = elapsed(active.started)
        let admitted = DiagnosticCaptureEvent(
            elapsedMilliseconds: elapsed, kind: event.kind, name: event.name, outcome: event.outcome,
            code: event.code, requestID: event.requestID,
            durationMilliseconds: event.durationMilliseconds, count: event.count,
            profileID: event.profileID, connectionID: event.connectionID,
            lifecycleGeneration: event.lifecycleGeneration
        )
        // Count the actual exported line, plus conservative room for the
        // summary line's changing counters and fixed report headers. This is
        // intentionally over-inclusive: a capture may stop early, never grow
        // beyond the advertised byte limit.
        let eventBytes = admitted.textLine.utf8.count + 1
        let summaryBytes = active.summaryNames.contains(admitted.name) ? 24 : admitted.name.utf8.count + 96
        let fixedReportBytes = 512
        let size = eventBytes + summaryBytes
        guard active.bytes + size + fixedReportBytes <= Self.maximumBytes else {
            active.dropped += 1
            return
        }
        active.summaryNames.insert(admitted.name)
        active.events.append(admitted)
        active.bytes += size
    }

    private func elapsed(_ instant: ContinuousClock.Instant) -> Int {
        diagnosticMilliseconds(instant.duration(to: clock.now()))
    }

    private static func operationName(_ operation: PerformanceOperation) -> String {
        String(describing: operation)
    }

    private static func boundedDuration(_ value: Int) -> Int {
        min(max(0, value), maximumDurationMilliseconds)
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
