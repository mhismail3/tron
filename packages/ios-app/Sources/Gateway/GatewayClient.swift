import Foundation

private final class GatewayHandshakeStage: @unchecked Sendable {
    private let lock = NSLock()
    private var value: GatewayConnectionDiagnosticStage = .helloSend

    func set(_ value: GatewayConnectionDiagnosticStage) {
        lock.lock(); self.value = value; lock.unlock()
    }

    func get() -> GatewayConnectionDiagnosticStage {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

private enum GatewayTimeoutOutcome<T: Sendable>: @unchecked Sendable {
    case value(T)
    case failure(Error)
    case loser
}

private final class GatewayTimeoutWinner: @unchecked Sendable {
    private let lock = NSLock()
    private var timeoutWon = false

    func claimTimeout() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !timeoutWon else { return false }
        timeoutWon = true
        return true
    }

    func claimOperation() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !timeoutWon else { return false }
        timeoutWon = true
        return true
    }
}

enum GatewayRequestTransmissionState: Equatable {
    case queued
    case sending
    case sent

    var mayHaveBeenSent: Bool { self != .queued }
}

enum GatewayUploadPolicy {
    static let maximumRequestBytes = 25 * 1_048_576
    static let maximumResponseBytes = 64 * 1_024
}

struct GatewayEventBufferPolicy: Sendable {
    let maximumEvents: Int
    let maximumBytes: Int

    // Matches the Gateway synchronization quarantine count while the byte cap
    // remains the stricter cross-session memory bound.
    static let `default` = Self(maximumEvents: 1_024, maximumBytes: 2 * 1_024 * 1_024)
}

/// A snapshot of the Gateway transport epoch, including the disconnected state.
/// Optional reads use this value so a request captured while offline cannot
/// attach itself to a later connection.
struct GatewayConnectionAdmission: Equatable, Sendable {
    let connectionID: Int?
}

enum GatewayEventAdmissionReason: String, Sendable, Equatable {
    case countLimit = "count_limit"
    case byteLimit = "byte_limit"
    case oversizedEvent = "oversized_event"
    case retiredEpoch = "retired_epoch"
}

enum GatewayDiagnosticTopicAdmission {
    static let recognizedTopics: Set<String> = [
        "session.snapshot", "session.rebaseline", "session.summary", "session.listChanged",
        "session.message", "session.progress", "session.toolProgress", "session.extensionActivity",
        "session.extensionPresentation", "session.compaction", "session.processActivity",
        "session.closed", "session.operationFailed", "session.extensionError",
        "session.structureChanged", "session.contextChanged", "session.resourcesChanged",
        "session.processTranscript.changed", "transport.disconnected", "transport.resyncRequired",
        "system.stopping", "notification.inbox.changed", "auth.prompt", "auth.event",
        "auth.completed", "automation.changed", "settings.changed", "trust.changed",
        "providers.changed", "packages.changed", "packages.progress", "packages.completed",
        "models.customChanged", "devices.changed", "terminal.output", "terminal.exit"
    ]

    static func admit(_ topic: String) -> String {
        recognizedTopics.contains(topic) ? topic : "other"
    }
}

struct GatewayEventHubSnapshot: Sendable, Equatable {
    let bufferedEventCount: Int
    let bufferedBytes: Int
    let maximumEvents: Int
    let maximumBytes: Int
    let oldestQueuedAgeMilliseconds: Int
    let timeSinceLastDequeueMilliseconds: Int?
    let countHighWaterMark: Int
    let byteHighWaterMark: Int
    let admittedCount: Int
    let dequeuedCount: Int
    let pressureCrossings: Int
    let pressureLevels: [Int]
    let dequeueWaitAgeMilliseconds: Int?
    let dequeueWaitTopic: String?
    let dequeueWaitConnectionID: Int?
}

struct GatewayEventAdmission: Sendable, Equatable {
    let accepted: Bool
    let reason: GatewayEventAdmissionReason?
    let topic: String
    let admittedBytes: Int
    let snapshot: GatewayEventHubSnapshot
    let pressureChanged: Bool
}

