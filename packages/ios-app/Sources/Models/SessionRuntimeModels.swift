import Foundation

struct ModelRef: Codable, Hashable, Sendable, Identifiable {
    let provider: String
    let id: String

}

struct ContextUsage: Codable, Hashable, Sendable {
    let tokens: Int?
    let contextWindow: Int
    let percent: Double?
}

struct ExtensionRunChild: Codable, Hashable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable { case running, completed, failed }
    let id: String
    let label: String
    let status: Status
    let lifecycle: ExtensionActivityLifecycleState?
    let attention: ExtensionActivityAttention?
    let task: String?
    let lastActivityAt: String?
    let currentTool: String?
    let currentToolStartedAt: String?
    let currentPath: String?
    let toolCount: Int?
    let turnCount: Int?
    let durationMs: Int?
    let output: String?
    let children: [ExtensionRunChild]?

    var displayStateName: String {
        if let lifecycle { return lifecycle.displayName }
        return switch status {
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }

    init(id: String, label: String, status: Status, lifecycle: ExtensionActivityLifecycleState? = nil,
         attention: ExtensionActivityAttention? = nil, task: String? = nil, lastActivityAt: String? = nil,
         currentTool: String? = nil, currentToolStartedAt: String? = nil, currentPath: String? = nil,
         toolCount: Int? = nil, turnCount: Int? = nil, durationMs: Int? = nil, output: String? = nil,
         children: [ExtensionRunChild]? = nil) {
        self.id = id; self.label = label; self.status = status; self.lifecycle = lifecycle; self.attention = attention
        self.task = task; self.lastActivityAt = lastActivityAt; self.currentTool = currentTool
        self.currentToolStartedAt = currentToolStartedAt; self.currentPath = currentPath; self.toolCount = toolCount
        self.turnCount = turnCount; self.durationMs = durationMs; self.output = output; self.children = children
    }
}

struct ExtensionRunActivity: Codable, Hashable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable { case running, completed, failed }
    let id: String
    /// Gateway-owned deterministic presentation identity. `id` remains for
    /// rolling compatibility with older snapshots.
    let activityId: String?
    let runId: String?
    let toolCallId: String
    let source: ExtensionToolOrigin
    let title: String
    let mode: String?
    let status: Status
    let startedAt: String
    let updatedAt: String
    let completedAt: String?
    let lastActivityAt: String?
    let currentTool: String?
    let currentToolStartedAt: String?
    let currentPath: String?
    let toolCount: Int?
    let turnCount: Int?
    let durationMs: Int?
    let output: String?
    let children: [ExtensionRunChild]
    let lifecycle: ExtensionActivityLifecycle?

    var stableID: String { activityId ?? id }
    var isLive: Bool { lifecycle?.state.isCurrent ?? (status == .running) }
    var displayStateName: String {
        if let lifecycle { return lifecycle.state.displayName }
        return switch status {
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }

    init(
        id: String, activityId: String? = nil, runId: String? = nil,
        toolCallId: String, source: ExtensionToolOrigin, title: String,
        mode: String? = nil, status: Status, startedAt: String, updatedAt: String,
        completedAt: String? = nil, lastActivityAt: String? = nil,
        currentTool: String? = nil, currentToolStartedAt: String? = nil,
        currentPath: String? = nil, toolCount: Int? = nil, turnCount: Int? = nil,
        durationMs: Int? = nil, output: String? = nil,
        children: [ExtensionRunChild] = [], lifecycle: ExtensionActivityLifecycle? = nil
    ) {
        self.id = id; self.activityId = activityId; self.runId = runId
        self.toolCallId = toolCallId; self.source = source; self.title = title
        self.mode = mode; self.status = status; self.startedAt = startedAt; self.updatedAt = updatedAt
        self.completedAt = completedAt; self.lastActivityAt = lastActivityAt
        self.currentTool = currentTool; self.currentToolStartedAt = currentToolStartedAt
        self.currentPath = currentPath; self.toolCount = toolCount; self.turnCount = turnCount
        self.durationMs = durationMs; self.output = output; self.children = children; self.lifecycle = lifecycle
    }

    private enum CodingKeys: String, CodingKey {
        case id, activityId, runId, toolCallId, source, title, mode, status,
             startedAt, updatedAt, completedAt, lastActivityAt, currentTool,
             currentToolStartedAt, currentPath, toolCount, turnCount, durationMs,
             output, children, lifecycle
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        activityId = try values.decodeIfPresent(String.self, forKey: .activityId)
        runId = try values.decodeIfPresent(String.self, forKey: .runId)
        toolCallId = try values.decode(String.self, forKey: .toolCallId)
        source = try values.decode(ExtensionToolOrigin.self, forKey: .source)
        title = try values.decode(String.self, forKey: .title)
        mode = try values.decodeIfPresent(String.self, forKey: .mode)
        status = try values.decode(Status.self, forKey: .status)
        startedAt = try values.decode(String.self, forKey: .startedAt)
        updatedAt = try values.decode(String.self, forKey: .updatedAt)
        completedAt = try values.decodeIfPresent(String.self, forKey: .completedAt)
        lastActivityAt = try values.decodeIfPresent(String.self, forKey: .lastActivityAt)
        currentTool = try values.decodeIfPresent(String.self, forKey: .currentTool)
        currentToolStartedAt = try values.decodeIfPresent(String.self, forKey: .currentToolStartedAt)
        currentPath = try values.decodeIfPresent(String.self, forKey: .currentPath)
        toolCount = try values.decodeIfPresent(Int.self, forKey: .toolCount)
        turnCount = try values.decodeIfPresent(Int.self, forKey: .turnCount)
        durationMs = try values.decodeIfPresent(Int.self, forKey: .durationMs)
        output = try values.decodeIfPresent(String.self, forKey: .output)
        children = try values.decode([ExtensionRunChild].self, forKey: .children)
        lifecycle = try values.decodeIfPresent(ExtensionActivityLifecycle.self, forKey: .lifecycle)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encodeIfPresent(activityId, forKey: .activityId)
        try values.encodeIfPresent(runId, forKey: .runId); try values.encode(toolCallId, forKey: .toolCallId)
        try values.encode(source, forKey: .source); try values.encode(title, forKey: .title)
        try values.encodeIfPresent(mode, forKey: .mode); try values.encode(status, forKey: .status)
        try values.encode(startedAt, forKey: .startedAt); try values.encode(updatedAt, forKey: .updatedAt)
        try values.encodeIfPresent(completedAt, forKey: .completedAt); try values.encodeIfPresent(lastActivityAt, forKey: .lastActivityAt)
        try values.encodeIfPresent(currentTool, forKey: .currentTool); try values.encodeIfPresent(currentToolStartedAt, forKey: .currentToolStartedAt)
        try values.encodeIfPresent(currentPath, forKey: .currentPath); try values.encodeIfPresent(toolCount, forKey: .toolCount)
        try values.encodeIfPresent(turnCount, forKey: .turnCount); try values.encodeIfPresent(durationMs, forKey: .durationMs)
        try values.encodeIfPresent(output, forKey: .output); try values.encode(children, forKey: .children)
        try values.encodeIfPresent(lifecycle, forKey: .lifecycle)
    }
}

