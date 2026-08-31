import Foundation

struct ContentPart: Codable, Hashable, Sendable, Identifiable {
    struct Attachment: Codable, Hashable, Sendable {
        let name: String
        let mimeType: String
        let size: Int
    }

    enum Kind: String, Codable, Sendable { case text, thinking, image, toolCall }
    let id: String
    let ordinal: Int
    let thinkingRunOrdinal: Int?
    let type: Kind
    let text: String?
    let attachment: Attachment?
    let redacted: Bool?
    let mimeType: String?
    let blobId: String?
    let toolCallId: String?
    let name: String?
    let label: String?
    let arguments: JSONValue?
    let toolSegmentId: String?
    let groupId: String?
    let groupIndex: Int?
    let groupCount: Int?
    let groupFinalized: Bool?
}

extension ContentPart {
    init(
        id: String,
        ordinal: Int,
        thinkingRunOrdinal: Int?,
        type: Kind,
        text: String?,
        attachment: Attachment?,
        redacted: Bool?,
        mimeType: String?,
        blobId: String?,
        toolCallId: String?,
        name: String?,
        arguments: JSONValue?
    ) {
        self.id = id
        self.ordinal = ordinal
        self.thinkingRunOrdinal = thinkingRunOrdinal
        self.type = type
        self.text = text
        self.attachment = attachment
        self.redacted = redacted
        self.mimeType = mimeType
        self.blobId = blobId
        self.toolCallId = toolCallId
        self.name = name
        label = nil
        self.arguments = arguments
        toolSegmentId = nil
        groupId = nil
        groupIndex = nil
        groupCount = nil
        groupFinalized = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, ordinal, thinkingRunOrdinal, type, text, attachment, redacted,
             mimeType, blobId, toolCallId, name, label, arguments,
             toolSegmentId, groupId, groupIndex, groupCount, groupFinalized
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        ordinal = try values.decode(Int.self, forKey: .ordinal)
        type = try values.decode(Kind.self, forKey: .type)
        thinkingRunOrdinal = try values.decodeIfPresent(Int.self, forKey: .thinkingRunOrdinal)
        if type == .thinking, thinkingRunOrdinal == nil {
            throw DecodingError.keyNotFound(
                CodingKeys.thinkingRunOrdinal,
                .init(
                    codingPath: values.codingPath,
                    debugDescription: "Thinking content requires a stable run ordinal"
                )
            )
        }
        text = try values.decodeIfPresent(String.self, forKey: .text)
        attachment = try values.decodeIfPresent(Attachment.self, forKey: .attachment)
        redacted = try values.decodeIfPresent(Bool.self, forKey: .redacted)
        mimeType = try values.decodeIfPresent(String.self, forKey: .mimeType)
        blobId = try values.decodeIfPresent(String.self, forKey: .blobId)
        toolCallId = try values.decodeIfPresent(String.self, forKey: .toolCallId)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        label = try values.decodeIfPresent(String.self, forKey: .label)
        arguments = try values.decodeIfPresent(JSONValue.self, forKey: .arguments)
        toolSegmentId = try values.decodeIfPresent(String.self, forKey: .toolSegmentId)
        groupId = try values.decodeIfPresent(String.self, forKey: .groupId)
        groupIndex = try values.decodeIfPresent(Int.self, forKey: .groupIndex)
        groupCount = try values.decodeIfPresent(Int.self, forKey: .groupCount)
        groupFinalized = try values.decodeIfPresent(Bool.self, forKey: .groupFinalized)
        if let toolSegmentId, type != .toolCall || toolSegmentId.isEmpty {
            throw DecodingError.dataCorruptedError(
                forKey: .toolSegmentId,
                in: values,
                debugDescription: "Tool segment identity must be nonempty and owned by a tool call"
            )
        }
        let identityFieldsPresent = [groupId != nil, groupIndex != nil, groupCount != nil]
        if identityFieldsPresent.contains(true) || groupFinalized == true {
            guard type == .toolCall,
                  identityFieldsPresent.allSatisfy({ $0 }),
                  let groupId, !groupId.isEmpty,
                  let groupIndex, groupIndex >= 0,
                  let groupCount, groupCount > 0, groupIndex < groupCount,
                  groupFinalized == true else {
                throw DecodingError.dataCorruptedError(
                    forKey: .groupId,
                    in: values,
                    debugDescription: "Tool invocation group metadata must be complete, finalized, and in bounds"
                )
            }
        } else if groupFinalized == false, type != .toolCall {
            throw DecodingError.dataCorruptedError(
                forKey: .groupFinalized,
                in: values,
                debugDescription: "Only provisional tool calls may carry groupFinalized=false"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(ordinal, forKey: .ordinal)
        try values.encodeIfPresent(thinkingRunOrdinal, forKey: .thinkingRunOrdinal)
        try values.encode(type, forKey: .type)
        try values.encodeIfPresent(text, forKey: .text)
        try values.encodeIfPresent(attachment, forKey: .attachment)
        try values.encodeIfPresent(redacted, forKey: .redacted)
        try values.encodeIfPresent(mimeType, forKey: .mimeType)
        try values.encodeIfPresent(blobId, forKey: .blobId)
        try values.encodeIfPresent(toolCallId, forKey: .toolCallId)
        try values.encodeIfPresent(name, forKey: .name)
        try values.encodeIfPresent(label, forKey: .label)
        try values.encodeIfPresent(arguments, forKey: .arguments)
        try values.encodeIfPresent(toolSegmentId, forKey: .toolSegmentId)
        try values.encodeIfPresent(groupId, forKey: .groupId)
        try values.encodeIfPresent(groupIndex, forKey: .groupIndex)
        try values.encodeIfPresent(groupCount, forKey: .groupCount)
        try values.encodeIfPresent(groupFinalized, forKey: .groupFinalized)
    }
}

private protocol TranscriptPayload: Codable, Hashable, Sendable {
    var id: String { get }
    var parentId: String? { get }
    var timestamp: String { get }
}

struct ExtensionToolOrigin: Codable, Hashable, Sendable {
    /// Legacy public source fallback. It is never a filesystem path or grouping
    /// key when more than one admitted owner claims it.
    let source: String
    /// Exact opaque owner identity, when supplied by the Gateway.
    let owner: ExtensionOwner?

    init(source: String, owner: ExtensionOwner? = nil) {
        self.source = source
        self.owner = owner
    }

    private enum CodingKeys: String, CodingKey { case source, owner }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        source = try values.decode(String.self, forKey: .source)
        guard !source.isEmpty, source.utf8.count <= 8_192,
              !source.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw DecodingError.dataCorruptedError(forKey: .source, in: values, debugDescription: "Extension origin source is invalid")
        }
        owner = try values.decodeIfPresent(ExtensionOwner.self, forKey: .owner)
        if let owner {
            guard !owner.source.isEmpty, owner.source.utf8.count <= 8_192 else {
                throw DecodingError.dataCorruptedError(forKey: .owner, in: values, debugDescription: "Extension owner source is invalid")
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(source, forKey: .source)
        try values.encodeIfPresent(owner, forKey: .owner)
    }
}

enum ChatDirection: String, Codable, Sendable { case inboundContext, agentOutput, agentInvocation, ambientStatus, hiddenInternal }
enum ChatContextEffect: String, Codable, Sendable { case none, modelInput, hiddenModelInput, toolResult }
enum ChatDelivery: String, Codable, Sendable { case stored, nextTurn, steer, followUp, triggeredTurn, continuedTurn, beforeAgentStart, toolResult, unknown }
enum ChatOriginKind: String, Codable, Sendable { case user, subagent, `extension`, process, gateway, assistant, unknown }
enum ChatSemanticKind: String, Codable, Sendable { case prompt, resourcePrompt, command, message, tool, status, state, unknown }
enum ChatSemanticVisibility: String, Codable, Sendable { case visible, hidden }

enum ChatOriginConfidence: String, Codable, Sendable { case boundary, receipt, adapter, unknown }

private func admitsSemanticString(_ value: String, maximumBytes: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximumBytes
        && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
}

struct ChatOrigin: Codable, Hashable, Sendable {
    let kind: ChatOriginKind
    let ownerId: String?
    let title: String?
    let confidence: ChatOriginConfidence

    private enum CodingKeys: String, CodingKey { case kind, ownerId, title, confidence }

    init(kind: ChatOriginKind, ownerId: String? = nil, title: String? = nil, confidence: ChatOriginConfidence) {
        self.kind = kind; self.ownerId = ownerId; self.title = title; self.confidence = confidence
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(ChatOriginKind.self, forKey: .kind)
        ownerId = try values.decodeIfPresent(String.self, forKey: .ownerId)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        confidence = try values.decode(ChatOriginConfidence.self, forKey: .confidence)
        guard ownerId.map({ admitsSemanticString($0, maximumBytes: 256) }) ?? true,
              title.map({ admitsSemanticString($0, maximumBytes: 512) }) ?? true else {
            throw DecodingError.dataCorruptedError(
                forKey: .ownerId,
                in: values,
                debugDescription: "Chat origin metadata is invalid or oversized"
            )
        }
    }
}

struct ChatSemanticMetadata: Codable, Hashable, Sendable {
    let version: Int
    let direction: ChatDirection
    let contextEffect: ChatContextEffect
    let delivery: ChatDelivery
    let visibility: ChatSemanticVisibility
    let kind: ChatSemanticKind
    let origin: ChatOrigin
    let invocationId: String?
    let operationId: String?
    let sequence: Int
    let lifecycle: InvocationLifecycle?
    let resourceInvocation: ComposerResourceInvocation?

    private enum CodingKeys: String, CodingKey {
        case version, direction, contextEffect, delivery, visibility, kind, origin,
             invocationId, operationId, sequence, lifecycle, resourceInvocation
    }

    init(
        version: Int = 1,
        direction: ChatDirection,
        contextEffect: ChatContextEffect,
        delivery: ChatDelivery,
        visibility: ChatSemanticVisibility,
        kind: ChatSemanticKind,
        origin: ChatOrigin,
        invocationId: String? = nil,
        operationId: String? = nil,
        sequence: Int,
        lifecycle: InvocationLifecycle? = nil,
        resourceInvocation: ComposerResourceInvocation? = nil
    ) {
        self.version = version; self.direction = direction; self.contextEffect = contextEffect
        self.delivery = delivery; self.visibility = visibility; self.kind = kind; self.origin = origin
        self.invocationId = invocationId; self.operationId = operationId; self.sequence = sequence
        self.lifecycle = lifecycle; self.resourceInvocation = resourceInvocation
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        direction = try values.decode(ChatDirection.self, forKey: .direction)
        contextEffect = try values.decode(ChatContextEffect.self, forKey: .contextEffect)
        delivery = try values.decode(ChatDelivery.self, forKey: .delivery)
        visibility = try values.decode(ChatSemanticVisibility.self, forKey: .visibility)
        kind = try values.decode(ChatSemanticKind.self, forKey: .kind)
        origin = try values.decode(ChatOrigin.self, forKey: .origin)
        invocationId = try values.decodeIfPresent(String.self, forKey: .invocationId)
        operationId = try values.decodeIfPresent(String.self, forKey: .operationId)
        sequence = try values.decode(Int.self, forKey: .sequence)
        lifecycle = try values.decodeIfPresent(InvocationLifecycle.self, forKey: .lifecycle)
        resourceInvocation = try values.decodeIfPresent(ComposerResourceInvocation.self, forKey: .resourceInvocation)
        guard version == 1, sequence >= 0,
              invocationId.map({ admitsSemanticString($0, maximumBytes: 256) }) ?? true,
              operationId.map({ admitsSemanticString($0, maximumBytes: 256) }) ?? true,
              resourceInvocation.map(\.isTransportValid) ?? true else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: values,
                debugDescription: "Chat semantic metadata is invalid or oversized"
            )
        }
    }
}

