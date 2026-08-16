import Foundation

struct ContentPart: Codable, Hashable, Sendable, Identifiable {
    struct Attachment: Codable, Hashable, Sendable {
        let name: String
        let mimeType: String
        let size: Int
    }

    enum Kind: String, Codable, Sendable { case text, thinking, image, toolCall }
    let id: String
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

private protocol TranscriptPayload: Codable, Hashable, Sendable {
    var id: String { get }
    var parentId: String? { get }
    var timestamp: String { get }
}

struct MessageTranscriptItem: TranscriptPayload {
    let id: String
    let parentId: String?
    let timestamp: String
    let kind: TranscriptItem.Kind
    let role: TranscriptItem.Role
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

/// A discriminated protocol-v2 transcript value. Each Pi entry kind decodes into
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
        case .message: self = .message(try MessageTranscriptItem(from: decoder))
        case .bash: self = .bash(try BashTranscriptItem(from: decoder))
        case .customMessage: self = .customMessage(try CustomMessageTranscriptItem(from: decoder))
        case .customEntry: self = .customEntry(try CustomEntryTranscriptItem(from: decoder))
        case .compaction, .branchSummary: self = .summary(try SummaryTranscriptItem(from: decoder))
        case .modelChange: self = .modelChange(try ModelChangeTranscriptItem(from: decoder))
        case .thinkingChange: self = .thinkingChange(try ThinkingChangeTranscriptItem(from: decoder))
        case .label: self = .label(try LabelTranscriptItem(from: decoder))
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