struct ExtensionActivityDelta: Codable, Hashable, Sendable {
    let activity: ExtensionRunActivity
    let liveActivityRevision: Int
    let extensionActivityAsOf: String
}

struct ToolExecutionState: Codable, Hashable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable { case running, completed, failed }
    let toolCallId: String
    let toolName: String
    let toolLabel: String?
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
    let extensionOrigin: ExtensionToolOrigin?
    let extensionActivity: ExtensionRunActivity?
    let liveActivityRevision: Int?
    let extensionActivityAsOf: String?
    let groupId: String?
    let groupIndex: Int?
    let groupCount: Int?
    let groupFinalized: Bool?
    var id: String { toolCallId }

    init(
        toolCallId: String, toolName: String, toolLabel: String? = nil, order: Int? = nil, status: Status,
        arguments: JSONValue, partialResult: JSONValue?, result: JSONValue?,
        output: String? = nil, outputTruncated: Bool? = nil,
        isError: Bool, startedAt: String, updatedAt: String,
        lastProgressAt: String? = nil, completedAt: String? = nil,
        durationMs: Int? = nil, progressSequence: Int? = nil,
        extensionOrigin: ExtensionToolOrigin? = nil, extensionActivity: ExtensionRunActivity? = nil,
        liveActivityRevision: Int? = nil, extensionActivityAsOf: String? = nil,
        groupId: String? = nil, groupIndex: Int? = nil,
        groupCount: Int? = nil, groupFinalized: Bool? = nil
    ) {
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.toolLabel = toolLabel
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
        self.extensionOrigin = extensionOrigin
        self.extensionActivity = extensionActivity
        self.liveActivityRevision = liveActivityRevision
        self.extensionActivityAsOf = extensionActivityAsOf
        self.groupId = groupId
        self.groupIndex = groupIndex
        self.groupCount = groupCount
        self.groupFinalized = groupFinalized
    }

    private enum CodingKeys: String, CodingKey {
        case toolCallId, toolName, toolLabel, order, status, arguments, partialResult, result,
             output, outputTruncated, isError, startedAt, updatedAt, lastProgressAt,
             completedAt, durationMs, progressSequence, extensionOrigin, extensionActivity,
             liveActivityRevision, extensionActivityAsOf, groupId, groupIndex, groupCount, groupFinalized
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        toolCallId = try values.decode(String.self, forKey: .toolCallId)
        toolName = try values.decode(String.self, forKey: .toolName)
        toolLabel = try values.decodeIfPresent(String.self, forKey: .toolLabel)
        order = try values.decodeIfPresent(Int.self, forKey: .order)
        status = try values.decode(Status.self, forKey: .status)
        arguments = try values.decode(JSONValue.self, forKey: .arguments)
        partialResult = try values.decodeIfPresent(JSONValue.self, forKey: .partialResult)
        result = try values.decodeIfPresent(JSONValue.self, forKey: .result)
        output = try values.decodeIfPresent(String.self, forKey: .output)
        outputTruncated = try values.decodeIfPresent(Bool.self, forKey: .outputTruncated)
        isError = try values.decode(Bool.self, forKey: .isError)
        startedAt = try values.decode(String.self, forKey: .startedAt)
        updatedAt = try values.decode(String.self, forKey: .updatedAt)
        lastProgressAt = try values.decodeIfPresent(String.self, forKey: .lastProgressAt)
        completedAt = try values.decodeIfPresent(String.self, forKey: .completedAt)
        durationMs = try values.decodeIfPresent(Int.self, forKey: .durationMs)
        progressSequence = try values.decodeIfPresent(Int.self, forKey: .progressSequence)
        extensionOrigin = try values.decodeIfPresent(ExtensionToolOrigin.self, forKey: .extensionOrigin)
        extensionActivity = try values.decodeIfPresent(ExtensionRunActivity.self, forKey: .extensionActivity)
        liveActivityRevision = try values.decodeIfPresent(Int.self, forKey: .liveActivityRevision)
        extensionActivityAsOf = try values.decodeIfPresent(String.self, forKey: .extensionActivityAsOf)
        groupId = try values.decodeIfPresent(String.self, forKey: .groupId)
        groupIndex = try values.decodeIfPresent(Int.self, forKey: .groupIndex)
        groupCount = try values.decodeIfPresent(Int.self, forKey: .groupCount)
        groupFinalized = try values.decodeIfPresent(Bool.self, forKey: .groupFinalized)
        let fields = [groupId != nil, groupIndex != nil, groupCount != nil, groupFinalized != nil]
        if fields.contains(true) {
            guard fields.allSatisfy({ $0 }), let groupId, !groupId.isEmpty,
                  let groupIndex, groupIndex >= 0,
                  let groupCount, groupCount > 0, groupIndex < groupCount,
                  groupFinalized == true else {
                throw DecodingError.dataCorruptedError(
                    forKey: .groupId,
                    in: values,
                    debugDescription: "Tool execution group metadata must be complete, finalized, and in bounds"
                )
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(toolCallId, forKey: .toolCallId)
        try values.encode(toolName, forKey: .toolName)
        try values.encodeIfPresent(toolLabel, forKey: .toolLabel)
        try values.encodeIfPresent(order, forKey: .order)
        try values.encode(status, forKey: .status)
        try values.encode(arguments, forKey: .arguments)
        try values.encodeIfPresent(partialResult, forKey: .partialResult)
        try values.encodeIfPresent(result, forKey: .result)
        try values.encodeIfPresent(output, forKey: .output)
        try values.encodeIfPresent(outputTruncated, forKey: .outputTruncated)
        try values.encode(isError, forKey: .isError)
        try values.encode(startedAt, forKey: .startedAt)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encodeIfPresent(lastProgressAt, forKey: .lastProgressAt)
        try values.encodeIfPresent(completedAt, forKey: .completedAt)
        try values.encodeIfPresent(durationMs, forKey: .durationMs)
        try values.encodeIfPresent(progressSequence, forKey: .progressSequence)
        try values.encodeIfPresent(extensionOrigin, forKey: .extensionOrigin)
        try values.encodeIfPresent(extensionActivity, forKey: .extensionActivity)
        try values.encodeIfPresent(liveActivityRevision, forKey: .liveActivityRevision)
        try values.encodeIfPresent(extensionActivityAsOf, forKey: .extensionActivityAsOf)
        try values.encodeIfPresent(groupId, forKey: .groupId)
        try values.encodeIfPresent(groupIndex, forKey: .groupIndex)
        try values.encodeIfPresent(groupCount, forKey: .groupCount)
        try values.encodeIfPresent(groupFinalized, forKey: .groupFinalized)
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
    enum Kind: String, Codable, Sendable { case prompt, command, compaction, branchSummary, bash, retry }
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
    /// Gateway's bounded authoritative queue capacity. Rich queue projections
    /// exceeding this limit are invalid and must not reach row rendering.
    static let maximumQueuedMessages = 32
    /// Gateway's canonical count bound for one authoritative transcript tail.
    static let maximumTranscriptItems = 512
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
    var pendingPrompt: PendingPrompt? = nil
    var compactionQueued: Bool? = nil
    var automaticCompactionEnabled: Bool? = nil
    var transcript: [TranscriptItem]
    var transcriptStart: Int?
    var transcriptTotal: Int?
    var streaming: TranscriptItem?
    var leafEntryId: String?
    var operation: SessionOperationState?
    var extensionCommand: SessionOperationState? = nil
    var retry: RetryState?
    var toolExecutions: [ToolExecutionState]
    var extensionActivities: [ExtensionRunActivity]? = nil
    var extensionActivityOmissions: ExtensionActivityOmissions? = nil
    /// Monotonic Gateway facts for the disposable current/recent projection.
    /// Optional keeps rolling compatibility with older Gateway snapshots.
    var liveActivityRevision: Int? = nil
    var extensionActivityAsOf: String? = nil
    /// Atomic, disposable process projection. New Gateways provide both
    /// fields; older Gateways omit both and never revive the retired hub.
    var processOverview: SessionProcessOverview? = nil
    var processActivities: [SessionProcessActivity]? = nil
    var extensionPresentation: ExtensionPresentationState
    var diagnostics: [RuntimeDiagnostic]
    /// Set only on the disposable offline cache projection. Gateway snapshots
    /// leave this absent so canonical runtime state remains authoritative.
    var isCachedProjection: Bool? = nil

    struct QueuedMessages: Codable, Hashable, Sendable {
        let steering: [String]
        let followUp: [String]
    }

    struct PromptAttachment: Codable, Hashable, Identifiable, Sendable {
        let id: String
        let name: String
        let mimeType: String
        let size: Int
    }

    struct QueuedMessage: Codable, Hashable, Identifiable, Sendable {
        enum Behavior: String, Codable, Hashable, Sendable {
            case steer, followUp
        }

        let id: String
        var behavior: Behavior
        var text: String
        /// Total uploaded items retained for rolling Gateway compatibility.
        let attachmentCount: Int
        /// Optional typed counts from newer Gateways.
        var photoCount: Int? = nil
        var fileAttachmentCount: Int? = nil
        /// Optional exact descriptors from newer Gateways; payload bytes remain remote.
        var attachments: [PromptAttachment]? = nil
    }

    struct PendingPrompt: Codable, Hashable, Identifiable, Sendable {
        let id: String
        let createdAt: String?
        let behavior: QueuedMessage.Behavior?
        let text: String
        let attachmentCount: Int
        var photoCount: Int? = nil
        var fileAttachmentCount: Int? = nil
        /// Optional exact descriptors from newer Gateways; payload bytes remain remote.
        var attachments: [PromptAttachment]? = nil
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

enum SessionTreePolicy {
    static let maximumNodes = 1_000
    static let maximumStringBytes = 8_192
    static let maximumTimestampBytes = 64
    static let maximumEncodedBytes = 700_000

    static func admit(_ nodes: [SessionTreeNode]) throws -> [SessionTreeNode] {
        guard nodes.count <= maximumNodes else { throw invalidTree() }
        var identities = Set<String>()
        identities.reserveCapacity(nodes.count)
        for node in nodes {
            guard !node.id.isEmpty,
                  node.id.utf8.count <= maximumStringBytes,
                  node.parentId.map({ !$0.isEmpty && $0.utf8.count <= maximumStringBytes }) ?? true,
                  !node.timestamp.isEmpty,
                  node.timestamp.utf8.count <= maximumTimestampBytes,
                  GatewayTimestamp.parse(node.timestamp) != nil,
                  !node.kind.isEmpty,
                  node.kind.utf8.count <= maximumStringBytes,
                  node.label.map({ !$0.isEmpty && $0.utf8.count <= maximumStringBytes }) ?? true,
                  node.preview.utf8.count <= maximumStringBytes,
                  node.depth >= 0,
                  node.childCount >= 0,
                  identities.insert(node.id).inserted else {
                throw invalidTree()
            }
        }
        guard let encoded = try? JSONEncoder.gateway.encode(nodes),
              encoded.count <= maximumEncodedBytes else {
            throw invalidTree()
        }
        return nodes
    }

    private static func invalidTree() -> GatewayFailure {
        GatewayFailure(
            code: "invalid_response",
            message: "The session tree from the Mac is invalid or too large.",
            retryable: true,
            details: nil
        )
    }
}
