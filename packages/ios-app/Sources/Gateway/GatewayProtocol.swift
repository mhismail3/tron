import Foundation

struct GatewayRequest: Encodable, Sendable {
    let type = "request"
    let id: String
    let method: String
    let params: JSONValue
}

/// The `cancel` control frame (protocol 6): this client no longer waits for the
/// named request, so the Gateway may stop computing its answer. It has no reply.
struct GatewayCancelFrame: Encodable, Sendable {
    let type = "cancel"
    let id: String
}

/// Reads whose answer nothing consumes once the caller abandons them, so the
/// Gateway may abandon the work with them. Every entry only projects state and
/// settles nothing durable. Accepted mutations and admitted prompts are never
/// here: those keep their owner on the Gateway and settle durably, whatever the
/// phone does with the wait.
enum GatewayDisposableReadPolicy {
    static let disposableReadMethods: Set<String> = [
        "session.open",
        "session.list",
        "session.transcript",
        "session.history.list",
        "session.history.entry",
        "session.search",
        "model.list",
        "provider.list",
        "provider.usage"
    ]

    static func admits(_ method: String) -> Bool { disposableReadMethods.contains(method) }

    /// A shed disposable read is answered `busy` with a retry hint (`G-12`). One
    /// retry is what the hint is for; a Gateway that keeps shedding is telling
    /// the caller the truth about its capacity rather than asking to be hammered.
    static let busyRetryLimit = 1
    /// The longest wait a server-supplied hint can impose, so one shed read
    /// cannot park a caller behind an unbounded Gateway answer.
    static let maximumRetryAfterDelay = Duration.seconds(10)

    /// The wait this failure asks for, or nil when the failure is not a shed
    /// disposable read: a locally minted failure has no hint, and a mutation or
    /// prompt is never retried from here — its owner settles it durably.
    static func retryAfterDelay(for failure: GatewayFailure, method: String) -> Duration? {
        guard admits(method),
              failure.code == "busy",
              failure.answeredByGateway == true,
              case .object(let details)? = failure.details,
              case .number(let milliseconds)? = details["retryAfterMs"],
              milliseconds > 0
        else { return nil }
        return min(.seconds(milliseconds / 1_000), maximumRetryAfterDelay)
    }
}

struct GatewayResponse: Decodable, Sendable, Equatable {
    let type: String
    let id: String
    let ok: Bool
    let result: JSONValue?
    let error: GatewayFailure?
}

/// Local transport provenance for an operation whose bytes definitely did not
/// leave the client's queued state. This type is intentionally not Codable and
/// cannot be forged by a Gateway application-error response.
struct GatewayDefinitelyNotSentError: Error, Hashable, Sendable, LocalizedError {
    let failure: GatewayFailure
    var errorDescription: String? { failure.message }
}

/// Local transport provenance for an operation whose bytes may have reached the
/// Gateway. This type is intentionally not Codable and cannot be forged by a
/// Gateway application-error response.
struct GatewayPossiblySentError: Error, Hashable, Sendable, LocalizedError {
    let failure: GatewayFailure
    var errorDescription: String? { failure.message }
}

struct GatewayFailure: Codable, Error, Hashable, Sendable, LocalizedError {
    let code: String
    let message: String
    let retryable: Bool
    let details: JSONValue?
    /// Whether this failure is the Gateway's own answer: the decoded error of a
    /// response the Gateway sent, rather than a code the phone's transport
    /// minted locally for a request that never got an answer. The wire failure
    /// has no such field, so the client stamps it where it decodes an answer;
    /// `session.open.failure` reports `gatewayCode` only from a stamped failure.
    var answeredByGateway: Bool? = nil

    /// Phone-local provenance, so it is not a wire key: a response frame cannot
    /// stamp or clear it, and an encoded failure never carries it. The client is
    /// the only writer (see `stampedAsGatewayAnswer`).
    private enum CodingKeys: String, CodingKey {
        case code, message, retryable, details
    }

    var errorDescription: String? { message }

    /// The same failure stamped as the Gateway's own answer.
    var stampedAsGatewayAnswer: GatewayFailure {
        var stamped = self
        stamped.answeredByGateway = true
        return stamped
    }
}

