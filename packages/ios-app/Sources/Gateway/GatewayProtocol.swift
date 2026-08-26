import Foundation

struct GatewayRequest: Encodable, Sendable {
    let type = "request"
    let id: String
    let method: String
    let params: JSONValue
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

    var errorDescription: String? { message }
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
    case terminalEvent(PreparedTerminalEvent)
}

struct GatewayEvent: Decodable, Sendable, Equatable {
    let type: String
    let topic: String
    let sessionId: String?
    let payload: JSONValue
    let preparation: GatewayEventPreparation

    private enum CodingKeys: String, CodingKey {
        case type, topic, sessionId, payload
    }

    init(type: String, topic: String, sessionId: String?, payload: JSONValue) {
        self.type = type
        self.topic = topic
        self.sessionId = sessionId
        self.payload = payload
        preparation = Self.prepare(topic: topic, adapter: JSONValuePayloadAdapter(payload: payload))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        topic = try container.decode(String.self, forKey: .topic)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        payload = try container.decode(JSONValue.self, forKey: .payload)
        let payloadDecoder = try container.superDecoder(forKey: .payload)
        preparation = Self.prepare(topic: topic, adapter: DecoderPayloadAdapter(decoder: payloadDecoder))
    }

    var preparedSessionEvent: PreparedSessionEvent? {
        guard case .sessionEvent(let event) = preparation else { return nil }
        return event
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
        case .none, .sessionSummary, .processTranscriptChanged, .terminalEvent:
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
        case .sessionSummary, .processTranscriptChanged, .terminalEvent:
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
        case "session.snapshot":
            guard let snapshot = try? adapter.decode(SessionSnapshot.self),
                  SessionSnapshotQueueAdmissionPolicy.admit(snapshot),
                  ExtensionPresentationPolicy.admit(snapshot.extensionPresentation),
                  ExtensionActivityAdmissionPolicy.admitsSnapshotFacts(snapshot),
                  SessionProcessAdmissionPolicy.admitsSnapshotFacts(snapshot) else { return .none }
            return .sessionSnapshot(snapshot)
        case "session.rebaseline":
            guard let payload = try? adapter.decode(RebaselinePayload.self),
                  !payload.subscriptionToken.isEmpty,
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
                   let item = try? message.decode(TranscriptItem.self) { preparedData = .progress(item) }
                else { preparedData = .invalid }
            case "session.compaction":
                if let value = envelope.data.objectValue?["item"], value != .null,
                   let item = try? value.decode(TranscriptItem.self), item.kind == .compaction {
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

    private enum CodingKeys: String, CodingKey {
        case type, gatewayVersion, piVersion, protocolVersion, minProtocolVersion,
             machineId, machineGroupID, machineName, capabilities, gatewayChannel,
             sourceRevision, buildFingerprint, runtimeEpoch
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
            runtimeEpoch: runtimeEpoch
        )
    }
}

struct EmptyParams: Codable, Sendable {}

struct CommandParams: Codable, Sendable {
    let commandId: String
    init(commandId: String = UUID().uuidString) { self.commandId = commandId }
}