struct MessageTranscriptItem: TranscriptPayload {
    let id: String
    let parentId: String?
    let timestamp: String
    let kind: TranscriptItem.Kind
    let role: TranscriptItem.Role
    let presentationId: String
    let content: [ContentPart]
    let provider: String?
    let modelId: String?
    let stopReason: String?
    let errorMessage: String?
    let toolCallId: String?
    let toolName: String?
    let toolLabel: String?
    let isError: Bool?
    let details: JSONValue?
    let usage: JSONValue?
    let startedAt: String?
    let completedAt: String?
    let durationMs: Int?
    let lastProgressAt: String?
    let progressSequence: Int?
    let toolSegmentId: String?
    let semantic: ChatSemanticMetadata?
    var extensionOrigin: ExtensionToolOrigin? = nil

    private enum CodingKeys: String, CodingKey {
        case id, parentId, timestamp, kind, role, presentationId, content, provider, modelId, stopReason,
             errorMessage, toolCallId, toolName, toolLabel, isError, details, usage, startedAt,
             completedAt, durationMs, lastProgressAt, progressSequence, toolSegmentId, semantic, extensionOrigin
    }

    init(
        id: String, parentId: String?, timestamp: String, kind: TranscriptItem.Kind, role: TranscriptItem.Role,
        presentationId: String, content: [ContentPart], provider: String? = nil, modelId: String? = nil,
        stopReason: String? = nil, errorMessage: String? = nil, toolCallId: String? = nil, toolName: String? = nil,
        toolLabel: String? = nil, isError: Bool? = nil, details: JSONValue? = nil, usage: JSONValue? = nil, startedAt: String? = nil,
        completedAt: String? = nil, durationMs: Int? = nil, lastProgressAt: String? = nil,
        progressSequence: Int? = nil, toolSegmentId: String? = nil,
        semantic: ChatSemanticMetadata? = nil,
        extensionOrigin: ExtensionToolOrigin? = nil
    ) {
        self.id = id; self.parentId = parentId; self.timestamp = timestamp; self.kind = kind; self.role = role
        self.presentationId = presentationId; self.content = content; self.provider = provider; self.modelId = modelId
        self.stopReason = stopReason; self.errorMessage = errorMessage; self.toolCallId = toolCallId; self.toolName = toolName
        self.toolLabel = toolLabel; self.isError = isError; self.details = details; self.usage = usage; self.startedAt = startedAt; self.completedAt = completedAt
        self.durationMs = durationMs; self.lastProgressAt = lastProgressAt; self.progressSequence = progressSequence
        self.toolSegmentId = toolSegmentId
        self.semantic = semantic
        self.extensionOrigin = extensionOrigin
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        parentId = try values.decodeIfPresent(String.self, forKey: .parentId)
        timestamp = try values.decode(String.self, forKey: .timestamp)
        kind = try values.decode(TranscriptItem.Kind.self, forKey: .kind)
        role = try values.decode(TranscriptItem.Role.self, forKey: .role)
        presentationId = try values.decode(String.self, forKey: .presentationId)
        let decodedContent = try values.decode([ContentPart].self, forKey: .content)
        let grouped = Dictionary(grouping: decodedContent.filter { $0.groupId != nil }, by: { $0.groupId! })
        for parts in grouped.values {
            guard let expectedCount = parts.first?.groupCount,
                  parts.allSatisfy({
                      $0.groupCount == expectedCount
                          && $0.toolSegmentId == parts.first?.toolSegmentId
                  }),
                  parts.count == expectedCount,
                  Set(parts.compactMap(\.groupIndex)) == Set(0..<expectedCount) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .content, in: values,
                    debugDescription: "Tool invocation group metadata is inconsistent"
                )
            }
        }
        content = decodedContent
        provider = try values.decodeIfPresent(String.self, forKey: .provider)
        modelId = try values.decodeIfPresent(String.self, forKey: .modelId)
        stopReason = try values.decodeIfPresent(String.self, forKey: .stopReason)
        errorMessage = try values.decodeIfPresent(String.self, forKey: .errorMessage)
        toolCallId = try values.decodeIfPresent(String.self, forKey: .toolCallId)
        toolName = try values.decodeIfPresent(String.self, forKey: .toolName)
        toolLabel = try values.decodeIfPresent(String.self, forKey: .toolLabel)
        isError = try values.decodeIfPresent(Bool.self, forKey: .isError)
        details = try values.decodeIfPresent(JSONValue.self, forKey: .details)
        usage = try values.decodeIfPresent(JSONValue.self, forKey: .usage)
        startedAt = try values.decodeIfPresent(String.self, forKey: .startedAt)
        completedAt = try values.decodeIfPresent(String.self, forKey: .completedAt)
        durationMs = try values.decodeIfPresent(Int.self, forKey: .durationMs)
        lastProgressAt = try values.decodeIfPresent(String.self, forKey: .lastProgressAt)
        progressSequence = try values.decodeIfPresent(Int.self, forKey: .progressSequence)
        toolSegmentId = try values.decodeIfPresent(String.self, forKey: .toolSegmentId)
        semantic = try values.decodeIfPresent(ChatSemanticMetadata.self, forKey: .semantic)
        if let toolSegmentId, role != .toolResult || toolSegmentId.isEmpty {
            throw DecodingError.dataCorruptedError(
                forKey: .toolSegmentId,
                in: values,
                debugDescription: "Only a tool result may carry nonempty tool segment identity"
            )
        }
        extensionOrigin = try values.decodeIfPresent(ExtensionToolOrigin.self, forKey: .extensionOrigin)
    }
}

