import Foundation

struct ModelRef: Codable, Hashable, Sendable, Identifiable {
    let provider: String
    let id: String

    var displayName: String { id }
}

struct ContextUsage: Codable, Hashable, Sendable {
    let tokens: Int?
    let contextWindow: Int
    let percent: Double?
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
    var queueRevision: Int? = nil
    var queuedItems: [QueuedMessage]? = nil
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

    struct QueuedMessage: Codable, Hashable, Identifiable, Sendable {
        enum Behavior: String, Codable, Hashable, Sendable {
            case steer, followUp
        }

        let id: String
        var behavior: Behavior
        var text: String
        let attachmentCount: Int
    }

    var displayedQueuedMessages: [QueuedMessage] {
        if let queuedItems { return queuedItems }
        return queued.steering.enumerated().map { index, text in
            QueuedMessage(
                id: "legacy-steer-\(index)",
                behavior: .steer,
                text: text,
                attachmentCount: 0
            )
        } + queued.followUp.enumerated().map { index, text in
            QueuedMessage(
                id: "legacy-follow-up-\(index)",
                behavior: .followUp,
                text: text,
                attachmentCount: 0
            )
        }
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
