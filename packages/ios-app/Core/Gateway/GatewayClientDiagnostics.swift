import Foundation

// The typed diagnostics the Gateway client reports: connection stages, RPC
// outcomes, the failure-code classifier, and the event consumer's work window.
// The service that serves them to the UI, and the client-side store that
// retains them, live above this layer.

package enum GatewayConnectionDiagnosticStage: String, Sendable {
    case queuePressure = "queue-pressure"
    /// The WebSocket never opened: the path did not reach the Mac.
    case transportOpen = "transport-open"
    case helloSend = "hello-send"
    case helloReceive = "hello-receive"
    case liveness
    case transport
    /// One lane of a raced attempt lost (E-3c). The winner's own hello record
    /// names the transport that carried the connection; this record names why
    /// the other lane did not.
    case transportRace = "transport-race"
}

package enum GatewayConnectionDiagnosticOutcome: String, Sendable {
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
    /// The LAN lane did not answer (E-3c). The next attempt races both lanes
    /// again; a Mac that is off the home network simply loses this lane.
    case lanUnreachable = "lan_unreachable"
    /// The LAN lane served a certificate the profile's pin does not admit
    /// (E-3c): the lane is refused before any credential is written.
    case lanPinMismatch = "lan_pin_mismatch"
    /// iOS denied this install the Local Network permission (E-3c): the lane is
    /// not dialed again until the permission changes, and the phone stays on
    /// Tailscale.
    case lanDenied = "lan_denied"
}

package struct GatewayConnectionDiagnostic: Sendable {
    let sequence: Int
    let clientID: String?
    let attemptID: String?
    let connectionID: Int?
    /// The Gateway's `connectionId` from this epoch's hello, once received.
    let gatewayConnectionID: String?
    let timestamp: String
    let profileID: String?
    let profileLabel: String?
    package let stage: GatewayConnectionDiagnosticStage
    package let outcome: GatewayConnectionDiagnosticOutcome
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
    package let handshake: GatewayHandshakeDiagnostic?

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

package struct GatewayRPCDiagnostic: Sendable {
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

package enum GatewayDiagnosticFailure {
    package static func code(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        guard let failure = error as? GatewayFailure else { return "transport" }
        return normalizedCode(failure.code)
    }

    /// The Gateway's own error code when the Gateway answered. A typed failure
    /// (for example `conflict`, `busy` or `forbidden`) must never be reported as
    /// `transport`, which is reserved for a failure that never reached the
    /// Gateway. Bounded so a malformed code cannot inflate a record.
    package static func answerCode(_ error: Error) -> String {
        guard let failure = error as? GatewayFailure,
              !failure.code.isEmpty, failure.code.utf8.count <= 64 else { return code(error) }
        return failure.code
    }

    package static func normalizedCode(_ code: String) -> String {
        switch code {
        case "timeout", "unauthenticated", "forbidden", "busy", "disconnected", "event_overflow", "invalid_response",
             "protocol_mismatch", "identity_mismatch", "invalid_profile", "not_paired", "pong_timeout", "ping_timeout",
             "cancelled", "possibly_sent": return code
        default: return "transport"
        }
    }
}

package enum GatewayEventConsumerPhase: String, Sendable {
    case wholeHandler = "whole-handler"
    case reduction
    case synchronizationReadWait = "synchronization"
}

package struct GatewayEventConsumerDiagnostic: Sendable, Equatable {
    package let category: String
    package let phase: GatewayEventConsumerPhase
    package let count: Int
    package let slowCount: Int
    package let maximumDuration: Duration
    package let totalDuration: Duration
    package let firstObservedAt: Date
    let lastObservedAt: Date

    package init(category: String, phase: GatewayEventConsumerPhase, count: Int, slowCount: Int, maximumDuration: Duration, totalDuration: Duration, firstObservedAt: Date, lastObservedAt: Date) {
        self.category = category
        self.phase = phase
        self.count = count
        self.slowCount = slowCount
        self.maximumDuration = maximumDuration
        self.totalDuration = totalDuration
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
    }
}