struct BashTranscriptItem: TranscriptPayload {
    let id: String
    let parentId: String?
    let timestamp: String
    let kind: TranscriptItem.Kind
    let command: String
    let output: String
    let exitCode: Int?
    let cancelled: Bool
    let truncated: Bool
    let fullOutputPath: String?
    let excludeFromContext: Bool?
    let startedAt: String?
    let completedAt: String?
    let durationMs: Int?
}

struct CustomMessageTranscriptItem: TranscriptPayload {
    let id: String
    let parentId: String?
    let timestamp: String
    let kind: TranscriptItem.Kind
    let customType: String
    let content: [ContentPart]
    let details: JSONValue?
    let semantic: ChatSemanticMetadata?
}

struct CustomEntryTranscriptItem: TranscriptPayload {
    let id: String
    let parentId: String?
    let timestamp: String
    let kind: TranscriptItem.Kind
    let customType: String
    let data: JSONValue?
    let semantic: ChatSemanticMetadata?
}

struct SummaryTranscriptItem: TranscriptPayload {
    let id: String
    let parentId: String?
    let timestamp: String
    let kind: TranscriptItem.Kind
    let presentationId: String?
    let summary: String
    let tokensBefore: Int?
    let details: JSONValue?
    let usage: JSONValue?
    let fromHook: Bool?
}

