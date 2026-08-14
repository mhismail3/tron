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
    case toolProgress(ToolExecutionState)
    case interactions([ExtensionInteraction])
    case widget(key: String, value: ExtensionWidget?)
    case raw
    case invalid
}

struct PreparedSessionEvent: Sendable, Equatable {
    let envelope: SessionEventEnvelope
    let data: PreparedSessionEventData
}

struct GatewayEventCursor: Sendable, Equatable {
    let runtimeGeneration: String
    let eventSequence: Int
}

enum GatewayEventPreparation: Sendable, Equatable {
    case none
    case sessionSummary(SessionSummaryUpdate)
    case sessionSnapshot(SessionSnapshot)
    case sessionEvent(PreparedSessionEvent)
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

    private enum SessionEventCodingKeys: String, CodingKey {
        case runtimeGeneration, eventSequence, revision, data
    }

    private struct ProgressData: Decodable {
        let message: TranscriptItem?
    }

    init(type: String, topic: String, sessionId: String?, payload: JSONValue) {
        self.type = type
        self.topic = topic
        self.sessionId = sessionId
        self.payload = payload
        preparation = Self.prepareRaw(topic: topic, payload: payload)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        topic = try container.decode(String.self, forKey: .topic)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        payload = try container.decode(JSONValue.self, forKey: .payload)
        let payloadDecoder = try container.superDecoder(forKey: .payload)
        preparation = Self.prepare(topic: topic, from: payloadDecoder)
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
        case .sessionEvent(let event):
            return .init(
                runtimeGeneration: event.envelope.runtimeGeneration,
                eventSequence: event.envelope.eventSequence
            )
        case .none, .sessionSummary:
            return nil
        }
    }

    var isConsumableSessionReplay: Bool {
        switch preparation {
        case .sessionSnapshot:
            return true
        case .sessionEvent(let event):
            if case .invalid = event.data { return false }
            guard let object = event.envelope.data.objectValue else {
                return !["session.status", "session.working", "session.editorText"].contains(topic)
            }
            switch topic {
            case "session.status":
                return object["key"]?.stringValue != nil
            case "session.editorText":
                return object["action"]?.stringValue.map { ["set", "paste"].contains($0) } == true
                    && object["text"]?.stringValue != nil
                    && object["fullText"]?.stringValue != nil
                    && object["revision"]?.intValue != nil
            default:
                return true
            }
        case .none:
            return !topic.hasPrefix("session.")
        case .sessionSummary:
            return true
        }
    }

    private static func prepare(topic: String, from decoder: Decoder) -> GatewayEventPreparation {
        switch topic {
        case "session.summary":
            return (try? SessionSummaryUpdate(from: decoder)).map(GatewayEventPreparation.sessionSummary) ?? .none
        case "session.snapshot":
            return (try? SessionSnapshot(from: decoder)).map(GatewayEventPreparation.sessionSnapshot) ?? .none
        case let topic where topic.hasPrefix("session.") && topic != "session.listChanged":
            guard let container = try? decoder.container(keyedBy: SessionEventCodingKeys.self),
                  let runtimeGeneration = try? container.decode(String.self, forKey: .runtimeGeneration),
                  let eventSequence = try? container.decode(Int.self, forKey: .eventSequence),
                  let revision = try? container.decode(Int.self, forKey: .revision),
                  let data = try? container.decode(JSONValue.self, forKey: .data) else { return .none }
            let envelope = SessionEventEnvelope(
                runtimeGeneration: runtimeGeneration,
                eventSequence: eventSequence,
                revision: revision,
                data: data
            )
            let preparedData: PreparedSessionEventData
            switch topic {
            case "session.progress":
                if let progress = try? container.decode(ProgressData.self, forKey: .data),
                   let message = progress.message {
                    preparedData = .progress(message)
                } else {
                    preparedData = .invalid
                }
            case "session.toolProgress":
                preparedData = (try? container.decode(ToolExecutionState.self, forKey: .data))
                    .map(PreparedSessionEventData.toolProgress) ?? .invalid
            case "session.interactions":
                preparedData = (try? container.decode([ExtensionInteraction].self, forKey: .data))
                    .map(PreparedSessionEventData.interactions) ?? .invalid
            case "session.widget":
                if let key = data.objectValue?["key"]?.stringValue {
                    let widget = data.objectValue?["lines"] == .null
                        ? nil
                        : try? container.decode(ExtensionWidget.self, forKey: .data)
                    preparedData = .widget(key: key, value: widget)
                } else {
                    preparedData = .invalid
                }
            default:
                preparedData = .raw
            }
            return .sessionEvent(PreparedSessionEvent(envelope: envelope, data: preparedData))
        default:
            return .none
        }
    }

    /// Raw construction is reserved for local/synthetic events and test fixtures.
    /// Network frames use `init(from:)` and decode typed views directly from the
    /// original decoder without another byte serialization pass.
    private static func prepareRaw(topic: String, payload: JSONValue) -> GatewayEventPreparation {
        switch topic {
        case "session.summary":
            return (try? payload.decode(SessionSummaryUpdate.self))
                .map(GatewayEventPreparation.sessionSummary) ?? .none
        case "session.snapshot":
            return (try? payload.decode(SessionSnapshot.self))
                .map(GatewayEventPreparation.sessionSnapshot) ?? .none
        case let topic where topic.hasPrefix("session.") && topic != "session.listChanged":
            guard let envelope = try? payload.decode(SessionEventEnvelope.self) else { return .none }
            let preparedData: PreparedSessionEventData
            switch topic {
            case "session.progress":
                if let message = envelope.data.objectValue?["message"], message != .null,
                   let item = try? message.decode(TranscriptItem.self) {
                    preparedData = .progress(item)
                } else {
                    preparedData = .invalid
                }
            case "session.toolProgress":
                preparedData = (try? envelope.data.decode(ToolExecutionState.self))
                    .map(PreparedSessionEventData.toolProgress) ?? .invalid
            case "session.interactions":
                preparedData = (try? envelope.data.decode([ExtensionInteraction].self))
                    .map(PreparedSessionEventData.interactions) ?? .invalid
            case "session.widget":
                if let key = envelope.data.objectValue?["key"]?.stringValue {
                    let widget = envelope.data.objectValue?["lines"] == .null
                        ? nil
                        : try? envelope.data.decode(ExtensionWidget.self)
                    preparedData = .widget(key: key, value: widget)
                } else {
                    preparedData = .invalid
                }
            default:
                preparedData = .raw
            }
            return .sessionEvent(PreparedSessionEvent(envelope: envelope, data: preparedData))
        default:
            return .none
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

struct GatewayFrameDecoder: Sendable {
    let decode: @Sendable (Data) throws -> GatewayInboundFrame

    static let gateway = GatewayFrameDecoder { data in
        try JSONDecoder().decode(GatewayInboundFrame.self, from: data)
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
    let machineName: String
    let capabilities: [String]

    var info: GatewayInfo {
        GatewayInfo(
            gatewayVersion: gatewayVersion,
            piVersion: piVersion,
            protocolVersion: protocolVersion,
            minProtocolVersion: minProtocolVersion,
            machineId: machineId,
            machineName: machineName,
            capabilities: capabilities
        )
    }
}

struct EmptyParams: Codable, Sendable {}

struct CommandParams: Codable, Sendable {
    let commandId: String
    init(commandId: String = UUID().uuidString) { self.commandId = commandId }
}
