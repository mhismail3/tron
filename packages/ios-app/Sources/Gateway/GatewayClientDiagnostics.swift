import Foundation

// The typed diagnostics the Gateway client reports: connection stages, RPC
// outcomes, the failure-code classifier, and the event consumer's work window.
// The service that serves them to the UI, and the client-side store that
// retains them, live above this layer.

enum GatewayConnectionDiagnosticStage: String, Sendable {
    case queuePressure = "queue-pressure"
    /// The WebSocket never opened: the path did not reach the Mac.
    case transportOpen = "transport-open"
    case helloSend = "hello-send"
    case helloReceive = "hello-receive"
    case liveness
    case transport
}

enum GatewayConnectionDiagnosticOutcome: String, Sendable {
    case success
    case failure
    /// A liveness probe that missed its deadline but was answered by an inbound
    /// frame. It leaves a debug record and never retires an epoch.
    case excused
}

enum GatewayConnectionDiagnosticReason: String, Sendable {
    case timeout
    case canceled
    case replaced
    case background
    case eventOverflow = "event_overflow"
    case transport
    case pingTimeout = "ping_timeout"
    case sendFailure = "send_failure"
    case closed
    case retired
    case protocolMismatch
    case identityMismatch
    case invalidProfile
    case decodeLimit = "decode_limit"
}

struct GatewayConnectionDiagnostic: Sendable {
    let sequence: Int
    let clientID: String?
    let attemptID: String?
    let connectionID: Int?
    /// The Gateway's `connectionId` from this epoch's hello, once received.
    let gatewayConnectionID: String?
    let timestamp: String
    let profileID: String?
    let profileLabel: String?
    let stage: GatewayConnectionDiagnosticStage
    let outcome: GatewayConnectionDiagnosticOutcome
    let durationMilliseconds: Int
    let reason: GatewayConnectionDiagnosticReason?
    let platformCode: Int?
    /// Transport metadata remains typed and separate: WebSocket close codes
    /// and HTTP handshake statuses must never be merged into one numeric code.
    let closeCode: Int?
    let httpStatusCode: Int?
    let overflowCount: Int?
    let overflowReason: GatewayEventAdmissionReason?
    let rejectedTopic: String?
    let overflowBytes: Int?
    let queueBytes: Int?
    let queueMaximumEvents: Int?
    let queueMaximumBytes: Int?
    let queueOldestAgeMilliseconds: Int?
    let queueTimeSinceLastDequeueMilliseconds: Int?
    let queueCountHighWaterMark: Int?
    let queueByteHighWaterMark: Int?
    let admittedEventCount: Int?
    let dequeuedEventCount: Int?
    let pressureCrossings: Int?
    let pressureLevels: [Int]?
    let dequeueWaitAgeMilliseconds: Int?
    let dequeueWaitTopic: String?
    let dequeueWaitConnectionID: Int?
    let lastInboundAgeMilliseconds: Int?
    let lastWriteProgressAgeMilliseconds: Int?
    let frameBytes: Int?
    let decodeLimitKind: JSONValueDecodingLimitKind?
    let decodeActual: Int?
    let decodeMaximum: Int?
    let decodeCodingPath: String?
    let handshake: GatewayHandshakeDiagnostic?