actor GatewayEventHub {
    private struct BufferedDelivery {
        let delivery: GatewayEventDelivery
        let bytes: Int
        let key: String?
        let queuedAt: ContinuousClock.Instant
    }

    private let policy: GatewayEventBufferPolicy
    private let clock: MonotonicClock
    private var buffered: [BufferedDelivery] = []
    private var bufferedBytes = 0
    private var waiters: [(UUID, CheckedContinuation<GatewayEventDelivery?, Never>)] = []
    private var finished = false
    private var lastDequeuedAt: ContinuousClock.Instant?
    private var countHighWaterMark = 0
    private var byteHighWaterMark = 0
    private var admittedCount = 0
    private var dequeuedCount = 0
    private var pressureLevels: Set<Int> = []
    // Evidence follows the newest admitted epoch. During a suspended close,
    // successor admission can overlap removal of the predecessor's buffer;
    // stale deliveries must not reset successor counters or threshold state.
    private var evidenceConnectionID: Int?
    private var retiredThrough = Int.min
    private var dequeuedAt: ContinuousClock.Instant?
    private var dequeuedTopic: String?
    private var dequeuedConnectionID: Int?

    init(
        policy: GatewayEventBufferPolicy = .default,
        clock: MonotonicClock = .continuous
    ) {
        self.policy = policy
        self.clock = clock
    }

    func next() async -> GatewayEventDelivery? {
        clearDequeued()
        if let first = buffered.first {
            dequeue(first)
            markDequeued(first.delivery)
            return first.delivery
        }
        if finished || Task.isCancelled { return nil }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let first = buffered.first {
                    dequeue(first)
                    markDequeued(first.delivery)
                    continuation.resume(returning: first.delivery)
                } else if finished || Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    waiters.append((waiterID, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    /// Admission and its evidence are one actor operation. In particular, a
    /// coalesced replacement is preflighted before changing byte accounting, so
    /// a rejected replacement cannot leave the hub over its configured bound.
    func admit(_ delivery: GatewayEventDelivery, bytes: Int) -> GatewayEventAdmission {
        guard !finished, delivery.connectionID > retiredThrough,
              evidenceConnectionID.map({ delivery.connectionID >= $0 }) ?? true else {
            return outcome(false, reason: .retiredEpoch, delivery: delivery, bytes: bytes)
        }
        return enqueue(delivery, bytes: bytes)
    }

    private func enqueue(_ delivery: GatewayEventDelivery, bytes: Int) -> GatewayEventAdmission {
        beginEvidence(for: delivery.connectionID)
        let byteCount = max(0, bytes)
        let key = coalescingKey(for: delivery)
        if byteCount > policy.maximumBytes {
            return outcome(false, reason: .oversizedEvent, delivery: delivery, bytes: byteCount)
        }
        if !waiters.isEmpty {
            let (_, waiter) = waiters.removeFirst()
            markDequeued(delivery)
            waiter.resume(returning: delivery)
            lastDequeuedAt = clock.now()
            admittedCount = admittedCount.saturatingIncremented()
            dequeuedCount = dequeuedCount.saturatingIncremented()
            return outcome(true, reason: nil, delivery: delivery, bytes: byteCount)
        }
        if let key, let index = buffered.lastIndex(where: { $0.key == key }) {
            let replacementBytes = bufferedBytes - buffered[index].bytes + byteCount
            guard replacementBytes <= policy.maximumBytes else {
                return outcome(false, reason: .byteLimit, delivery: delivery, bytes: byteCount)
            }
            bufferedBytes = replacementBytes
            buffered[index] = BufferedDelivery(
                delivery: delivery, bytes: byteCount, key: key,
                queuedAt: min(buffered[index].queuedAt, clock.now())
            )
            admittedCount = admittedCount.saturatingIncremented()
            updateHighWaterMarks()
            let pressureChanged = notePressure()
            return outcome(true, reason: nil, delivery: delivery, bytes: byteCount, pressureChanged: pressureChanged)
        }
        if buffered.count >= policy.maximumEvents {
            return outcome(false, reason: .countLimit, delivery: delivery, bytes: byteCount)
        }
        guard bufferedBytes <= policy.maximumBytes - byteCount else {
            return outcome(false, reason: .byteLimit, delivery: delivery, bytes: byteCount)
        }
        buffered.append(BufferedDelivery(
            delivery: delivery, bytes: byteCount, key: key, queuedAt: clock.now()
        ))
        bufferedBytes += byteCount
        admittedCount = admittedCount.saturatingIncremented()
        updateHighWaterMarks()
        let pressureChanged = notePressure()
        return outcome(true, reason: nil, delivery: delivery, bytes: byteCount, pressureChanged: pressureChanged)
    }

    func snapshot() -> GatewayEventHubSnapshot { makeSnapshot(now: clock.now()) }

    private func dequeue(_ value: BufferedDelivery) {
        buffered.removeFirst()
        bufferedBytes -= value.bytes
        lastDequeuedAt = clock.now()
        if value.delivery.connectionID == evidenceConnectionID {
            dequeuedCount = dequeuedCount.saturatingIncremented()
        }
    }

    private func outcome(
        _ accepted: Bool,
        reason: GatewayEventAdmissionReason?,
        delivery: GatewayEventDelivery,
        bytes: Int,
        pressureChanged: Bool = false
    ) -> GatewayEventAdmission {
        GatewayEventAdmission(
            accepted: accepted,
            reason: reason,
            topic: admittedTopic(delivery.event.topic),
            admittedBytes: max(0, bytes),
            snapshot: makeSnapshot(now: clock.now()),
            pressureChanged: pressureChanged
        )
    }

    private func makeSnapshot(now: ContinuousClock.Instant) -> GatewayEventHubSnapshot {
        GatewayEventHubSnapshot(
            bufferedEventCount: buffered.count,
            bufferedBytes: max(0, bufferedBytes),
            maximumEvents: policy.maximumEvents,
            maximumBytes: policy.maximumBytes,
            oldestQueuedAgeMilliseconds: buffered.first.map { milliseconds($0.queuedAt.duration(to: now)) } ?? 0,
            timeSinceLastDequeueMilliseconds: lastDequeuedAt.map { milliseconds($0.duration(to: now)) },
            countHighWaterMark: countHighWaterMark,
            byteHighWaterMark: byteHighWaterMark,
            admittedCount: admittedCount,
            dequeuedCount: dequeuedCount,
            pressureCrossings: pressureLevels.count,
            pressureLevels: pressureLevels.sorted(),
            dequeueWaitAgeMilliseconds: dequeuedAt.map { milliseconds($0.duration(to: now)) },
            dequeueWaitTopic: dequeuedTopic,
            dequeueWaitConnectionID: dequeuedConnectionID
        )
    }

    private func updateHighWaterMarks() {
        countHighWaterMark = max(countHighWaterMark, buffered.count)
        byteHighWaterMark = max(byteHighWaterMark, bufferedBytes)
    }

    private func notePressure() -> Bool {
        guard policy.maximumEvents > 0, policy.maximumBytes > 0 else { return false }
        let previousCount = pressureLevels.count
        let ratio = max(Double(buffered.count) / Double(policy.maximumEvents), Double(bufferedBytes) / Double(policy.maximumBytes))
        for level in [50, 75, 90, 100] where ratio >= Double(level) / 100 {
            pressureLevels.insert(level)
        }
        return pressureLevels.count > previousCount
    }

    private func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let value = components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
        return Int(max(0, min(Int64(Int.max), value)))
    }

    private func admittedTopic(_ topic: String) -> String {
        GatewayDiagnosticTopicAdmission.admit(topic)
    }

    private func markDequeued(_ delivery: GatewayEventDelivery) {
        dequeuedAt = clock.now()
        dequeuedTopic = admittedTopic(delivery.event.topic)
        dequeuedConnectionID = delivery.connectionID
    }

    private func clearDequeued() {
        dequeuedAt = nil
        dequeuedTopic = nil
        dequeuedConnectionID = nil
    }

    private func beginEvidence(for connectionID: Int) {
        guard evidenceConnectionID != connectionID else { return }
        // A replacement epoch supersedes queued predecessor projections. This
        // runs before capacity checks; stale backlog cannot retire its successor.
        buffered.removeAll { $0.delivery.connectionID < connectionID }
        bufferedBytes = buffered.reduce(0) { $0 + $1.bytes }
        evidenceConnectionID = connectionID
        admittedCount = 0
        dequeuedCount = 0
        countHighWaterMark = 0
        byteHighWaterMark = 0
        pressureLevels.removeAll()
        lastDequeuedAt = nil
        clearDequeued()
    }

    private func coalescingKey(for delivery: GatewayEventDelivery) -> String? {
        let prefix = "connection:\(delivery.connectionID):"
        switch delivery.event.preparation {
        case .sessionSummary(let update): return "\(prefix)summary:\(update.sessionId)"
        case .none where delivery.event.topic == "session.listChanged": return "\(prefix)listChanged"
        case .none where delivery.event.topic == "notification.inbox.changed": return "\(prefix)notificationInboxChanged"
        case .none where delivery.event.topic == "knowledge.changed": return "\(prefix)knowledgeChanged"
        case .none where delivery.event.topic == "devices.changed": return "\(prefix)devicesChanged"
        case .automationChanged: return "\(prefix)automationChanged"
        default: return nil
        }
    }

    func reset(connectionID: Int, notification: GatewayEvent? = nil) {
        let mayNotify = !finished && connectionID > retiredThrough
            && (evidenceConnectionID.map { connectionID >= $0 } ?? true)
        retiredThrough = max(retiredThrough, connectionID)
        buffered.removeAll { $0.delivery.connectionID <= retiredThrough }
        bufferedBytes = buffered.reduce(0) { $0 + $1.bytes }
        if let owner = evidenceConnectionID, owner <= retiredThrough {
            evidenceConnectionID = nil
            admittedCount = 0
            dequeuedCount = 0
            countHighWaterMark = buffered.count
            byteHighWaterMark = bufferedBytes
            pressureLevels.removeAll()
            lastDequeuedAt = nil
        }
        if let owner = dequeuedConnectionID, owner <= retiredThrough { clearDequeued() }
        // Only the retirement owner may enqueue its final control notification.
        // Ordinary frames remain fenced, including after the buffer is empty.
        if mayNotify, let notification {
            _ = enqueue(GatewayEventDelivery(connectionID: connectionID, event: notification), bytes: notification.admittedBytes)
        }
    }

    func finish() {
        finished = true
        buffered.removeAll(keepingCapacity: false)
        bufferedBytes = 0
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.1.resume(returning: nil) }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        let (_, waiter) = waiters.remove(at: index)
        waiter.resume(returning: nil)
    }
}

private extension Int {
    func saturatingIncremented() -> Int { self == Int.max ? self : self + 1 }
}

struct GatewayEventStream: AsyncSequence, Sendable {
    typealias Element = GatewayEventDelivery

    fileprivate let hub: GatewayEventHub

    struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate let hub: GatewayEventHub

        mutating func next() async -> GatewayEventDelivery? {
            await hub.next()
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(hub: hub)
    }

}

enum GatewayResponseDecoding {
    private static let maximumMethodCharacters = 160
    private static let maximumPathCharacters = 512
    private static let maximumPathComponents = 64

    static func decode<Response: Decodable>(
        _ value: JSONValue,
        as responseType: Response.Type,
        method: String
    ) throws -> Response {
        do {
            return try value.decode(responseType)
        } catch let error as DecodingError {
            throw failure(method: method, error: error)
        }
    }

    static func failure(method: String, error: DecodingError) -> GatewayFailure {
        let diagnosis: (category: String, summary: String, path: [CodingKey])
        switch error {
        case .keyNotFound(let key, let context):
            diagnosis = ("missing_required_data", "is missing required data", context.codingPath + [key])
        case .valueNotFound(_, let context):
            diagnosis = ("missing_value", "contains a missing value", context.codingPath)
        case .typeMismatch(_, let context):
            diagnosis = ("type_mismatch", "contains data of the wrong type", context.codingPath)
        case .dataCorrupted(let context):
            diagnosis = ("invalid_data", "contains invalid data", context.codingPath)
        @unknown default:
            diagnosis = ("invalid_data", "contains invalid data", [])
        }
        let admittedMethod = String(method.prefix(maximumMethodCharacters))
        let path = admittedPath(diagnosis.path)
        let message = "The Gateway response for \(admittedMethod) \(diagnosis.summary) at \(path). Try again; if it continues, tap View Logs for details and update Tron on iPhone and the Gateway together."
        return GatewayFailure(
            code: "invalid_response",
            message: message,
            retryable: false,
            details: .object([
                "method": .string(admittedMethod),
                "category": .string(diagnosis.category),
                "codingPath": .string(path),
            ])
        )
    }

    private static func admittedPath(_ codingPath: [CodingKey]) -> String {
        let components = codingPath.prefix(maximumPathComponents).map { key -> String in
            if let index = key.intValue { return "[\(index)]" }
            // Synthesized model CodingKeys are source-owned schema names.
            // Dictionary keys are response-owned data and may contain session
            // IDs, provider values, or secrets, so never retain them in Logs.
            guard String(reflecting: type(of: key)).hasSuffix(".CodingKeys") else {
                return "<redacted>"
            }
            let admitted = key.stringValue.unicodeScalars.map { scalar -> Character in
                CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
                    ? Character(String(scalar)) : "?"
            }
            return String(admitted.prefix(64))
        }
        let joined = components.reduce(into: "") { result, component in
            if component.hasPrefix("[") { result += component }
            else { result += result.isEmpty ? component : ".\(component)" }
        }
        return String((joined.isEmpty ? "response" : joined).prefix(maximumPathCharacters))
    }
}

actor GatewayClient {
    #if HOSTED_TEST
    // A run-local gate exercises the real actor-hop race without production hooks.
    @TaskLocal static var hostedEventAdmissionGate: (@Sendable () async -> (@Sendable (GatewayEventAdmission) -> Void))?
    #endif

    private struct PendingRequest {
        let continuation: CheckedContinuation<JSONValue, Error>
        let method: String
        let requestID: String
        let startedAt: ContinuousClock.Instant
        let profileID: String?
        let profileLabel: String?
        let connectionID: Int
        let diagnosticPurpose: String?
        let diagnosticPage: Int?
        let timeout: Task<Void, Never>
        var send: Task<Void, Never>?
        var transmission: GatewayRequestTransmissionState
    }

    private struct ConnectionEpoch {
        let id: Int
        let socket: any GatewaySocketConnection
        let startedAt: ContinuousClock.Instant
        let attemptID: String?
        let profileID: String
        let profileLabel: String
        var receiveTask: Task<Void, Never>?
        var livenessTask: Task<Void, Never>?
        var eventsActivated = false
        var pending: [String: PendingRequest] = [:]
        var lastInboundAt: ContinuousClock.Instant?
        var lastWriteProgressAt: ContinuousClock.Instant?
        var overflowResyncSignaled = false
        var info: GatewayInfo?
    }

    nonisolated let events: GatewayEventStream
    private let eventHub: GatewayEventHub
    private let socketFactory: GatewaySocketFactory
    private let clock: MonotonicClock
    /// Current network interfaces for connection records only.
    private let networkPath: @Sendable () -> String?
    private let uuidSource: UUIDSource
    private let frameDecoder: GatewayFrameDecoder
    private let boundedHTTPDataTransport: BoundedHTTPDataTransport
    private let liveViewTransport: BoundedHTTPDataTransport
    private let boundedHTTPUploadTransport: BoundedHTTPUploadTransport
    private let boundedHTTPFileTransport: BoundedHTTPFileTransport
    private let performanceSignposts: any PerformanceSignposting
    private var connection: ConnectionEpoch?
    private var connectionDiagnostics: [GatewayConnectionDiagnostic] = []
    private var latestSessionListRequestID: String?
    private var diagnosticSequence = 0
    private var firstDiagnosticSequenceByEpisode: [String: Int] = [:]
    private let diagnosticStore: IOSClientDiagnosticStore?
    private var diagnosticCaptureSink: (any DiagnosticCaptureRPCSink)?
    nonisolated let diagnosticOwnerID = UUID().uuidString
    private var generation = 0
    private var profile: GatewayProfile?
    private var token: String?

    var info: GatewayInfo? { connection?.info }

    func activeConnectionID() -> Int? { connection?.id }

    func activeConnectionAdmission() -> GatewayConnectionAdmission {
        GatewayConnectionAdmission(connectionID: connection?.id)
    }

    func diagnostics() -> [GatewayConnectionDiagnostic] { connectionDiagnostics }

    /// Installs the opt-in capture sink before normal app work starts. A nil
    /// sink is the cheap production path and retains no request observations.
    func installDiagnosticCaptureSink(_ sink: (any DiagnosticCaptureRPCSink)?) {
        diagnosticCaptureSink = sink
    }

    /// Joins projection-level catalog records to the request diagnostic already
    /// owned by this actor without copying request lifecycle state into AppModel.
    func sessionListRequestID() -> String? { latestSessionListRequestID }

    private func recordRPCDiagnostic(
        request: PendingRequest,
        outcome: GatewayRPCDiagnosticOutcome,
        error: Error? = nil
    ) {
        let duration = diagnosticMilliseconds(request.startedAt.duration(to: clock.now()))
        let code = error.map(Self.diagnosticCode)
        if diagnosticCaptureSink?.isCapturing == true {
            diagnosticCaptureSink?.recordRPC(
                method: request.method,
                requestID: request.requestID,
                requestStartedAt: request.startedAt,
                outcome: outcome.rawValue,
                code: code,
                durationMilliseconds: duration,
                profileID: request.profileID,
                connectionID: request.connectionID,
                purpose: request.diagnosticPurpose,
                page: request.diagnosticPage
            )
        }
        let incidentID = outcome == .success ? nil : "rpc:\(request.requestID)"
        guard request.method == "session.list" else { return }
        diagnosticStore?.record(IOSClientDiagnosticBuffer.logRecord(GatewayRPCDiagnostic(
            method: request.method,
            requestID: request.requestID,
            outcome: outcome,
            code: code,
            durationMilliseconds: duration,
            timestamp: GatewayTimestamp.preciseString(from: .now),
            profileID: request.profileID,
            profileLabel: request.profileLabel,
            incidentID: incidentID
        )))
    }

    private static func diagnosticCode(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let failure = error as? GatewayFailure {
            return GatewayDiagnosticFailure.normalizedCode(failure.code)
        }
        // Local send-state wrappers retain the actual bounded failure code.
        // Treating them as an untyped transport error loses request-timeout
        // evidence and makes catalog failures appear application-originated.
        if let failure = (error as? GatewayDefinitelyNotSentError)?.failure
            ?? (error as? GatewayPossiblySentError)?.failure {
            return GatewayDiagnosticFailure.normalizedCode(failure.code)
        }
        return "transport"
    }

    private func recordDiagnostic(
        stage: GatewayConnectionDiagnosticStage,
        outcome: GatewayConnectionDiagnosticOutcome,
        startedAt: ContinuousClock.Instant,
        reason: GatewayConnectionDiagnosticReason? = nil,
        error: Error? = nil,
        platformCode: Int? = nil,
        closeCode: Int? = nil,
        httpStatusCode: Int? = nil,
        connectionID: Int? = nil,
        overflowCount: Int? = nil,
        overflowReason: GatewayEventAdmissionReason? = nil,
        rejectedTopic: String? = nil,
        overflowBytes: Int? = nil,
        queueSnapshot: GatewayEventHubSnapshot? = nil,
        lastInboundAgeMilliseconds: Int? = nil,
        lastWriteProgressAgeMilliseconds: Int? = nil,
        profileID: String? = nil,
        profileLabel: String? = nil,
        attemptID: String? = nil,
        frameBytes: Int? = nil,
        decodeLimitKind: JSONValueDecodingLimitKind? = nil,
        decodeActual: Int? = nil,
        decodeMaximum: Int? = nil,
        decodeCodingPath: String? = nil,
        handshake: GatewayHandshakeDiagnostic? = nil
    ) {
        let components = startedAt.duration(to: clock.now()).components
        let elapsed = max(
            Int64(0),
            components.seconds * 1_000
                + components.attoseconds / 1_000_000_000_000_000
        )
        let resolvedPlatformCode = platformCode ?? error.flatMap(Self.platformErrorCode)
        diagnosticSequence &+= 1
        let diagnostic = GatewayConnectionDiagnostic(
            sequence: diagnosticSequence,
            clientID: diagnosticOwnerID,
            attemptID: attemptID ?? (connectionID == connection?.id ? connection?.attemptID : nil),
            connectionID: connectionID,
            timestamp: GatewayTimestamp.preciseString(from: .now),
            profileID: profileID ?? self.profile?.id,
            profileLabel: profileLabel ?? self.profile?.label,
            stage: stage,
            outcome: outcome,
            durationMilliseconds: Int(elapsed),
            reason: reason,
            platformCode: resolvedPlatformCode,
            closeCode: closeCode,
            httpStatusCode: httpStatusCode,
            overflowCount: overflowCount,
            overflowReason: overflowReason,
            rejectedTopic: rejectedTopic,
            overflowBytes: overflowBytes,
            queueBytes: queueSnapshot?.bufferedBytes,
            queueMaximumEvents: queueSnapshot?.maximumEvents,
            queueMaximumBytes: queueSnapshot?.maximumBytes,
            queueOldestAgeMilliseconds: queueSnapshot?.oldestQueuedAgeMilliseconds,
            queueTimeSinceLastDequeueMilliseconds: queueSnapshot?.timeSinceLastDequeueMilliseconds,
            queueCountHighWaterMark: queueSnapshot?.countHighWaterMark,
            queueByteHighWaterMark: queueSnapshot?.byteHighWaterMark,
            admittedEventCount: queueSnapshot?.admittedCount,
            dequeuedEventCount: queueSnapshot?.dequeuedCount,
            pressureCrossings: queueSnapshot?.pressureCrossings,
            pressureLevels: queueSnapshot?.pressureLevels,
            dequeueWaitAgeMilliseconds: queueSnapshot?.dequeueWaitAgeMilliseconds,
            dequeueWaitTopic: queueSnapshot?.dequeueWaitTopic,
            dequeueWaitConnectionID: queueSnapshot?.dequeueWaitConnectionID,
            lastInboundAgeMilliseconds: lastInboundAgeMilliseconds,
            lastWriteProgressAgeMilliseconds: lastWriteProgressAgeMilliseconds,
            frameBytes: frameBytes,
            decodeLimitKind: decodeLimitKind,
            decodeActual: decodeActual,
            decodeMaximum: decodeMaximum,
            decodeCodingPath: decodeCodingPath,
            handshake: handshake
        )
        connectionDiagnostics.insert(diagnostic, at: 0)
        if diagnostic.outcome == .failure {
            let episode = diagnostic.attemptID ?? diagnostic.connectionID.map(String.init) ?? "client"
            if firstDiagnosticSequenceByEpisode[episode] == nil {
                firstDiagnosticSequenceByEpisode[episode] = diagnostic.sequence
            }
        }
        while connectionDiagnostics.count > 200 {
            if let removable = connectionDiagnostics.lastIndex(where: { diagnostic in
                let episode = diagnostic.attemptID ?? diagnostic.connectionID.map(String.init) ?? "client"
                return firstDiagnosticSequenceByEpisode[episode] != diagnostic.sequence
            }) {
                connectionDiagnostics.remove(at: removable)
            } else {
                connectionDiagnostics.removeLast()
            }
        }
        firstDiagnosticSequenceByEpisode = firstDiagnosticSequenceByEpisode.filter { _, sequence in
            connectionDiagnostics.contains { $0.sequence == sequence }
        }
        diagnosticStore?.record(IOSClientDiagnosticBuffer.logRecord(diagnostic))
    }

    init(
        socketFactory: GatewaySocketFactory = .urlSession,
        clock: MonotonicClock = .continuous,
        uuidSource: UUIDSource = .random,
        frameDecoder: GatewayFrameDecoder = .gateway,
        boundedHTTPDataTransport: BoundedHTTPDataTransport = .urlSession,
        liveViewTransport: BoundedHTTPDataTransport = .noRedirects,
        boundedHTTPUploadTransport: BoundedHTTPUploadTransport = .urlSession,
        boundedHTTPFileTransport: BoundedHTTPFileTransport = .urlSession,
        performanceSignposts: any PerformanceSignposting = SystemPerformanceSignposts.shared,
        eventBufferPolicy: GatewayEventBufferPolicy = .default,
        diagnosticStore: IOSClientDiagnosticStore? = nil,
        diagnosticCaptureSink: (any DiagnosticCaptureRPCSink)? = nil,
        networkPath: @escaping @Sendable () -> String? = { GatewayNetworkPathSnapshot.shared.current }
    ) {
        self.networkPath = networkPath
        self.diagnosticStore = diagnosticStore
        self.socketFactory = socketFactory
        self.clock = clock
        self.uuidSource = uuidSource
        self.frameDecoder = frameDecoder
        self.boundedHTTPDataTransport = boundedHTTPDataTransport
        self.liveViewTransport = liveViewTransport
        self.boundedHTTPUploadTransport = boundedHTTPUploadTransport
        self.boundedHTTPFileTransport = boundedHTTPFileTransport
        self.performanceSignposts = performanceSignposts
        self.diagnosticCaptureSink = diagnosticCaptureSink
        let eventHub = GatewayEventHub(policy: eventBufferPolicy, clock: clock)
        self.eventHub = eventHub
        events = GatewayEventStream(hub: eventHub)
    }

    deinit {
        let eventHub = self.eventHub
        Task { await eventHub.finish() }
        connection?.receiveTask?.cancel()
        connection?.livenessTask?.cancel()
        if let socket = connection?.socket {
            Task { await socket.close() }
        }
    }

    func connect(profile: GatewayProfile, token: String) async throws -> GatewayInfo {
        try await establish(profile: profile, token: token, activateEvents: true, isReconnect: false).info
    }

    func connectForLifecycle(profile: GatewayProfile, token: String) async throws -> GatewayConnectionIdentity {
        try await establish(profile: profile, token: token, activateEvents: false, isReconnect: false)
    }

    private func establish(
        profile: GatewayProfile,
        token: String,
        activateEvents: Bool,
        isReconnect: Bool = false,
        attemptID: String? = nil
    ) async throws -> GatewayConnectionIdentity {
        let interval = performanceSignposts.begin(.gatewayConnect)
        do {
            let identity = try await establishConnection(
                profile: profile,
                token: token,
                activateEvents: activateEvents,
                isReconnect: isReconnect,
                attemptID: attemptID
            )
            performanceSignposts.end(interval, result: .success, metrics: .none)
            return identity
        } catch {
            let result = PerformanceResult.forFailure(error)
            performanceSignposts.end(interval, result: result, metrics: .none)
            throw error
        }
    }

    private func establishConnection(
        profile: GatewayProfile,
        token: String,
        activateEvents: Bool,
        isReconnect: Bool,
        attemptID: String? = nil
    ) async throws -> GatewayConnectionIdentity {
        generation &+= 1
        let epochID = generation
        let retiredConnectionID = connection?.id
        await detachConnection(
            reason: GatewayFailure(code: "replaced", message: "Connection replaced", retryable: true, details: nil)
        )
        if let retiredConnectionID {
            // Remove predecessor deliveries even when a successor connected
            // while its close was suspended; reset preserves successor evidence.
            await eventHub.reset(connectionID: retiredConnectionID)
        }
        try Task.checkCancellation()
        guard generation == epochID else { throw CancellationError() }

        guard let socketURL = profile.socketURL else { throw Self.invalidProfileEndpoint() }
        self.profile = profile
        self.token = token
        let handshakeTimeout = GatewayConnectionPolicy.handshakeDeadline
        let attemptStartedAt = clock.now()
        let handshakeStage = GatewayHandshakeStage()
        // One deadline covers hello send and receive. The URL loading inactivity
        // timeout stays above the application-owned liveness decision.
        var request = URLRequest(url: socketURL, timeoutInterval: GatewayConnectionPolicy.requestInactivityTimeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = socketFactory.makeConnection(request)
        connection = ConnectionEpoch(
            id: epochID, socket: socket, startedAt: attemptStartedAt,
            attemptID: attemptID, profileID: profile.id, profileLabel: profile.label
        )

        do {
            let hello: JSONValue = .object([
                "type": .string("hello"),
                "protocolVersion": .number(Double(TronGatewayProtocolContract.protocolVersion)),
                "clientId": .string(uuidSource.next().uuidString),
                "clientRole": .string("mobile"),
            ])
            let helloData = try JSONEncoder.gateway.encode(hello)
            let data = try await Self.withTimeout(clock: clock, duration: handshakeTimeout, onTimeout: { await socket.close() }) {
                handshakeStage.set(.helloSend)
                try await socket.send(helloData)
                await self.markWriteProgress(epochID: epochID)
                try await self.requireEpoch(epochID)
                handshakeStage.set(.helloReceive)
                return try await socket.receive()
            }
            try requireEpoch(epochID)
            try GatewayFramePolicy.validateInboundBytes(data)
            let decoded = try JSONDecoder.gateway.decode(GatewayHello.self, from: data)
            try requireEpoch(epochID)
            guard decoded.type == "hello",
                  decoded.protocolVersion == TronGatewayProtocolContract.protocolVersion,
                  decoded.minProtocolVersion == TronGatewayProtocolContract.minimumProtocolVersion else {
                throw GatewayFailure(code: "protocol_mismatch", message: "The Mac gateway protocol is not compatible with this app.", retryable: false, details: nil)
            }
            let admittedChannel = try GatewayChannelPolicy.admit(decoded.gatewayChannel)
            guard admittedChannel == profile.gatewayChannel else {
                throw GatewayFailure(
                    code: "identity_mismatch",
                    message: "The connected Gateway channel does not match this paired server.",
                    retryable: false,
                    details: nil
                )
            }
            guard var epoch = connection, epoch.id == epochID else { throw CancellationError() }
            epoch.info = decoded.info
            epoch.lastInboundAt = clock.now()
            connection = epoch
            if activateEvents { try activateEventDelivery(connectionID: epochID) }
            // No socket metadata read here: an extra await on the success path
            // would let a slow or retired socket delay admission. A completed
            // hello already proves the transport opened.
            recordDiagnostic(
                stage: .helloReceive,
                outcome: .success,
                startedAt: attemptStartedAt,
                connectionID: epochID,
                profileID: profile.id,
                profileLabel: profile.label,
                attemptID: attemptID,
                handshake: handshakeDiagnostic(
                    metadata: GatewaySocketMetadata(closeCode: nil, httpStatusCode: nil),
                    reachedHelloReceive: true
                )
            )
            return GatewayConnectionIdentity(id: epochID, info: decoded.info)
        } catch {
            let metadata = await socket.metadata()
            let upgradeFailure = Self.upgradeFailure(error, metadata: metadata)
            let failure = upgradeFailure ?? Self.transportFailure(error)
            let reachedStage = handshakeStage.get()
            let handshake = handshakeDiagnostic(metadata: metadata, reachedHelloReceive: reachedStage == .helloReceive)
            recordDiagnostic(
                // A hello write that never completed on a socket that never
                // opened is a path failure, not a Mac that did not answer.
                stage: reachedStage == .helloSend && !handshake.transportOpened ? .transportOpen : reachedStage,
                outcome: .failure,
                startedAt: attemptStartedAt,
                reason: Self.diagnosticReason(for: failure.code),
                error: error,
                closeCode: metadata.closeCode,
                httpStatusCode: metadata.httpStatusCode,
                connectionID: epochID,
                profileID: profile.id,
                profileLabel: profile.label,
                attemptID: attemptID,
                handshake: handshake
            )
            await detachConnection(epochID: epochID, reason: failure)
            if let upgradeFailure { throw upgradeFailure }
            throw error
        }
    }

    private func handshakeDiagnostic(metadata: GatewaySocketMetadata, reachedHelloReceive: Bool) -> GatewayHandshakeDiagnostic {
        GatewayHandshakeDiagnostic(
            transportOpened: metadata.transportOpenMilliseconds != nil || reachedHelloReceive,
            transportOpenMilliseconds: metadata.transportOpenMilliseconds,
            waitedForConnectivity: metadata.waitedForConnectivity,
            networkInterfaces: networkPath()
        )
    }

    func reconnect() async throws -> GatewayInfo {
        guard let profile, let token else {
            throw GatewayFailure(code: "not_paired", message: "No paired gateway is selected.", retryable: false, details: nil)
        }
        return try await reconnectForLifecycle(profile: profile, token: token, activateEvents: true).info
    }

    func reconnectForLifecycle(
        profile: GatewayProfile,
        token: String,
        activateEvents: Bool = false,
        attemptID: String? = nil
    ) async throws -> GatewayConnectionIdentity {
        try await establish(
            profile: profile,
            token: token,
            activateEvents: activateEvents,
            isReconnect: true,
            attemptID: attemptID
        )
    }

    func activateEvents(connectionID: Int) throws {
        try activateEventDelivery(connectionID: connectionID)
    }

    private func activateEventDelivery(connectionID: Int) throws {
        try requireEpoch(connectionID)
        guard var epoch = connection, epoch.id == connectionID,
              !epoch.eventsActivated else { return }
        epoch.eventsActivated = true
        connection = epoch
        startReceive(epochID: connectionID)
        startLivenessWait(epochID: connectionID)
    }

    /// Retires only the transport epoch while preserving the selected profile
    /// credentials for the next foreground reconnect. Background suspension is
    /// an intentional transport boundary, not a live subscription interval.
    func retireForBackground() async {
        generation &+= 1
        let retiredConnectionID = connection?.id
        await detachConnection(
            reason: GatewayFailure(code: "backgrounded", message: "Connection retired while the app was backgrounded.", retryable: true, details: nil)
        )
        if let retiredConnectionID { await eventHub.reset(connectionID: retiredConnectionID) }
    }

    func closeIfCurrent(connectionID: Int) async {
        guard connection?.id == connectionID else { return }
        generation &+= 1
        await detachConnection(
            epochID: connectionID,
            reason: GatewayFailure(code: "retired", message: "Connection ownership was retired.", retryable: true, details: nil)
        )
        await eventHub.reset(connectionID: connectionID)
    }

    func close() async {
        generation &+= 1
        // Revoke credentials before suspension: an older close must never
        // erase the profile installed by a concurrent replacement connection.
        profile = nil
        token = nil
        let retiredConnectionID = connection?.id
        await detachConnection(
            reason: GatewayFailure(code: "closed", message: "Connection closed", retryable: true, details: nil)
        )
        if let retiredConnectionID { await eventHub.reset(connectionID: retiredConnectionID) }
    }

    func ensureResponsive(maximumSilence: Duration = .seconds(35)) async throws {
        guard let epoch = connection, let lastInboundAt = epoch.lastInboundAt else {
            throw GatewayFailure(code: "disconnected", message: "The Mac gateway is offline.", retryable: true, details: nil)
        }
        if clock.now() - lastInboundAt <= maximumSilence { return }
        struct Response: Decodable { let protocolVersion: Int }
        let _: Response = try await request(
            "system.info",
            EmptyParams(),
            expectedEpochID: epoch.id
        )
    }

    func request<P: Encodable, R: Decodable>(
        _ method: String,
        _ params: P,
        as responseType: R.Type = R.self,
        timeout: Duration = .seconds(30),
        diagnosticPurpose: String? = nil,
        diagnosticPage: Int? = nil
    ) async throws -> R {
        let value = try await requestValue(
            method, params, timeout: timeout,
            diagnosticPurpose: diagnosticPurpose, diagnosticPage: diagnosticPage
        )
        return try GatewayResponseDecoding.decode(value, as: responseType, method: method)
    }

    func requestValue<P: Encodable>(
        _ method: String,
        _ params: P,
        timeout: Duration = .seconds(30),
        diagnosticPurpose: String? = nil,
        diagnosticPage: Int? = nil
    ) async throws -> JSONValue {
        try await requestValue(
            method,
            params,
            timeout: timeout,
            epochExpectation: .current,
            diagnosticPurpose: diagnosticPurpose,
            diagnosticPage: diagnosticPage
        )
    }

    func request<P: Encodable, R: Decodable>(
        _ method: String,
        _ params: P,
        as responseType: R.Type = R.self,
        timeout: Duration = .seconds(30),
        expectedEpochID: Int,
        diagnosticPurpose: String? = nil,
        diagnosticPage: Int? = nil
    ) async throws -> R {
        let value = try await requestValue(
            method,
            params,
            timeout: timeout,
            expectedEpochID: expectedEpochID,
            diagnosticPurpose: diagnosticPurpose,
            diagnosticPage: diagnosticPage
        )
        return try GatewayResponseDecoding.decode(value, as: responseType, method: method)
    }

    func request<P: Encodable, R: Decodable>(
        _ method: String,
        _ params: P,
        as responseType: R.Type = R.self,
        timeout: Duration = .seconds(30),
        expectedConnection: GatewayConnectionAdmission
    ) async throws -> R {
        let value = try await requestValue(
            method,
            params,
            timeout: timeout,
            expectedConnection: expectedConnection
        )
        return try GatewayResponseDecoding.decode(value, as: responseType, method: method)
    }

    func requestValue<P: Encodable>(
        _ method: String,
        _ params: P,
        timeout: Duration = .seconds(30),
        expectedEpochID: Int,
        diagnosticPurpose: String? = nil,
        diagnosticPage: Int? = nil
    ) async throws -> JSONValue {
        try await requestValue(
            method,
            params,
            timeout: timeout,
            epochExpectation: .id(expectedEpochID),
            diagnosticPurpose: diagnosticPurpose,
            diagnosticPage: diagnosticPage
        )
    }

    func requestValue<P: Encodable>(
        _ method: String,
        _ params: P,
        timeout: Duration = .seconds(30),
        expectedConnection: GatewayConnectionAdmission
    ) async throws -> JSONValue {
        try await requestValue(
            method,
            params,
            timeout: timeout,
            epochExpectation: .admission(expectedConnection)
        )
    }

    private enum EpochExpectation {
        case current
        case id(Int)
        case admission(GatewayConnectionAdmission)
    }

    private func requestValue<P: Encodable>(
        _ method: String,
        _ params: P,
        timeout: Duration,
        epochExpectation: EpochExpectation,
        diagnosticPurpose: String? = nil,
        diagnosticPage: Int? = nil
    ) async throws -> JSONValue {
        guard let epoch = connection, epoch.info != nil, epoch.eventsActivated else {
            throw Self.definitelyNotSentFailure()
        }
        switch epochExpectation {
        case .current:
            break
        case .id(let expectedEpochID):
            guard expectedEpochID == epoch.id else { throw Self.definitelyNotSentFailure() }
        case .admission(let expectedConnection):
            guard expectedConnection.connectionID == epoch.id else {
                throw Self.definitelyNotSentFailure()
            }
        }
        let epochID = epoch.id
        let socket = epoch.socket
        let id = uuidSource.next().uuidString
        if method == "session.list" { latestSessionListRequestID = id }
        let frame = GatewayRequest(id: id, method: method, params: try JSONValue.encode(params))
        let data = try JSONEncoder.gateway.encode(frame)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard var current = connection, current.id == epochID else {
                    continuation.resume(throwing: Self.definitelyNotSentFailure(
                        code: "replaced",
                        message: "Connection replaced"
                    ))
                    return
                }
                let clock = self.clock
                let timeoutTask = Task { [weak self] in
                    try? await clock.sleep(timeout)
                    guard !Task.isCancelled else { return }
                    await self?.expire(id: id, epochID: epochID)
                }
                current.pending[id] = PendingRequest(
                    continuation: continuation,
                    method: method,
                    requestID: id,
                    startedAt: clock.now(),
                    profileID: current.profileID,
                    profileLabel: current.profileLabel,
                    connectionID: epochID,
                    diagnosticPurpose: diagnosticPurpose,
                    diagnosticPage: diagnosticPage,
                    timeout: timeoutTask,
                    send: nil,
                    transmission: .queued
                )
                connection = current
                let sendTask = Task { [weak self, socket] in
                    guard await self?.claimSend(id: id, epochID: epochID) == true else { return }
                    let result: Result<Void, Error>
                    do {
                        try await socket.send(data)
                        result = .success(())
                    } catch {
                        result = .failure(error)
                    }
                    await self?.sendCompleted(result, id: id, epochID: epochID)
                }
                guard var installedEpoch = connection,
                      installedEpoch.id == epochID,
                      var installedRequest = installedEpoch.pending[id] else {
                    sendTask.cancel()
                    return
                }
                installedRequest.send = sendTask
                installedEpoch.pending[id] = installedRequest
                connection = installedEpoch
            }
        } onCancel: {
            Task { await self.cancelRequest(id: id, epochID: epochID) }
        }
    }

    private func markWriteProgress(epochID: Int) {
        guard var epoch = connection, epoch.id == epochID else { return }
        epoch.lastWriteProgressAt = clock.now()
        connection = epoch
    }

    private func claimSend(id: String, epochID: Int) -> Bool {
        guard var epoch = connection, epoch.id == epochID,
              var request = epoch.pending[id], request.transmission == .queued else { return false }
        request.transmission = .sending
        epoch.pending[id] = request
        connection = epoch
        return true
    }

    private func sendCompleted(
        _ result: Result<Void, Error>,
        id: String,
        epochID: Int
    ) async {
        guard var epoch = connection, epoch.id == epochID,
              var request = epoch.pending[id] else { return }
        switch result {
        case .success:
            request.transmission = .sent
            epoch.lastWriteProgressAt = clock.now()
            epoch.pending[id] = request
            connection = epoch
        case .failure(let error):
            let failure = Self.possiblySentFailure(cause: error)
            fail(id: id, epochID: epochID, error: failure)
            // A genuine current-epoch write failure is stronger than an RPC
            // timeout: retire exactly this socket, while the request remains
            // classified as possibly sent for command-ID reconciliation.
            await disconnectEpoch(
                epochID: epochID,
                failure: GatewayFailure(
                    code: "transport_send_failed",
                    message: "The Mac gateway connection could not send data.",
                    retryable: true,
                    details: Self.transportFailure(error).details
                )
            )
        }
    }

    func upload(name: String, mimeType: String, data: Data) async throws -> String {
        try requireUploadSize(data.count)
        let context = try uploadContext(name: name, mimeType: mimeType)
        var request = context.request
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        request.httpBody = data
        let (responseData, http) = try await boundedHTTPDataTransport.data(
            for: request,
            maximumBytes: GatewayUploadPolicy.maximumResponseBytes
        )
        // The upload is an independently staged HTTP resource. A WebSocket
        // reconnect while the bytes are in flight must not discard a
        // successful photo upload or turn it into a misleading failure.
        return try admitUploadResponse(responseData, http: http, context: context)
    }

    func discardUpload(_ id: String) async throws {
        guard UUID(uuidString: id) != nil else {
            throw GatewayFailure(
                code: "invalid_request",
                message: "Attachment staging identity is invalid.",
                retryable: false,
                details: nil
            )
        }
        guard let profile, let token else {
            throw GatewayFailure(
                code: "not_paired",
                message: "No paired gateway is selected.",
                retryable: false,
                details: nil
            )
        }
        guard let url = profile.httpURL(path: "/v1/uploads/\(id)") else {
            throw Self.invalidProfileEndpoint()
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, http) = try await boundedHTTPDataTransport.data(
            for: request,
            maximumBytes: GatewayUploadPolicy.maximumResponseBytes
        )
        guard self.profile?.id == profile.id else { throw CancellationError() }
        guard http.statusCode != 204, http.statusCode != 404 else { return }
        struct FailureEnvelope: Decodable { let error: GatewayFailure }
        if let failure = try? JSONDecoder.gateway.decode(FailureEnvelope.self, from: data).error {
            throw failure
        }
        throw GatewayFailure(
            code: "upload_failed",
            message: "Attachment staging could not be discarded (HTTP \(http.statusCode)).",
            retryable: http.statusCode == 408 || http.statusCode == 429 || http.statusCode >= 500,
            details: nil
        )
    }

    func upload(
        name: String,
        mimeType: String,
        fileURL: URL,
        byteCount: Int
    ) async throws -> String {
        try requireUploadSize(byteCount)
        let context = try uploadContext(name: name, mimeType: mimeType)
        var request = context.request
        request.setValue(String(byteCount), forHTTPHeaderField: "Content-Length")
        let (responseData, http) = try await boundedHTTPUploadTransport.data(
            for: request,
            fileURL: fileURL,
            maximumBytes: GatewayUploadPolicy.maximumResponseBytes
        )
        return try admitUploadResponse(responseData, http: http, context: context)
    }

    private struct UploadContext {
        let profileID: String
        let request: URLRequest
    }

    private func uploadContext(name: String, mimeType: String) throws -> UploadContext {
        // Upload staging is an authenticated HTTP operation owned by the paired
        // profile, not by a disposable WebSocket epoch. A brief socket
        // reconnect must not prevent selecting or staging an attachment.
        guard let profile, let token else {
            throw GatewayFailure(code: "not_paired", message: "No paired gateway is selected.", retryable: false, details: nil)
        }
        guard let url = profile.httpURL(
            path: "/v1/uploads",
            queryItems: [URLQueryItem(name: "name", value: name)]
        ) else { throw Self.invalidProfileEndpoint() }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        return UploadContext(profileID: profile.id, request: request)
    }

    private func requireUploadSize(_ byteCount: Int) throws {
        guard byteCount > 0, byteCount <= GatewayUploadPolicy.maximumRequestBytes else {
            throw GatewayFailure(
                code: "upload_failed",
                message: "Attachments may contain 1 byte through 25 MiB.",
                retryable: false,
                details: nil
            )
        }
    }

    private func admitUploadResponse(
        _ data: Data,
        http: HTTPURLResponse,
        context: UploadContext
    ) throws -> String {
        guard profile?.id == context.profileID else { throw CancellationError() }
        guard http.statusCode == 201 else {
            struct FailureEnvelope: Decodable { let error: GatewayFailure }
            if let failure = try? JSONDecoder.gateway.decode(FailureEnvelope.self, from: data).error {
                throw failure
            }
            let retryable = http.statusCode == 408 || http.statusCode == 429 || http.statusCode >= 500
            throw GatewayFailure(
                code: "upload_failed",
                message: "Attachment upload failed (HTTP \(http.statusCode)).",
                retryable: retryable,
                details: nil
            )
        }
        struct Envelope: Decodable { struct Upload: Decodable { let id: String }; let upload: Upload }
        do {
            let id = try JSONDecoder.gateway.decode(Envelope.self, from: data).upload.id
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Upload response did not contain an ID")) }
            return id
        } catch {
            throw GatewayFailure(code: "upload_failed", message: "The Gateway returned an invalid attachment response.", retryable: true, details: nil)
        }
    }

    func blob(
        id: String,
        sessionID: String? = nil,
        profileID: String,
        maximumBytes: Int
    ) async throws -> (Data, String) {
        // Transcript blobs remain profile-owned across disposable WebSocket
        // epochs. This keeps thumbnails and an open preview stable while the
        // event channel reconnects and rebaselines.
        guard let profile, profile.id == profileID, let token else {
            throw CancellationError()
        }
        let value = try await boundedBlob(
            id: id,
            sessionID: sessionID,
            profile: profile,
            token: token,
            maximumBytes: maximumBytes
        )
        guard self.profile?.id == profileID else { throw CancellationError() }
        return value
    }

    func openLiveView(
        kind: DisplayKind,
        viewId: String,
        generation: String,
        sessionID: String,
        profileID: String
    ) async throws -> LiveLease {
        guard let capability = kind.liveViewCapability,
              info?.capabilities.contains(capability) == true else { throw LiveError.ended }
        guard let profile, profile.id == profileID, let token,
              let url = Self.liveViewPath(viewId: viewId, sessionID: sessionID).flatMap({ profile.httpURL(path: $0) }) else { throw CancellationError() }
        try Task.checkCancellation()
        let connectionID = connection?.id
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body = try JSONEncoder.gateway.encode(["generation": generation])
        request.httpBody = body
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, http) = try await liveViewTransport.data(for: request, maximumBytes: 64 * 1_024)
        guard http.url == url else { throw LiveError.invalidResponse }
        guard http.statusCode == 200 else { throw LiveError.response(data, status: http.statusCode) }
        let wire = try JSONDecoder.gateway.decode(LiveLease.Wire.self, from: data)
        let lease = try LiveLease(wire: wire, request: request, transport: liveViewTransport)
        // A valid lease from the wrong producer is never a browser/native alias.
        // It still owns cancellation-independent cleanup at the original origin.
        guard wire.descriptor.schema == kind.liveViewSchema,
              wire.descriptor.viewId == viewId, wire.descriptor.generation == generation else {
            await lease.close()
            throw LiveError.invalidResponse
        }
        guard !Task.isCancelled, self.profile?.id == profileID, connection?.id == connectionID else {
            await lease.close()
            throw CancellationError()
        }
        return lease
    }

    func displayArtifactFile(
        id: String,
        sessionID: String,
        profileID: String,
        maximumBytes: Int,
        expectedBytes: Int64
    ) async throws -> URL {
        guard let profile, profile.id == profileID, let token else { throw CancellationError() }
        let downloaded = try await boundedBlobFile(
            id: id,
            sessionID: sessionID,
            profile: profile,
            token: token,
            maximumBytes: maximumBytes
        )
        do {
            guard downloaded.byteCount == expectedBytes else {
                throw GatewayFailure(
                    code: "blob_failed",
                    message: "The display media changed while it was downloading.",
                    retryable: true,
                    details: nil
                )
            }
            try Task.checkCancellation()
            guard self.profile?.id == profileID else { throw CancellationError() }
            return downloaded.url
        } catch {
            BoundedHTTPFileStaging.shared.discard(downloaded.url)
            throw error
        }
    }

    func blobFile(id: String, maximumBytes: Int, expectedBytes: Int64? = nil) async throws -> URL {
        guard let profile, let token, let connectionID = connection?.id else {
            throw GatewayFailure(code: "disconnected", message: "The Mac gateway is offline.", retryable: true, details: nil)
        }
        let downloaded = try await boundedBlobFile(
            id: id,
            profile: profile,
            token: token,
            maximumBytes: maximumBytes
        )
        do {
            if let expectedBytes, downloaded.byteCount != expectedBytes {
                throw GatewayFailure(
                    code: "blob_failed",
                    message: "The export size changed while it was downloading. Try exporting again.",
                    retryable: true,
                    details: nil
                )
            }
            try requireEpoch(connectionID)
            guard self.profile?.id == profile.id else { throw CancellationError() }
            return downloaded.url
        } catch {
            BoundedHTTPFileStaging.shared.discard(downloaded.url)
            throw error
        }
    }

    private func boundedBlob(
        id: String,
        sessionID: String? = nil,
        profile: GatewayProfile,
        token: String,
        maximumBytes: Int
    ) async throws -> (Data, String) {
        guard let url = mediaURL(id: id, sessionID: sessionID, profile: profile) else {
            throw Self.invalidProfileEndpoint()
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, http) = try await boundedHTTPDataTransport.data(
            for: request,
            maximumBytes: maximumBytes
        )
        guard http.statusCode == 200 else {
            throw GatewayFailure(code: "blob_failed", message: "The image is no longer available. Refresh the session.", retryable: true, details: nil)
        }
        return (data, http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream")
    }

    private func boundedBlobFile(
        id: String,
        sessionID: String? = nil,
        profile: GatewayProfile,
        token: String,
        maximumBytes: Int
    ) async throws -> BoundedHTTPDownloadedFile {
        guard let url = mediaURL(id: id, sessionID: sessionID, profile: profile) else {
            throw Self.invalidProfileEndpoint()
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let downloaded = try await boundedHTTPFileTransport.download(
            for: request,
            maximumBytes: maximumBytes
        )
        guard downloaded.response.statusCode == 200 || downloaded.response.statusCode == 206 else {
            BoundedHTTPFileStaging.shared.discard(downloaded.url)
            throw GatewayFailure(code: "blob_failed", message: "The export is no longer available. Try exporting again.", retryable: true, details: nil)
        }
        return downloaded
    }

    private func mediaURL(id: String, sessionID: String? = nil, profile: GatewayProfile) -> URL? {
        Self.mediaPath(id: id, sessionID: sessionID).flatMap { profile.httpURL(path: $0) }
    }

    nonisolated static func liveViewPath(viewId: String, sessionID: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard !viewId.isEmpty, viewId.utf8.count <= 200, !sessionID.isEmpty, sessionID.utf8.count <= 200,
              let encodedView = viewId.addingPercentEncoding(withAllowedCharacters: allowed),
              let encodedSession = sessionID.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        guard ![".", ".."].contains(viewId), ![".", ".."].contains(sessionID) else { return nil }
        return "/v1/sessions/\(encodedSession)/live-views/\(encodedView)"
    }

    nonisolated static func mediaPath(id: String, sessionID: String? = nil) -> String? {
        if let sessionID {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            guard UUID(uuidString: id) != nil,
                  !sessionID.isEmpty, sessionID.utf8.count <= 200,
                  let encodedSession = sessionID.addingPercentEncoding(withAllowedCharacters: allowed),
                  !encodedSession.isEmpty else { return nil }
            return "/v1/sessions/\(encodedSession)/display-artifacts/\(id)"
        }
        if id.hasPrefix("upload:") {
            let uploadID = String(id.dropFirst("upload:".count))
            guard UUID(uuidString: uploadID) != nil else { return nil }
            return "/v1/uploads/\(uploadID)"
        }
        return "/v1/blobs/\(id)"
    }

    private func startReceive(epochID: Int) {
        guard var epoch = connection, epoch.id == epochID,
              epoch.receiveTask == nil else { return }
        let socket = epoch.socket
        epoch.receiveTask = Task { [weak self, socket] in
            let result: Result<Data, Error>
            do { result = .success(try await socket.receive()) }
            catch { result = .failure(error) }
            await self?.receiveCompleted(result, epochID: epochID)
        }
        connection = epoch
    }

    private func receiveCompleted(_ result: Result<Data, Error>, epochID: Int) async {
        guard var completedEpoch = connection, completedEpoch.id == epochID else { return }
        completedEpoch.receiveTask = nil
        connection = completedEpoch
        switch result {
        case .success(let data):
            guard var current = connection, current.id == epochID else { return }
            current.lastInboundAt = clock.now()
            connection = current
            do {
                try await handle(data, epochID: epochID)
                if ownsEpoch(epochID) { startReceive(epochID: epochID) }
            } catch {
                await disconnectEpoch(epochID: epochID, failure: Self.transportFailure(error))
            }
        case .failure(let error):
            await disconnectEpoch(epochID: epochID, failure: Self.transportFailure(error))
        }
    }

    private func startLivenessWait(epochID: Int) {
        guard var epoch = connection, epoch.id == epochID,
              epoch.livenessTask == nil else { return }
        let clock = self.clock
        let socket = epoch.socket
        epoch.livenessTask = Task { [weak self, clock, socket] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(GatewayConnectionPolicy.clientPingInterval)
                    try Task.checkCancellation()
                } catch { return }
                let startedAt = clock.now()
                let timeout = GatewayFailure(
                    code: "pong_timeout",
                    message: "The Mac gateway did not answer its liveness probe.",
                    retryable: true,
                    details: nil
                )
                do {
                    try await GatewayClient.withTimeout(
                        clock: clock,
                        duration: GatewayConnectionPolicy.clientPongDeadline,
                        onTimeout: { [weak self] in
                            // Record and revoke at the epoch owner before close
                            // wakes the receiver with a less-specific error.
                            await self?.livenessFailed(timeout, epochID: epochID, startedAt: startedAt)
                        },
                        timeoutFailure: timeout
                    ) {
                        try await socket.ping()
                    }
                    await self?.notePong(epochID: epochID)
                } catch {
                    guard !Task.isCancelled else { return }
                    await self?.livenessFailed(error, epochID: epochID, startedAt: startedAt)
                    return
                }
            }
        }
        connection = epoch
    }

    private func notePong(epochID: Int) {
        guard var epoch = connection, epoch.id == epochID else { return }
        epoch.lastInboundAt = clock.now()
        connection = epoch
    }

    private func livenessFailed(_ error: Error, epochID: Int, startedAt: ContinuousClock.Instant) async {
        guard ownsEpoch(epochID) else { return }
        recordDiagnostic(
            stage: .liveness,
            outcome: .failure,
            startedAt: startedAt,
            reason: Self.diagnosticReason(for: Self.transportFailure(error).code),
            error: error,
            connectionID: epochID
        )
        await disconnectEpoch(epochID: epochID, failure: Self.transportFailure(error))
    }

    private func disconnectEpoch(epochID: Int, failure: GatewayFailure) async {
        let queueSnapshot = await eventHub.snapshot()
        guard await detachConnection(
            epochID: epochID,
            reason: failure,
            queueSnapshot: queueSnapshot
        ) else { return }
        await eventHub.reset(connectionID: epochID, notification: GatewayEvent(
                type: "event",
                topic: "transport.disconnected",
                sessionId: nil,
                // Only fixed reason codes cross the diagnostics/event boundary;
                // transport errors may contain URLs or other private text.
                payload: .object(["reason": .string(failure.code)]),
                admittedBytes: 256
            ))
    }

    private func handle(_ data: Data, epochID: Int) async throws {
        try requireEpoch(epochID)
        let frame: GatewayInboundFrame
        do {
            frame = try frameDecoder.decode(data)
        } catch let violation as JSONValueDecodingLimitViolation {
            // Preserve the bounded decoder cause before strict epoch retirement
            // replaces it with the generic transport close classification.
            guard let current = connection, current.id == epochID else { throw violation }
            recordDiagnostic(
                stage: .transport,
                outcome: .failure,
                startedAt: current.startedAt,
                reason: .decodeLimit,
                error: violation,
                connectionID: epochID,
                profileID: current.profileID,
                profileLabel: current.profileLabel,
                attemptID: current.attemptID,
                frameBytes: data.count,
                decodeLimitKind: violation.kind,
                decodeActual: violation.actual,
                decodeMaximum: violation.maximum,
                decodeCodingPath: violation.codingPath
            )
            throw violation
        }
        try requireEpoch(epochID)
        switch frame {
        case .response(let response):
            guard let waiter = removePending(id: response.id, epochID: epochID) else { return }
            if response.ok {
                recordRPCDiagnostic(request: waiter, outcome: .success)
                waiter.continuation.resume(returning: response.result ?? .null)
            } else {
                let error = response.error ?? GatewayFailure(
                    code: "invalid_response",
                    message: "Gateway returned an invalid error.",
                    retryable: false,
                    details: nil
                )
                recordRPCDiagnostic(
                    request: waiter,
                    outcome: error.code == "invalid_response" ? .invalidResponse : .applicationFailure,
                    error: error
                )
                waiter.continuation.resume(throwing: error)
            }
        case .event(let event):
            // GatewayEvent was prepared directly from the frame decoder's
            // original Decoder. Stamp trusted transport size without rebuilding
            // the typed payload through JSONValue.
            let admittedEvent = event.withAdmittedBytes(data.count)
            #if HOSTED_TEST
            let didAdmit = await Self.hostedEventAdmissionGate?()
            #endif
            let admission = await eventHub.admit(GatewayEventDelivery(
                connectionID: epochID,
                event: admittedEvent
            ), bytes: data.count)
            #if HOSTED_TEST
            didAdmit?(admission)
            #endif
            if admission.accepted {
                if admission.pressureChanged, let current = connection, current.id == epochID {
                    recordDiagnostic(stage: .queuePressure, outcome: .success, startedAt: current.startedAt,
                                     connectionID: epochID, queueSnapshot: admission.snapshot)
                }
                return
            }
            guard admission.reason != .retiredEpoch,
                  var current = connection,
                  current.id == epochID,
                  !current.overflowResyncSignaled else { return }
            current.overflowResyncSignaled = true
            connection = current
            recordDiagnostic(
                stage: .transport,
                outcome: .failure,
                startedAt: current.startedAt,
                reason: .eventOverflow,
                connectionID: epochID,
                overflowCount: admission.snapshot.bufferedEventCount,
                overflowReason: admission.reason,
                rejectedTopic: admission.topic,
                overflowBytes: admission.admittedBytes,
                queueSnapshot: admission.snapshot,
                profileID: current.profileID,
                profileLabel: current.profileLabel
            )
            await disconnectEpoch(
                epochID: epochID,
                failure: GatewayFailure(
                    code: "event_overflow",
                    message: "Live event buffer overflow",
                    retryable: true,
                    details: nil
                )
            )
        case .unsupported:
            break
        }
    }

    private func expire(id: String, epochID: Int) {
        guard let epoch = connection, epoch.id == epochID,
              let request = epoch.pending[id] else { return }
        let error: Error = request.transmission.mayHaveBeenSent
            ? Self.possiblySentFailure(message: "The Mac did not answer after the request may have been sent.")
            : GatewayFailure(code: "timeout", message: "The request expired before it was sent.", retryable: true, details: nil)
        fail(id: id, epochID: epochID, error: error)
    }

    private func cancelRequest(id: String, epochID: Int) {
        guard let epoch = connection, epoch.id == epochID,
              let request = epoch.pending[id] else { return }
        let error: Error = request.transmission.mayHaveBeenSent
            ? Self.possiblySentFailure(message: "The cancelled request may have reached the Mac.")
            : CancellationError()
        fail(id: id, epochID: epochID, error: error, forcedOutcome: .cancelled)
    }

    private func fail(
        id: String,
        epochID: Int,
        error: Error,
        forcedOutcome: GatewayRPCDiagnosticOutcome? = nil
    ) {
        guard let epoch = connection, epoch.id == epochID,
              let request = epoch.pending[id] else { return }
        let outcome: GatewayRPCDiagnosticOutcome
        if let forcedOutcome { outcome = forcedOutcome }
        else if (error as? GatewayFailure)?.code == "replaced" { outcome = .superseded }
        else if error is CancellationError { outcome = .cancelled }
        else if ["timeout", "possibly_sent"].contains((error as? GatewayFailure)?.code) { outcome = .timeout }
        else if (error as? GatewayFailure)?.code == "invalid_response" { outcome = .invalidResponse }
        else { outcome = .transportFailure }
        recordRPCDiagnostic(request: request, outcome: outcome, error: error)
        guard let waiter = removePending(id: id, epochID: epochID) else { return }
        waiter.continuation.resume(throwing: error)
    }

    private func removePending(id: String, epochID: Int) -> PendingRequest? {
        guard var epoch = connection, epoch.id == epochID,
              let waiter = epoch.pending.removeValue(forKey: id) else { return nil }
        connection = epoch
        waiter.timeout.cancel()
        waiter.send?.cancel()
        return waiter
    }

    @discardableResult
    private func detachConnection(
        epochID: Int? = nil,
        reason: Error,
        queueSnapshot: GatewayEventHubSnapshot? = nil
    ) async -> Bool {
        guard let epoch = connection,
              epochID == nil || epoch.id == epochID else { return false }
        connection = nil
        let failure = Self.transportFailure(reason)
        let now = clock.now()
        let ageMilliseconds: (ContinuousClock.Instant?) -> Int? = { instant in
            guard let instant else { return nil }
            let components = instant.duration(to: now).components
            return Int(max(0, min(Int64(Int.max), components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)))
        }
        let metadata = await epoch.socket.metadata()
        recordDiagnostic(
            stage: .transport,
            outcome: .failure,
            startedAt: epoch.startedAt,
            reason: Self.diagnosticReason(for: failure.code),
            error: reason,
            closeCode: metadata.closeCode,
            httpStatusCode: metadata.httpStatusCode,
            connectionID: epoch.id,
            queueSnapshot: queueSnapshot,
            lastInboundAgeMilliseconds: ageMilliseconds(epoch.lastInboundAt),
            lastWriteProgressAgeMilliseconds: ageMilliseconds(epoch.lastWriteProgressAt),
            profileID: epoch.profileID,
            profileLabel: epoch.profileLabel,
            attemptID: epoch.attemptID
        )
        epoch.receiveTask?.cancel()
        epoch.livenessTask?.cancel()
        for waiter in epoch.pending.values {
            waiter.timeout.cancel()
            waiter.send?.cancel()
            let error: Error = waiter.transmission.mayHaveBeenSent
                ? Self.possiblySentFailure(cause: reason)
                : Self.definitelyNotSentFailure(cause: reason)
            recordRPCDiagnostic(
                request: waiter,
                outcome: (reason as? GatewayFailure)?.code == "replaced" ? .superseded : .transportFailure,
                error: error
            )
            waiter.continuation.resume(throwing: error)
        }
        await epoch.socket.close()
        return generation == epoch.id && connection == nil
    }

    private func ownsEpoch(_ epochID: Int) -> Bool {
        connection?.id == epochID
    }

    private func requireEpoch(_ epochID: Int) throws {
        guard ownsEpoch(epochID) else { throw CancellationError() }
    }

    private nonisolated static func invalidProfileEndpoint() -> GatewayFailure {
        GatewayFailure(
            code: "invalid_profile",
            message: "This saved gateway address is invalid. Pair the Mac again.",
            retryable: false,
            details: nil
        )
    }

    private nonisolated static func definitelyNotSentFailure(
        code: String = "disconnected",
        message: String = "The Mac gateway is offline.",
        cause: Error? = nil
    ) -> GatewayDefinitelyNotSentError {
        GatewayDefinitelyNotSentError(failure: GatewayFailure(
            code: code,
            message: message,
            retryable: true,
            details: cause.map { .object(["cause": .string(transportFailure($0).code)]) }
        ))
    }

    private nonisolated static func possiblySentFailure(
        message: String = "The request may have reached the Mac before the connection ended.",
        cause: Error? = nil
    ) -> GatewayPossiblySentError {
        GatewayPossiblySentError(failure: GatewayFailure(
            code: "possibly_sent",
            message: message,
            retryable: true,
            details: cause.map { .object(["cause": .string(transportFailure($0).code)]) }
        ))
    }

    private nonisolated static func diagnosticReason(for code: String) -> GatewayConnectionDiagnosticReason {
        switch code {
        case "timeout": return .timeout
        case "cancelled": return .canceled
        case "replaced": return .replaced
        case "backgrounded": return .background
        case "event_overflow": return .eventOverflow
        case "pong_timeout", "ping_timeout": return .pingTimeout
        case "possibly_sent", "transport_send_failed": return .sendFailure
        case "closed": return .closed
        case "retired": return .retired
        case "protocol_mismatch": return .protocolMismatch
        case "identity_mismatch": return .identityMismatch
        case "invalid_profile": return .invalidProfile
        default: return .transport
        }
    }

    private nonisolated static func platformErrorCode(_ error: Error) -> Int? {
        if let urlError = error as? URLError { return urlError.errorCode }
        return (error as? GatewayFailure)?.details?.objectValue?["platformCode"]?.intValue
    }

    private nonisolated static func upgradeFailure(_ error: Error, metadata: GatewaySocketMetadata) -> GatewayFailure? {
        // Typed local cancellation/deadline/protocol outcomes already own the
        // attempt. Only an actual failed HTTP upgrade supplies these meanings;
        // a WebSocket policy close alone never authorizes re-pairing.
        guard !Task.isCancelled, !(error is CancellationError), !(error is GatewayFailure),
              (error as? URLError)?.code != .cancelled,
              let status = metadata.httpStatusCode else { return nil }
        let details: JSONValue? = platformErrorCode(error).map { .object(["platformCode": .number(Double($0))]) }
        switch status {
        case 401:
            return GatewayFailure(code: "unauthenticated", message: "The Mac rejected this device's credentials.", retryable: false, details: details)
        case 403:
            return GatewayFailure(code: "forbidden", message: "The Mac denied this connection. Check access settings.", retryable: false, details: details)
        case 503:
            return GatewayFailure(code: "busy", message: "The Mac gateway is temporarily unavailable or at capacity.", retryable: true, details: details)
        default:
            return nil
        }
    }

    private nonisolated static func transportFailure(_ error: Error) -> GatewayFailure {
        if error is CancellationError {
            return GatewayFailure(code: "cancelled", message: "Connection attempt cancelled.", retryable: true, details: nil)
        }
        if let failure = error as? GatewayFailure { return failure }
        if let definitelyNotSent = error as? GatewayDefinitelyNotSentError { return definitelyNotSent.failure }
        if let possiblySent = error as? GatewayPossiblySentError { return possiblySent.failure }
        let platformCode: Int? = (error as? URLError)?.errorCode
        return GatewayFailure(
            code: "disconnected",
            message: "The Mac gateway connection ended.",
            retryable: true,
            details: platformCode.map { .object(["platformCode": .number(Double($0))]) }
        )
    }

    private nonisolated static func withTimeout<T: Sendable>(
        clock: MonotonicClock,
        duration: Duration,
        onTimeout: (@Sendable () async -> Void)? = nil,
        timeoutFailure: GatewayFailure = GatewayFailure(
            code: "timeout",
            message: "The Mac gateway did not complete its handshake.",
            retryable: true,
            details: nil
        ),
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let winner = GatewayTimeoutWinner()
        return try await withTaskCancellationHandler {
            let selected: GatewayTimeoutOutcome<T>? = await withTaskGroup(of: GatewayTimeoutOutcome<T>.self) { group in
                group.addTask {
                    do {
                        let value = try await operation()
                        return winner.claimOperation() ? .value(value) : .loser
                    } catch {
                        return winner.claimOperation() ? .failure(error) : .loser
                    }
                }
                group.addTask {
                    do {
                        try await clock.sleep(duration)
                        try Task.checkCancellation()
                    } catch {
                        return .loser
                    }
                    guard winner.claimTimeout() else { return .loser }
                    // Close before cancelling/awaiting the operation. URLSession
                    // callbacks are not required to honor task cancellation.
                    await onTimeout?()
                    return .failure(timeoutFailure)
                }
                defer { group.cancelAll() }
                while let outcome = await group.next() {
                    if case .loser = outcome { continue }
                    return outcome
                }
                return nil
            }
            guard let selected else { throw CancellationError() }
            switch selected {
            case .value(let value): return value
            case .failure(let error): throw error
            case .loser: throw CancellationError()
            }
        } onCancel: {
            // Cancellation can happen while either child is suspended. The
            // captured socket close is deliberately initiated before the group
            // waits for non-cooperative Foundation callbacks to unwind.
            if let onTimeout {
                Task { await onTimeout() }
            }
        }
    }
}
