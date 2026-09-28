import Foundation
import TronMobileCore

package struct GatewayRequest: Encodable, Sendable {
    let type = "request"
    let id: String
    let method: String
    let params: JSONValue

    package init(id: String, method: String, params: JSONValue) {
        self.id = id
        self.method = method
        self.params = params
    }
}

package struct GatewayResponse: Decodable, Sendable, Equatable {
    let type: String
    package let id: String
    let ok: Bool
    package let result: JSONValue?
    package let error: GatewayFailure?
}

/// Local transport provenance for an operation whose bytes definitely did not
/// leave the client's queued state. This type is intentionally not Codable and
/// cannot be forged by a Gateway application-error response.
package struct GatewayDefinitelyNotSentError: Error, Hashable, Sendable, LocalizedError {
    package let failure: GatewayFailure

    package init(failure: GatewayFailure) {
        self.failure = failure
    }

    package var errorDescription: String? { failure.message }
}

/// Local transport provenance for an operation whose bytes may have reached the
/// Gateway. This type is intentionally not Codable and cannot be forged by a
/// Gateway application-error response.
package struct GatewayPossiblySentError: Error, Hashable, Sendable, LocalizedError {
    package let failure: GatewayFailure

    package init(failure: GatewayFailure) {
        self.failure = failure
    }

    package var errorDescription: String? { failure.message }
}

package struct GatewayFailure: Codable, Error, Hashable, Sendable, LocalizedError {
    package let code: String
    package let message: String
    package let retryable: Bool
    package let details: JSONValue?

    package init(code: String, message: String, retryable: Bool, details: JSONValue?) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.details = details
    }

    package var errorDescription: String? { message }
}

package enum PreparedSessionEventData: Sendable, Equatable {
    case progress(TranscriptItem)
    case compaction(TranscriptItem)
    case toolProgress(ToolExecutionState)
    case extensionActivity(ExtensionActivityDelta)
    case processActivity(SessionProcessDelta)
    case extensionPresentation(ExtensionPresentationMutation)
    case raw
    case invalid
}

package struct PreparedSessionEvent: Sendable, Equatable {
    package let envelope: SessionEventEnvelope
    package let data: PreparedSessionEventData
}

package struct PreparedSessionRebaseline: Sendable, Equatable {
    package let snapshot: SessionSnapshot
    package let subscriptionToken: String
}

package struct GatewayEventCursor: Sendable, Equatable {
    package let runtimeGeneration: String
    package let eventSequence: Int

    package init(runtimeGeneration: String, eventSequence: Int) {
        self.runtimeGeneration = runtimeGeneration
        self.eventSequence = eventSequence
    }
}

package struct PreparedTerminalOutputEvent: Decodable, Sendable, Equatable {
    package let terminalId: String
    package let sequence: Int
    package let data: String

    package init(terminalId: String, sequence: Int, data: String) {
        self.terminalId = terminalId
        self.sequence = sequence
        self.data = data
    }
}

package struct PreparedTerminalExitEvent: Decodable, Sendable, Equatable {
    package let terminalId: String
    package let sequence: Int?
    package let exitCode: Int?

    package init(terminalId: String, sequence: Int?, exitCode: Int?) {
        self.terminalId = terminalId
        self.sequence = sequence
        self.exitCode = exitCode
    }
}

package enum PreparedTerminalEvent: Sendable, Equatable {
    case output(PreparedTerminalOutputEvent)
    case exit(PreparedTerminalExitEvent)
}

package enum GatewayEventPreparation: Sendable, Equatable {
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

package struct GatewayEvent: Decodable, Sendable, Equatable {
    let type: String
    package let topic: String
    package let sessionId: String?
    package let payload: JSONValue
    /// Trusted encoded frame size supplied before synchronization admission.
    let admittedBytes: Int
    package let preparation: GatewayEventPreparation

    private enum CodingKeys: String, CodingKey {
        case type, topic, sessionId, payload
    }

    package init(type: String, topic: String, sessionId: String?, payload: JSONValue, admittedBytes: Int = 0) {
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

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        topic = try container.decode(String.self, forKey: .topic)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        payload = try container.decode(JSONValue.self, forKey: .payload)
        admittedBytes = 0
        let payloadDecoder = try container.superDecoder(forKey: .payload)
        preparation = Self.prepare(topic: topic, adapter: DecoderPayloadAdapter(decoder: payloadDecoder))
    }

    package var preparedSessionEvent: PreparedSessionEvent? {
        guard case .sessionEvent(let event) = preparation else { return nil }
        return event
    }

    package var preparedNotificationInboxChanged: NotificationInboxChanged? {
        guard case .notificationInboxChanged(let change) = preparation else { return nil }
        return change
    }

    package var sessionCursor: GatewayEventCursor? {
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

package enum GatewayInboundFrame: Decodable, Sendable, Equatable {
    case response(GatewayResponse)
    case event(GatewayEvent)
    case unsupported

    private enum CodingKeys: String, CodingKey { case type }

    package init(from decoder: Decoder) throws {
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

package enum GatewayFramePolicy {
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

package enum GatewayTokenAdmissionPolicy {
    static let maximumUTF8Bytes = 200

    package static func admit(_ token: String) -> Bool {
        // Keep scalar membership explicit: Xcode 27's optimized app build
        // miscompiles the bound CharacterSet.contains predicate and rejects
        // valid tokens, preventing both sync acknowledgement and cleanup.
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && token.utf8.count <= maximumUTF8Bytes
            && !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}
package struct GatewayFrameDecoder: Sendable {
    package let decode: @Sendable (Data) throws -> GatewayInboundFrame

    package static let gateway = GatewayFrameDecoder { data in
        try GatewayFramePolicy.validateInboundBytes(data)
        return try JSONDecoder.gateway.decode(GatewayInboundFrame.self, from: data)
    }
}

package struct GatewayEventDelivery: Sendable, Equatable {
    package let connectionID: Int
    package let event: GatewayEvent

    package init(connectionID: Int, event: GatewayEvent) {
        self.connectionID = connectionID
        self.event = event
    }
}

package struct GatewayConnectionIdentity: Sendable, Equatable {
    package let id: Int
    package let info: GatewayInfo

    package init(id: Int, info: GatewayInfo) {
        self.id = id
        self.info = info
    }
}

package struct GatewayHello: Decodable, Sendable {
    package let type: String
    package let gatewayVersion: String
    package let piVersion: String
    package let protocolVersion: Int
    package let minProtocolVersion: Int
    let machineId: String
    let machineGroupID: String?
    let machineName: String
    let capabilities: [String]
    package let gatewayChannel: String
    let sourceRevision: String?
    let buildFingerprint: String?
    let runtimeEpoch: String?

    private enum CodingKeys: String, CodingKey {
        case type, gatewayVersion, piVersion, protocolVersion, minProtocolVersion,
             machineId, machineGroupID, machineName, capabilities, gatewayChannel,
             sourceRevision, buildFingerprint, runtimeEpoch
    }

    package init(from decoder: Decoder) throws {
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

    package var info: GatewayInfo {
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

package struct EmptyParams: Codable, Sendable {
    package init() {}
}