enum PreparedSessionEventData: Sendable, Equatable {
    case progress(TranscriptItem)
    case compaction(TranscriptItem)
    case toolProgress(ToolExecutionState)
    case extensionActivity(ExtensionActivityDelta)
    case processActivity(SessionProcessDelta)
    case extensionPresentation(ExtensionPresentationMutation)
    case raw
    case invalid
}

struct PreparedSessionEvent: Sendable, Equatable {
    let envelope: SessionEventEnvelope
    let data: PreparedSessionEventData
}

struct PreparedSessionRebaseline: Sendable, Equatable {
    let snapshot: SessionSnapshot
    let subscriptionToken: String
}

struct GatewayEventCursor: Sendable, Equatable {
    let runtimeGeneration: String
    let eventSequence: Int
}

struct PreparedTerminalOutputEvent: Decodable, Sendable, Equatable {
    let terminalId: String
    let sequence: Int
    let data: String
}

struct PreparedTerminalExitEvent: Decodable, Sendable, Equatable {
    let terminalId: String
    let sequence: Int?
    let exitCode: Int?
}

enum PreparedTerminalEvent: Sendable, Equatable {
    case output(PreparedTerminalOutputEvent)
    case exit(PreparedTerminalExitEvent)
}

enum GatewayEventPreparation: Sendable, Equatable {
    case none
    case sessionSummary(SessionSummaryUpdate)
    case sessionSnapshot(SessionSnapshot)
    case sessionRebaseline(PreparedSessionRebaseline)
    case sessionEvent(PreparedSessionEvent)
    case processTranscriptChanged(ProcessTranscriptChanged)
    case automationChanged(AutomationChanged)
    case notificationInboxChanged(NotificationInboxChanged)
    case terminalEvent(PreparedTerminalEvent)
}

struct GatewayEvent: Decodable, Sendable, Equatable {
    let type: String
    let topic: String
    let sessionId: String?
    let payload: JSONValue
    /// Trusted encoded frame size supplied before synchronization admission.
    let admittedBytes: Int
    let preparation: GatewayEventPreparation

    private enum CodingKeys: String, CodingKey {
        case type, topic, sessionId, payload
    }

    init(type: String, topic: String, sessionId: String?, payload: JSONValue, admittedBytes: Int = 0) {
        self.type = type
        self.topic = topic
        self.sessionId = sessionId
        self.payload = payload
        self.admittedBytes = max(0, admittedBytes)
        preparation = Self.prepare(topic: topic, adapter: JSONValuePayloadAdapter(payload: payload))
    }

    /// Stamps transport admission metadata without reparsing the payload. The
    /// network decoder has already prepared typed session data from the original
    /// Decoder; rebuilding through JSONValue here would repeat expensive work and
    /// can lose decoder-specific numeric/date representation.
    func withAdmittedBytes(_ bytes: Int) -> Self {
        Self(
            type: type,
            topic: topic,
            sessionId: sessionId,
            payload: payload,
            admittedBytes: bytes,
            preparation: preparation
        )
    }

    private init(
        type: String,
        topic: String,
        sessionId: String?,
        payload: JSONValue,
        admittedBytes: Int,
        preparation: GatewayEventPreparation
    ) {
        self.type = type
        self.topic = topic
        self.sessionId = sessionId
        self.payload = payload
        self.admittedBytes = max(0, admittedBytes)
        self.preparation = preparation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        topic = try container.decode(String.self, forKey: .topic)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        payload = try container.decode(JSONValue.self, forKey: .payload)
        admittedBytes = 0
        let payloadDecoder = try container.superDecoder(forKey: .payload)
        preparation = Self.prepare(topic: topic, adapter: DecoderPayloadAdapter(decoder: payloadDecoder))
    }

    var preparedSessionEvent: PreparedSessionEvent? {
        guard case .sessionEvent(let event) = preparation else { return nil }
        return event
    }

    var preparedNotificationInboxChanged: NotificationInboxChanged? {
        guard case .notificationInboxChanged(let change) = preparation else { return nil }
        return change
    }

