import Foundation

struct ModelRef: Codable, Hashable, Sendable, Identifiable {
    let provider: String
    let id: String

    var displayName: String { id }
}

struct GatewayInfo: Codable, Hashable, Sendable {
    let gatewayVersion: String
    let piVersion: String
    let protocolVersion: Int
    let minProtocolVersion: Int
    let machineId: String
    let machineName: String
    let capabilities: [String]
}

struct PairedDevice: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let createdAt: String
}

enum SessionPhase: String, Codable, Hashable, Sendable {
    case idle, running, compacting, retrying, interrupted

    var isActive: Bool { self == .running || self == .compacting || self == .retrying }
}

struct SessionSummary: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable { case user, subagent }

    let id: String
    let name: String?
    let cwd: String
    let kind: Kind
    let parentSessionId: String?
    let createdAt: String
    let updatedAt: String
    let messageCount: Int
    let firstMessage: String
    let phase: SessionPhase
    let summaryRevision: Int?

    init(
        id: String, name: String?, cwd: String, kind: Kind = .user, parentSessionId: String?,
        createdAt: String, updatedAt: String, messageCount: Int,
        firstMessage: String, phase: SessionPhase, summaryRevision: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.kind = kind
        self.parentSessionId = parentSessionId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.firstMessage = firstMessage
        self.phase = phase
        self.summaryRevision = summaryRevision
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, cwd, kind, parentSessionId, createdAt, updatedAt, messageCount, firstMessage, phase, summaryRevision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        cwd = try container.decode(String.self, forKey: .cwd)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .user
        parentSessionId = try container.decodeIfPresent(String.self, forKey: .parentSessionId)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        messageCount = try container.decode(Int.self, forKey: .messageCount)
        firstMessage = try container.decode(String.self, forKey: .firstMessage)
        phase = try container.decode(SessionPhase.self, forKey: .phase)
        summaryRevision = try container.decodeIfPresent(Int.self, forKey: .summaryRevision)
    }

    var title: String {
        if let name, !name.isEmpty { return name }
        let first = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return first.isEmpty ? "New session" : String(first.prefix(80))
    }

    var workspaceName: String {
        URL(fileURLWithPath: cwd).lastPathComponent.isEmpty ? cwd : URL(fileURLWithPath: cwd).lastPathComponent
    }

    func relativeActivityDescription(relativeTo now: Date = .now) -> String {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: updatedAt) ?? ISO8601DateFormatter().date(from: updatedAt) else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func dashboardSessions(_ sessions: [SessionSummary]) -> [SessionSummary] {
        sessions.filter { $0.kind == .user }
    }
}

struct SessionSummaryUpdate: Codable, Hashable, Sendable {
    let sessionId: String
    let summaryRevision: Int
    let phase: SessionPhase
    let name: String?
    let updatedAt: String
    let messageCount: Int
    let firstMessage: String
}

struct ContextUsage: Codable, Hashable, Sendable {
    let tokens: Int?
    let contextWindow: Int
    let percent: Double?
}

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

struct ExtensionInteraction: Codable, Hashable, Identifiable, Sendable {
    enum Method: String, Codable, Sendable { case select, confirm, input, editor }
    let id: String
    let method: Method
    let title: String
    let message: String?
    let options: [String]?
    let placeholder: String?
    let prefill: String?
    let expiresAt: String?
}

struct ExtensionWidget: Codable, Hashable, Identifiable, Sendable {
    enum Placement: String, Codable, Sendable { case aboveEditor, belowEditor }
    let key: String
    let lines: [String]
    let placement: Placement
    var id: String { key }
}

struct ExtensionUIState: Codable, Hashable, Sendable {
    struct Working: Codable, Hashable, Sendable {
        var message: String?
        var visible: Bool
    }
    var statuses: [String: String]
    var working: Working
    var hiddenThinkingLabel: String?
    var widgets: [ExtensionWidget]
    var title: String?
    var editorRevision: Int
    var editorText: String
    var pendingInteractions: [ExtensionInteraction]
}

struct ToolExecutionState: Codable, Hashable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable { case running, completed, failed }
    let toolCallId: String
    let toolName: String
    let order: Int?
    let status: Status
    let arguments: JSONValue
    let partialResult: JSONValue?
    let result: JSONValue?
    let output: String?
    let outputTruncated: Bool?
    let isError: Bool
    let startedAt: String
    let updatedAt: String
    let lastProgressAt: String?
    let completedAt: String?
    let durationMs: Int?
    let progressSequence: Int?
    var id: String { toolCallId }

    init(
        toolCallId: String, toolName: String, order: Int? = nil, status: Status,
        arguments: JSONValue, partialResult: JSONValue?, result: JSONValue?,
        output: String? = nil, outputTruncated: Bool? = nil,
        isError: Bool, startedAt: String, updatedAt: String,
        lastProgressAt: String? = nil, completedAt: String? = nil,
        durationMs: Int? = nil, progressSequence: Int? = nil
    ) {
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.order = order
        self.status = status
        self.arguments = arguments
        self.partialResult = partialResult
        self.result = result
        self.output = output
        self.outputTruncated = outputTruncated
        self.isError = isError
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.lastProgressAt = lastProgressAt
        self.completedAt = completedAt
        self.durationMs = durationMs
        self.progressSequence = progressSequence
    }
}

