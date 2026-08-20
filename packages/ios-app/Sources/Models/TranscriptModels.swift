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
    let arguments: JSONValue?
}

extension ContentPart {
    private enum CodingKeys: String, CodingKey {
        case id, ordinal, thinkingRunOrdinal, type, text, attachment, redacted,
             mimeType, blobId, toolCallId, name, arguments
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
        arguments = try values.decodeIfPresent(JSONValue.self, forKey: .arguments)
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
        try values.encodeIfPresent(arguments, forKey: .arguments)
    }
}

private protocol TranscriptPayload: Codable, Hashable, Sendable {
    var id: String { get }
    var parentId: String? { get }
    var timestamp: String { get }
}

struct ExtensionToolOrigin: Codable, Hashable, Sendable {
    let source: String
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
    let isError: Bool?
    let details: JSONValue?
    let usage: JSONValue?
    let startedAt: String?
    let completedAt: String?
    let durationMs: Int?
    let lastProgressAt: String?
    let progressSequence: Int?
    let extensionOrigin: ExtensionToolOrigin? = nil

    private enum CodingKeys: String, CodingKey {
        case id, parentId, timestamp, kind, role, presentationId, content, provider, modelId, stopReason,
             errorMessage, toolCallId, toolName, isError, details, usage, startedAt,
             completedAt, durationMs, lastProgressAt, progressSequence, extensionOrigin
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
}

struct CustomMessageTranscriptItem: TranscriptPayload {
    let id: String
    let parentId: String?
    let timestamp: String
    let kind: TranscriptItem.Kind
    let customType: String
    let content: [ContentPart]
    let details: JSONValue?
}

struct CustomEntryTranscriptItem: TranscriptPayload {
    let id: String
    let parentId: String?
    let timestamp: String
    let kind: TranscriptItem.Kind
    let customType: String
    let data: JSONValue?
}

struct SummaryTranscriptItem: TranscriptPayload {
    let id: String
    let parentId: String?
    let timestamp: String
    let kind: TranscriptItem.Kind
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
        case .compaction, .branchSummary: self = .summary(try SummaryTranscriptItem(from: decoder))
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
              content.allSatisfy({ ($0.thinkingRunOrdinal ?? 0) >= 0 }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Projected content ordinals must be unique and nonnegative"
            )
        }
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
    var presentationId: String { if case .message(let value) = self { value.presentationId } else { id } }
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
    var extensionOrigin: ExtensionToolOrigin? { if case .message(let value) = self { value.extensionOrigin } else { nil } }
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
    var startedAt: String? { if case .message(let value) = self { value.startedAt } else { nil } }
    var completedAt: String? { if case .message(let value) = self { value.completedAt } else { nil } }
    var durationMs: Int? { if case .message(let value) = self { value.durationMs } else { nil } }
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