    var sessionCursor: GatewayEventCursor? {
        switch preparation {
        case .sessionSnapshot(let snapshot):
            return .init(
                runtimeGeneration: snapshot.runtimeGeneration,
                eventSequence: snapshot.eventSequence
            )
        case .sessionRebaseline(let rebaseline):
            return .init(
                runtimeGeneration: rebaseline.snapshot.runtimeGeneration,
                eventSequence: rebaseline.snapshot.eventSequence
            )
        case .sessionEvent(let event):
            return .init(
                runtimeGeneration: event.envelope.runtimeGeneration,
                eventSequence: event.envelope.eventSequence
            )
        case .none, .sessionSummary, .processTranscriptChanged, .automationChanged,
             .notificationInboxChanged, .terminalEvent:
            return nil
        }
    }

    var isConsumableSessionReplay: Bool {
        switch preparation {
        case .sessionSnapshot(let snapshot):
            return sessionId != nil && sessionId == snapshot.sessionId
        case .sessionRebaseline(let rebaseline):
            return sessionId != nil && sessionId == rebaseline.snapshot.sessionId
        case .sessionEvent(let event):
            if case .invalid = event.data { return false }
            return true
        case .none:
            return !topic.hasPrefix("session.")
        case .sessionSummary, .processTranscriptChanged, .automationChanged,
             .notificationInboxChanged, .terminalEvent:
            return true
        }
    }

    private struct RebaselinePayload: Decodable {
        let snapshot: SessionSnapshot
        let subscriptionToken: String
    }

    private protocol PayloadAdapter {
        func decode<T: Decodable>(_ type: T.Type) throws -> T
    }

    private struct DecoderPayloadAdapter: PayloadAdapter {
        let decoder: Decoder
        func decode<T: Decodable>(_ type: T.Type) throws -> T { try T(from: decoder) }
    }

    private struct JSONValuePayloadAdapter: PayloadAdapter {
        let payload: JSONValue
        func decode<T: Decodable>(_ type: T.Type) throws -> T { try payload.decode(type) }
    }