    init(
        sequence: Int,
        clientID: String? = nil,
        attemptID: String? = nil,
        connectionID: Int? = nil,
        gatewayConnectionID: String? = nil,
        timestamp: String,
        profileID: String?,
        profileLabel: String?,
        stage: GatewayConnectionDiagnosticStage,
        outcome: GatewayConnectionDiagnosticOutcome,
        durationMilliseconds: Int,
        reason: GatewayConnectionDiagnosticReason?,
        platformCode: Int?,
        closeCode: Int? = nil,
        httpStatusCode: Int? = nil,
        overflowCount: Int? = nil,
        overflowReason: GatewayEventAdmissionReason? = nil,
        rejectedTopic: String? = nil,
        overflowBytes: Int? = nil,
        queueBytes: Int? = nil,
        queueMaximumEvents: Int? = nil,
        queueMaximumBytes: Int? = nil,
        queueOldestAgeMilliseconds: Int? = nil,
        queueTimeSinceLastDequeueMilliseconds: Int? = nil,
        queueCountHighWaterMark: Int? = nil,
        queueByteHighWaterMark: Int? = nil,
        admittedEventCount: Int? = nil,
        dequeuedEventCount: Int? = nil,
        pressureCrossings: Int? = nil,
        pressureLevels: [Int]? = nil,
        dequeueWaitAgeMilliseconds: Int? = nil,
        dequeueWaitTopic: String? = nil,
        dequeueWaitConnectionID: Int? = nil,
        lastInboundAgeMilliseconds: Int? = nil,
        lastWriteProgressAgeMilliseconds: Int? = nil,
        frameBytes: Int? = nil,
        decodeLimitKind: JSONValueDecodingLimitKind? = nil,
        decodeActual: Int? = nil,
        decodeMaximum: Int? = nil,
        decodeCodingPath: String? = nil,
        handshake: GatewayHandshakeDiagnostic? = nil
    ) {
        self.handshake = handshake
        self.sequence = sequence
        self.clientID = clientID
        self.attemptID = attemptID
        self.connectionID = connectionID
        self.gatewayConnectionID = gatewayConnectionID
        self.timestamp = timestamp
        self.profileID = profileID
        self.profileLabel = profileLabel
        self.stage = stage
        self.outcome = outcome
        self.durationMilliseconds = durationMilliseconds
        self.reason = reason
        self.platformCode = platformCode
        self.closeCode = closeCode
        self.httpStatusCode = httpStatusCode
        self.overflowCount = overflowCount
        self.overflowReason = overflowReason
        self.rejectedTopic = rejectedTopic
        self.overflowBytes = overflowBytes
        self.queueBytes = queueBytes
        self.queueMaximumEvents = queueMaximumEvents
        self.queueMaximumBytes = queueMaximumBytes
        self.queueOldestAgeMilliseconds = queueOldestAgeMilliseconds
        self.queueTimeSinceLastDequeueMilliseconds = queueTimeSinceLastDequeueMilliseconds
        self.queueCountHighWaterMark = queueCountHighWaterMark
        self.queueByteHighWaterMark = queueByteHighWaterMark
        self.admittedEventCount = admittedEventCount
        self.dequeuedEventCount = dequeuedEventCount
        self.pressureCrossings = pressureCrossings
        self.pressureLevels = pressureLevels
        self.dequeueWaitAgeMilliseconds = dequeueWaitAgeMilliseconds
        self.dequeueWaitTopic = dequeueWaitTopic
        self.dequeueWaitConnectionID = dequeueWaitConnectionID
        self.lastInboundAgeMilliseconds = lastInboundAgeMilliseconds
        self.lastWriteProgressAgeMilliseconds = lastWriteProgressAgeMilliseconds
        self.frameBytes = frameBytes
        self.decodeLimitKind = decodeLimitKind
        self.decodeActual = decodeActual
        self.decodeMaximum = decodeMaximum
        self.decodeCodingPath = decodeCodingPath
    }
}

enum GatewayRPCDiagnosticOutcome: String, Sendable {
    case success
    case cancelled
    case superseded = "superseded/discarded"
    case timeout
    case transportFailure
    case invalidResponse
    case applicationFailure
}

struct GatewayRPCDiagnostic: Sendable {
    let method: String
    let requestID: String
    let outcome: GatewayRPCDiagnosticOutcome
    let code: String?
    let durationMilliseconds: Int
    let timestamp: String
    let profileID: String?
    let profileLabel: String?
    let incidentID: String?
}

enum GatewayDiagnosticFailure {
    static func code(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        guard let failure = error as? GatewayFailure else { return "transport" }
        return normalizedCode(failure.code)
    }

    /// The Gateway's own error code when the Gateway answered. A typed failure
    /// (for example `conflict`, `busy` or `forbidden`) must never be reported as
    /// `transport`, which is reserved for a failure that never reached the
    /// Gateway. Bounded so a malformed code cannot inflate a record.
    static func answerCode(_ error: Error) -> String {
        guard let failure = error as? GatewayFailure,
              !failure.code.isEmpty, failure.code.utf8.count <= 64 else { return code(error) }
        return failure.code
    }

    static func normalizedCode(_ code: String) -> String {
        switch code {
        case "timeout", "unauthenticated", "forbidden", "busy", "disconnected", "event_overflow", "invalid_response",
             "protocol_mismatch", "identity_mismatch", "invalid_profile", "not_paired", "pong_timeout", "ping_timeout",
             "cancelled", "possibly_sent": return code
        default: return "transport"
        }
    }
}

enum GatewayEventConsumerPhase: String, Sendable {
    case wholeHandler = "whole-handler"
    case reduction
    case synchronizationReadWait = "synchronization"
}

struct GatewayEventConsumerDiagnostic: Sendable, Equatable {
    let category: String
    let phase: GatewayEventConsumerPhase
    let count: Int
    let slowCount: Int
    let maximumDuration: Duration
    let totalDuration: Duration
    let firstObservedAt: Date
    let lastObservedAt: Date
}