struct RetryState: Codable, Hashable, Sendable {
    enum Source: String, Codable, Sendable { case agent, compaction, branchSummary }
    let source: Source
    let attempt: Int
    let maxAttempts: Int?
    let delayMs: Int?
    let errorMessage: String?
}

struct SessionOperationState: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case prompt, compaction, branchSummary, bash, retry }
    let id: String?
    let kind: Kind
    let startedAt: String
    let reason: String?
}

struct RuntimeDiagnostic: Codable, Hashable, Sendable {
    let type: String
    let message: String
}

struct SessionStats: Codable, Hashable, Sendable {
    struct Tokens: Codable, Hashable, Sendable {
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheWrite: Int
        let total: Int
    }
    let userMessages: Int
    let assistantMessages: Int
    let toolCalls: Int
    let toolResults: Int
    let totalMessages: Int
    let tokens: Tokens
    let latestCacheHitRate: Double?
    let cost: Double
}

struct SessionSnapshot: Codable, Hashable, Sendable {
    var sessionId: String
    var runtimeGeneration: String
    var revision: Int
    var eventSequence: Int
    var phase: SessionPhase
    var name: String?
    var cwd: String
    var parentSessionId: String?
    var model: ModelRef?
    var thinkingLevel: String
    var availableThinkingLevels: [String]
    var contextUsage: ContextUsage?
    var stats: SessionStats
    var queued: QueuedMessages
    var transcript: [TranscriptItem]
    var transcriptStart: Int?
    var transcriptTotal: Int?
    var streaming: TranscriptItem?
    var leafEntryId: String?
    var operation: SessionOperationState?
    var retry: RetryState?
    var toolExecutions: [ToolExecutionState]
    var extensionUI: ExtensionUIState
    var diagnostics: [RuntimeDiagnostic]

    struct QueuedMessages: Codable, Hashable, Sendable {
        let steering: [String]
        let followUp: [String]
    }
}

struct SessionEventEnvelope: Codable, Hashable, Sendable {
    let runtimeGeneration: String
    let eventSequence: Int
    let revision: Int
    let data: JSONValue
}

struct SessionTreeNode: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let parentId: String?
    let timestamp: String
    let kind: String
    let label: String?
    let preview: String
    let role: TranscriptItem.Role?
    let depth: Int
    let childCount: Int
    let isCurrentPath: Bool
}

struct CommandInfo: Codable, Hashable, Identifiable, Sendable {
    enum Source: String, Codable, Sendable { case `extension`, skill, prompt }
    let name: String
    let description: String?
    let argumentHint: String?
    let source: Source
    let sourcePath: String?
    var id: String { "\(source.rawValue):\(name)" }
}

struct PackageSummary: Codable, Hashable, Identifiable, Sendable {
    enum Scope: String, Codable, Sendable { case user, project }
    let source: String
    let scope: Scope
    let filtered: Bool
    let installedPath: String?
    var id: String { "\(scope.rawValue):\(source)" }
}

struct PackageInventory: Codable, Hashable, Sendable {
    let packages: [PackageSummary]
    let resources: JSONValue
}

struct PackageUpdate: Codable, Hashable, Identifiable, Sendable {
    let source: String
    let displayName: String
    let type: String
    let scope: PackageSummary.Scope
    var id: String { "\(scope.rawValue):\(source)" }
}

struct ProviderSummary: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let configured: Bool
    let authSource: String?
    let credentialType: String?
    let authMethods: [String]
    let modelCount: Int
}

struct ModelSummary: Codable, Hashable, Identifiable, Sendable {
    let provider: String
    let id: String
    let name: String
    let reasoning: Bool
    let input: [String]
    let contextWindow: Int
    let maxTokens: Int
    let available: Bool

    var ref: ModelRef { ModelRef(provider: provider, id: id) }
}

struct WorkspaceListing: Codable, Hashable, Sendable {
    let path: String
    let parent: String?
    let entries: [WorkspaceEntry]
}

struct WorkspaceEntry: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case directory, file }
    let name: String
    let path: String
    let kind: Kind
    let hidden: Bool
    var id: String { path }
}

struct TerminalSummary: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let sessionId: String
    let cwd: String
    let createdAt: String
    let exitedAt: String?
    let exitCode: Int?
    let sequence: Int
}

struct TerminalChunk: Codable, Hashable, Sendable {
    let sequence: Int
    let data: String
}