    private static func prepare(topic: String, adapter: some PayloadAdapter) -> GatewayEventPreparation {
        switch topic {
        case "session.summary":
            return (try? adapter.decode(SessionSummaryUpdate.self)).map(GatewayEventPreparation.sessionSummary) ?? .none
        case "automation.changed":
            return (try? adapter.decode(AutomationChanged.self)).map(GatewayEventPreparation.automationChanged) ?? .none
        case "notification.inbox.changed":
            guard let change = try? adapter.decode(NotificationInboxChanged.self),
                  NotificationInboxAdmissionPolicy.admits(change) else { return .none }
            return .notificationInboxChanged(change)
        case "session.snapshot":
            guard let snapshot = try? adapter.decode(SessionSnapshot.self),
                  SessionSnapshotTranscriptAdmissionPolicy.admit(snapshot),
                  SessionSnapshotQueueAdmissionPolicy.admit(snapshot),
                  ExtensionPresentationPolicy.admit(snapshot.extensionPresentation),
                  ExtensionActivityAdmissionPolicy.admitsSnapshotFacts(snapshot),
                  SessionProcessAdmissionPolicy.admitsSnapshotFacts(snapshot) else { return .none }
            return .sessionSnapshot(snapshot)
        case "session.rebaseline":
            guard let payload = try? adapter.decode(RebaselinePayload.self),
                  GatewayTokenAdmissionPolicy.admit(payload.subscriptionToken),
                  SessionSnapshotTranscriptAdmissionPolicy.admit(payload.snapshot),
                  SessionSnapshotQueueAdmissionPolicy.admit(payload.snapshot),
                  ExtensionPresentationPolicy.admit(payload.snapshot.extensionPresentation),
                  ExtensionActivityAdmissionPolicy.admitsSnapshotFacts(payload.snapshot),
                  SessionProcessAdmissionPolicy.admitsSnapshotFacts(payload.snapshot) else { return .none }
            return .sessionRebaseline(PreparedSessionRebaseline(snapshot: payload.snapshot, subscriptionToken: payload.subscriptionToken))
        case "terminal.output":
            return (try? adapter.decode(PreparedTerminalOutputEvent.self)).map { .terminalEvent(.output($0)) } ?? .none
        case "terminal.exit":
            return (try? adapter.decode(PreparedTerminalExitEvent.self)).map { .terminalEvent(.exit($0)) } ?? .none
        case "session.processTranscript.changed":
            guard let changed = try? adapter.decode(ProcessTranscriptChanged.self),
                  SessionProcessAdmissionPolicy.admits(changed) else { return .none }
            return .processTranscriptChanged(changed)
        case let topic where topic.hasPrefix("session.") && topic != "session.listChanged":
            guard let envelope = try? adapter.decode(SessionEventEnvelope.self) else { return .none }
            let preparedData: PreparedSessionEventData
            switch topic {
            case "session.progress":
                if let message = envelope.data.objectValue?["message"], message != .null,
                   let item = try? message.decode(TranscriptItem.self),
                   SessionSnapshotTranscriptAdmissionPolicy.admitsItem(item) {
                    preparedData = .progress(item)
                }
                else { preparedData = .invalid }
            case "session.compaction":
                if let value = envelope.data.objectValue?["item"], value != .null,
                   let item = try? value.decode(TranscriptItem.self), item.kind == .compaction,
                   SessionSnapshotTranscriptAdmissionPolicy.admitsItem(item) {
                    preparedData = .compaction(item)
                } else {
                    preparedData = .invalid
                }
            case "session.toolProgress":
                if let tool = try? envelope.data.decode(ToolExecutionState.self),
                   ExtensionActivityAdmissionPolicy.admitsToolFacts(tool) { preparedData = .toolProgress(tool) }
                else { preparedData = .invalid }
            case "session.extensionActivity":
                if let delta = try? envelope.data.decode(ExtensionActivityDelta.self),
                   ExtensionActivityAdmissionPolicy.admitsDelta(delta) { preparedData = .extensionActivity(delta) }
                else { preparedData = .invalid }
            case "session.processActivity":
                if let delta = try? envelope.data.decode(SessionProcessDelta.self),
                   SessionProcessAdmissionPolicy.admits(delta) { preparedData = .processActivity(delta) }
                else { preparedData = .invalid }
            case "session.extensionPresentation":
                if let mutation = try? envelope.data.decode(ExtensionPresentationMutation.self),
                   ExtensionPresentationPolicy.admit(mutation) { preparedData = .extensionPresentation(mutation) }
                else { preparedData = .invalid }
            default: preparedData = .raw
            }
            return .sessionEvent(PreparedSessionEvent(envelope: envelope, data: preparedData))
        default: return .none
        }
    }
}

enum GatewayInboundFrame: Decodable, Sendable, Equatable {
    case response(GatewayResponse)
    case event(GatewayEvent)
    case unsupported

    private enum CodingKeys: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self),
              let type = try? container.decode(String.self, forKey: .type) else {
            self = .unsupported
            return
        }
        switch type {
        case "response": self = .response(try GatewayResponse(from: decoder))
        case "event": self = .event(try GatewayEvent(from: decoder))
        default: self = .unsupported
        }
    }
}

enum GatewayFramePolicy {
    static let maximumInboundBytes = 1_048_576

    static func validateInboundBytes(_ data: Data) throws {
        guard data.count <= maximumInboundBytes else {
            throw GatewayFailure(
                code: "frame_too_large",
                message: "The Mac sent a Gateway frame larger than the supported protocol limit.",
                retryable: true,
                details: nil
            )
        }
    }
}

enum GatewayTokenAdmissionPolicy {
    static let maximumUTF8Bytes = 200

    static func admit(_ token: String) -> Bool {
        // Keep scalar membership explicit: Xcode 27's optimized app build
        // miscompiles the bound CharacterSet.contains predicate and rejects
        // valid tokens, preventing both sync acknowledgement and cleanup.
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && token.utf8.count <= maximumUTF8Bytes
            && !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}
struct GatewayFrameDecoder: Sendable {
    let decode: @Sendable (Data) throws -> GatewayInboundFrame