struct ModelChangeTranscriptItem: TranscriptPayload {
    let id: String
    let parentId: String?
    let timestamp: String
    let kind: TranscriptItem.Kind
    let modelRef: ModelRef
}

struct ThinkingChangeTranscriptItem: TranscriptPayload {
    let id: String
    let parentId: String?
    let timestamp: String
    let kind: TranscriptItem.Kind
    let level: String
}

struct LabelTranscriptItem: TranscriptPayload {
    let id: String
    let parentId: String?
    let timestamp: String
    let kind: TranscriptItem.Kind
    let targetId: String
    let label: String?
}

/// A discriminated Gateway transcript value. Each Pi entry kind decodes into
/// a shape that cannot accidentally accept fields belonging to another kind.
enum TranscriptItem: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case message, bash, customMessage, customEntry, compaction, branchSummary, modelChange, thinkingChange, label
    }
    enum Role: String, Codable, Sendable { case user, assistant, toolResult }

    case message(MessageTranscriptItem)
    case bash(BashTranscriptItem)
    case customMessage(CustomMessageTranscriptItem)
    case customEntry(CustomEntryTranscriptItem)
    case summary(SummaryTranscriptItem)
    case modelChange(ModelChangeTranscriptItem)
    case thinkingChange(ThinkingChangeTranscriptItem)
    case label(LabelTranscriptItem)

    private enum CodingKeys: String, CodingKey { case kind }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .message:
            let message = try MessageTranscriptItem(from: decoder)
            guard !message.presentationId.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: container,
                    debugDescription: "Message presentation identity cannot be empty"
                )
            }
            try Self.validateContentOrdinals(message.content, container: container)
            self = .message(message)
        case .bash: self = .bash(try BashTranscriptItem(from: decoder))
        case .customMessage:
            let message = try CustomMessageTranscriptItem(from: decoder)
            try Self.validateContentOrdinals(message.content, container: container)
            self = .customMessage(message)
        case .customEntry: self = .customEntry(try CustomEntryTranscriptItem(from: decoder))
        case .compaction, .branchSummary:
            let summary = try SummaryTranscriptItem(from: decoder)
            guard summary.presentationId.map({ !$0.isEmpty && $0.utf8.count <= 200 }) != false else {
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: container,
                    debugDescription: "Summary presentation identity must be nonempty and bounded"
                )
            }
            self = .summary(summary)
        case .modelChange: self = .modelChange(try ModelChangeTranscriptItem(from: decoder))
        case .thinkingChange: self = .thinkingChange(try ThinkingChangeTranscriptItem(from: decoder))
        case .label: self = .label(try LabelTranscriptItem(from: decoder))
        }
    }

    private static func validateContentOrdinals(
        _ content: [ContentPart],
        container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        let ordinals = content.map(\.ordinal)
        guard ordinals.allSatisfy({ $0 >= 0 }), Set(ordinals).count == ordinals.count,
              content.allSatisfy({ ($0.thinkingRunOrdinal ?? 0) >= 0 }),
              validToolGroups(in: content) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Projected content ordinals and finalized tool groups must be unique and valid"
            )
        }
    }

    private static func validToolGroups(in content: [ContentPart]) -> Bool {
        let grouped = Dictionary(grouping: content.compactMap { part in
            part.groupId == nil ? nil : part
        }, by: { $0.groupId! })
        for parts in grouped.values {
            guard let expectedCount = parts.first?.groupCount,
                  parts.allSatisfy({ $0.toolSegmentId == parts.first?.toolSegmentId }),
                  parts.count == expectedCount,
                  Set(parts.compactMap(\.groupIndex)) == Set(0..<expectedCount) else { return false }
            let positions = parts.compactMap { part in
                content.firstIndex(where: { $0.id == part.id })
            }
            guard let first = positions.min(), positions.count == expectedCount,
                  positions.sorted() == Array(first..<(first + expectedCount)) else { return false }
        }
        return true
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .message(let value): try value.encode(to: encoder)
        case .bash(let value): try value.encode(to: encoder)
        case .customMessage(let value): try value.encode(to: encoder)
        case .customEntry(let value): try value.encode(to: encoder)
        case .summary(let value): try value.encode(to: encoder)
        case .modelChange(let value): try value.encode(to: encoder)
        case .thinkingChange(let value): try value.encode(to: encoder)
        case .label(let value): try value.encode(to: encoder)
        }
    }

    var id: String { payload.id }
    var parentId: String? { payload.parentId }
    var timestamp: String { payload.timestamp }
    var kind: Kind {
        switch self {
        case .message: .message
        case .bash: .bash
        case .customMessage: .customMessage
        case .customEntry: .customEntry
        case .summary(let value): value.kind
        case .modelChange: .modelChange
        case .thinkingChange: .thinkingChange
        case .label: .label
        }
    }
    var role: Role? { if case .message(let value) = self { value.role } else { nil } }
    var presentationId: String {
        switch self {
        case .message(let value): value.presentationId
        case .summary(let value): value.presentationId ?? value.id
        default: id
        }
    }
    var content: [ContentPart]? {
        switch self {
        case .message(let value): value.content
        case .customMessage(let value): value.content
        default: nil
        }
    }
    var provider: String? { if case .message(let value) = self { value.provider } else { nil } }
    var modelId: String? { if case .message(let value) = self { value.modelId } else { nil } }
    var stopReason: String? { if case .message(let value) = self { value.stopReason } else { nil } }
    var errorMessage: String? { if case .message(let value) = self { value.errorMessage } else { nil } }
    var toolCallId: String? { if case .message(let value) = self { value.toolCallId } else { nil } }
    var toolName: String? { if case .message(let value) = self { value.toolName } else { nil } }
    var toolLabel: String? { if case .message(let value) = self { value.toolLabel } else { nil } }
    var extensionOrigin: ExtensionToolOrigin? { if case .message(let value) = self { value.extensionOrigin } else { nil } }
    var toolSegmentId: String? { if case .message(let value) = self { value.toolSegmentId } else { nil } }
    var isError: Bool? { if case .message(let value) = self { value.isError } else { nil } }
    var details: JSONValue? {
        switch self {
        case .message(let value): value.details
        case .customMessage(let value): value.details
        case .summary(let value): value.details
        default: nil
        }
    }
    var usage: JSONValue? {
        switch self {
        case .message(let value): value.usage
        case .summary(let value): value.usage
        default: nil
        }
    }
    var startedAt: String? {
        switch self {
        case .message(let value): value.startedAt
        case .bash(let value): value.startedAt
        default: nil
        }
    }
    var completedAt: String? {
        switch self {
        case .message(let value): value.completedAt
        case .bash(let value): value.completedAt
        default: nil
        }
    }
    var durationMs: Int? {
        switch self {
        case .message(let value): value.durationMs
        case .bash(let value): value.durationMs
        default: nil
        }
    }
    var lastProgressAt: String? { if case .message(let value) = self { value.lastProgressAt } else { nil } }
    var progressSequence: Int? { if case .message(let value) = self { value.progressSequence } else { nil } }
    var command: String? { if case .bash(let value) = self { value.command } else { nil } }
    var output: String? { if case .bash(let value) = self { value.output } else { nil } }
    var exitCode: Int? { if case .bash(let value) = self { value.exitCode } else { nil } }
    var cancelled: Bool? { if case .bash(let value) = self { value.cancelled } else { nil } }
    var truncated: Bool? { if case .bash(let value) = self { value.truncated } else { nil } }
    var fullOutputPath: String? { if case .bash(let value) = self { value.fullOutputPath } else { nil } }
    var customType: String? {
        switch self {
        case .customMessage(let value): value.customType
        case .customEntry(let value): value.customType
        default: nil
        }
    }
    var semantic: ChatSemanticMetadata? {
        switch self {
        case .message(let value): value.semantic
        case .customMessage(let value): value.semantic
        case .customEntry(let value): value.semantic
        default: nil
        }
    }
    var customData: JSONValue? { if case .customEntry(let value) = self { value.data } else { nil } }
    var summary: String? { if case .summary(let value) = self { value.summary } else { nil } }
    var tokensBefore: Int? { if case .summary(let value) = self { value.tokensBefore } else { nil } }
    var modelRef: ModelRef? { if case .modelChange(let value) = self { value.modelRef } else { nil } }
    var level: String? { if case .thinkingChange(let value) = self { value.level } else { nil } }
    var targetId: String? { if case .label(let value) = self { value.targetId } else { nil } }
    var label: String? { if case .label(let value) = self { value.label } else { nil } }

    var text: String {
        content?.compactMap { part in
            part.type == .text && part.attachment == nil ? part.text : nil
        }.joined() ?? summary ?? output ?? ""
    }

    private var payload: any TranscriptPayload {
        switch self {
        case .message(let value): value
        case .bash(let value): value
        case .customMessage(let value): value
        case .customEntry(let value): value
        case .summary(let value): value
        case .modelChange(let value): value
        case .thinkingChange(let value): value
        case .label(let value): value
        }
    }
}