    static let gateway = GatewayFrameDecoder { data in
        try GatewayFramePolicy.validateInboundBytes(data)
        return try JSONDecoder.gateway.decode(GatewayInboundFrame.self, from: data)
    }
}

struct GatewayEventDelivery: Sendable, Equatable {
    let connectionID: Int
    let event: GatewayEvent
}

struct GatewayConnectionIdentity: Sendable, Equatable {
    let id: Int
    let info: GatewayInfo
    /// The Gateway's key for this connection's records (O-1 correlation).
    let gatewayConnectionID: String?
}

struct GatewayHello: Decodable, Sendable {
    let type: String
    let gatewayVersion: String
    let piVersion: String
    let protocolVersion: Int
    let minProtocolVersion: Int
    let machineId: String
    let machineGroupID: String?
    let machineName: String
    let capabilities: [String]
    let gatewayChannel: String
    let sourceRevision: String?
    let buildFingerprint: String?
    let runtimeEpoch: String?
    /// The advertised grant projection revision; absence means this Gateway
    /// cannot say whether its stored grants changed, so the phone re-sends.
    let pushRegistrationRevision: String?
    /// Diagnostic only, so its absence never fails the handshake.
    let connectionId: String?
    /// The LAN lane the Gateway serves right now (E-3b). Every hello replaces
    /// what the profile stored, so an empty list is the lane being switched
    /// off, and a Gateway that never advertises leaves the profile as it was.
    let lanEndpoints: [GatewayLanEndpoint]
    let lanPin: String?

    private enum CodingKeys: String, CodingKey {
        case type, gatewayVersion, piVersion, protocolVersion, minProtocolVersion,
             machineId, machineGroupID, machineName, capabilities, gatewayChannel,
             sourceRevision, buildFingerprint, runtimeEpoch, pushRegistrationRevision, connectionId,
             lanEndpoints, lanPin
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        gatewayVersion = try values.decode(String.self, forKey: .gatewayVersion)
        piVersion = try values.decode(String.self, forKey: .piVersion)
        protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
        minProtocolVersion = try values.decode(Int.self, forKey: .minProtocolVersion)
        machineId = try values.decode(String.self, forKey: .machineId)
        machineGroupID = try values.decodeIfPresent(String.self, forKey: .machineGroupID)
        machineName = try values.decode(String.self, forKey: .machineName)
        capabilities = try values.decode([String].self, forKey: .capabilities)
        gatewayChannel = try GatewayChannelPolicy.admit(values.decode(String.self, forKey: .gatewayChannel))
        sourceRevision = try values.decodeIfPresent(String.self, forKey: .sourceRevision)
        buildFingerprint = try values.decodeIfPresent(String.self, forKey: .buildFingerprint)
        runtimeEpoch = try values.decodeIfPresent(String.self, forKey: .runtimeEpoch)
        pushRegistrationRevision = try values.decodeIfPresent(String.self, forKey: .pushRegistrationRevision)
        connectionId = try values.decodeIfPresent(String.self, forKey: .connectionId)
        lanEndpoints = GatewayLanEndpoint.sanitized(
            (try? values.decodeIfPresent([GatewayLanEndpoint].self, forKey: .lanEndpoints)) ?? nil
        )
        let pin: String? = (try? values.decodeIfPresent(String.self, forKey: .lanPin)) ?? nil
        lanPin = pin.flatMap(GatewayLanPin.admit)
    }

    var info: GatewayInfo {
        GatewayInfo(
            gatewayVersion: gatewayVersion,
            piVersion: piVersion,
            protocolVersion: protocolVersion,
            minProtocolVersion: minProtocolVersion,
            machineId: machineId,
            machineGroupID: machineGroupID,
            machineName: machineName,
            capabilities: capabilities,
            gatewayChannel: gatewayChannel,
            sourceRevision: sourceRevision,
            buildFingerprint: buildFingerprint,
            runtimeEpoch: runtimeEpoch,
            pushRegistrationRevision: pushRegistrationRevision,
            lanEndpoints: lanEndpoints,
            lanPin: lanPin
        )
    }
}

struct EmptyParams: Codable, Sendable {}
