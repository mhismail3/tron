import Foundation

package struct ModelRef: Codable, Hashable, Sendable, Identifiable {
    package let provider: String
    package let id: String
    package var contextWindowKey: String { "\(provider)/\(id)" }

    package init(provider: String, id: String) {
        self.provider = provider
        self.id = id
    }
}

package struct ContextUsage: Codable, Hashable, Sendable {
    package let tokens: Int?
    package let contextWindow: Int
    package let percent: Double?
}

package struct ExtensionRunChild: Codable, Hashable, Identifiable, Sendable {
    package enum Status: String, Codable, Sendable { case running, completed, failed }
    package let id: String
    package let label: String
    package let status: Status
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
    package let children: [ExtensionRunChild]?

    var displayStateName: String {
        if let lifecycle { return lifecycle.displayName }
        return switch status {
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }

    package init(id: String, label: String, status: Status, lifecycle: ExtensionActivityLifecycleState? = nil,
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

package struct ExtensionRunActivity: Codable, Hashable, Identifiable, Sendable {
    package enum Status: String, Codable, Sendable { case running, completed, failed }
    package let id: String
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
    package let lifecycle: ExtensionActivityLifecycle?

    package var stableID: String { activityId ?? id }
    package var isLive: Bool { lifecycle?.state.isCurrent ?? (status == .running) }
    var displayStateName: String {
        if let lifecycle { return lifecycle.state.displayName }
        return switch status {
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }

    package init(
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

    package init(from decoder: Decoder) throws {
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

    package func encode(to encoder: Encoder) throws {
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

package struct ExtensionActivityDelta: Codable, Hashable, Sendable {
    package let activity: ExtensionRunActivity
    package let liveActivityRevision: Int
    package let extensionActivityAsOf: String
}

/// Device-local receipt time for a Gateway duration sample. It deliberately has
/// no value identity and is excluded from Codable so authoritative snapshots,
/// caches, and protocol round trips remain unchanged.
package struct ToolDurationSampleAnchor: Hashable, Sendable {
    package let uptime: TimeInterval

    package init(uptime: TimeInterval) {
        self.uptime = uptime
    }

    package func advancing(_ milliseconds: Int, toUptime currentUptime: TimeInterval) -> Int {
        let baseline = max(0, milliseconds)
        let delta = (currentUptime - uptime) * 1_000
        guard delta.isFinite, delta > 0 else { return baseline }
        let rounded = delta.rounded()
        guard rounded < Double(Int.max - baseline) else { return Int.max }
        return baseline + Int(rounded)
    }

    package static func == (_: Self, _: Self) -> Bool { true }
    package func hash(into _: inout Hasher) {}
}

package struct ToolExecutionState: Codable, Hashable, Identifiable, Sendable {
    package enum Status: String, Codable, Sendable { case running, completed, failed }
    package let toolCallId: String
    package let toolName: String
    package let toolLabel: String?
    package let order: Int?
    package let status: Status
    package let arguments: JSONValue
    package let partialResult: JSONValue?
    package let result: JSONValue?
    package let nestedCalls: JSONValue?
    package let output: String?
    package let outputTruncated: Bool?
    package let isError: Bool
    package let startedAt: String
    package let updatedAt: String
    package let lastProgressAt: String?
    package let completedAt: String?
    package let durationMs: Int?
    package let durationSampleAnchor: ToolDurationSampleAnchor
    package let progressSequence: Int?
    package let extensionOrigin: ExtensionToolOrigin?
    package let extensionActivity: ExtensionRunActivity?
    package let liveActivityRevision: Int?
    package let extensionActivityAsOf: String?
    package let toolSegmentId: String?
    package let groupId: String?
    package let groupIndex: Int?
    package let groupCount: Int?
    package let groupFinalized: Bool?
    package var id: String { toolCallId }

    package init(
        toolCallId: String, toolName: String, toolLabel: String? = nil, order: Int? = nil, status: Status,
        arguments: JSONValue, partialResult: JSONValue?, result: JSONValue?, nestedCalls: JSONValue? = nil,
        output: String? = nil, outputTruncated: Bool? = nil,
        isError: Bool, startedAt: String, updatedAt: String,
        lastProgressAt: String? = nil, completedAt: String? = nil,
        durationMs: Int? = nil,
        durationSampleAnchor: ToolDurationSampleAnchor = ToolDurationSampleAnchor(
            uptime: ProcessInfo.processInfo.systemUptime
        ),
        progressSequence: Int? = nil,
        extensionOrigin: ExtensionToolOrigin? = nil, extensionActivity: ExtensionRunActivity? = nil,
        liveActivityRevision: Int? = nil, extensionActivityAsOf: String? = nil,
        toolSegmentId: String? = nil, groupId: String? = nil, groupIndex: Int? = nil,
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
        self.nestedCalls = nestedCalls
        self.output = output
        self.outputTruncated = outputTruncated
        self.isError = isError
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.lastProgressAt = lastProgressAt
        self.completedAt = completedAt
        self.durationMs = durationMs
        self.durationSampleAnchor = durationSampleAnchor
        self.progressSequence = progressSequence
        self.extensionOrigin = extensionOrigin
        self.extensionActivity = extensionActivity
        self.liveActivityRevision = liveActivityRevision
        self.extensionActivityAsOf = extensionActivityAsOf
        self.toolSegmentId = toolSegmentId
        self.groupId = groupId
        self.groupIndex = groupIndex
        self.groupCount = groupCount
        self.groupFinalized = groupFinalized
    }

    private enum CodingKeys: String, CodingKey {
        case toolCallId, toolName, toolLabel, order, status, arguments, partialResult, result, nestedCalls,
             output, outputTruncated, isError, startedAt, updatedAt, lastProgressAt,
             completedAt, durationMs, progressSequence, extensionOrigin, extensionActivity,
             liveActivityRevision, extensionActivityAsOf, toolSegmentId,
             groupId, groupIndex, groupCount, groupFinalized
    }

    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        toolCallId = try values.decode(String.self, forKey: .toolCallId)
        toolName = try values.decode(String.self, forKey: .toolName)
        toolLabel = try values.decodeIfPresent(String.self, forKey: .toolLabel)
        order = try values.decodeIfPresent(Int.self, forKey: .order)
        status = try values.decode(Status.self, forKey: .status)
        arguments = try values.decode(JSONValue.self, forKey: .arguments)
        partialResult = try values.decodeIfPresent(JSONValue.self, forKey: .partialResult)
        result = try values.decodeIfPresent(JSONValue.self, forKey: .result)
        nestedCalls = try values.decodeIfPresent(JSONValue.self, forKey: .nestedCalls)
        output = try values.decodeIfPresent(String.self, forKey: .output)
        outputTruncated = try values.decodeIfPresent(Bool.self, forKey: .outputTruncated)
        isError = try values.decode(Bool.self, forKey: .isError)
        startedAt = try values.decode(String.self, forKey: .startedAt)
        updatedAt = try values.decode(String.self, forKey: .updatedAt)
        lastProgressAt = try values.decodeIfPresent(String.self, forKey: .lastProgressAt)
        completedAt = try values.decodeIfPresent(String.self, forKey: .completedAt)
        durationMs = try values.decodeIfPresent(Int.self, forKey: .durationMs)
        durationSampleAnchor = ToolDurationSampleAnchor(
            uptime: ProcessInfo.processInfo.systemUptime
        )
        progressSequence = try values.decodeIfPresent(Int.self, forKey: .progressSequence)
        extensionOrigin = try values.decodeIfPresent(ExtensionToolOrigin.self, forKey: .extensionOrigin)
        extensionActivity = try values.decodeIfPresent(ExtensionRunActivity.self, forKey: .extensionActivity)
        liveActivityRevision = try values.decodeIfPresent(Int.self, forKey: .liveActivityRevision)
        extensionActivityAsOf = try values.decodeIfPresent(String.self, forKey: .extensionActivityAsOf)
        toolSegmentId = try values.decodeIfPresent(String.self, forKey: .toolSegmentId)
        if let toolSegmentId, toolSegmentId.isEmpty {
            throw DecodingError.dataCorruptedError(
                forKey: .toolSegmentId,
                in: values,
                debugDescription: "Tool segment identity must be nonempty"
            )
        }
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

    package func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(toolCallId, forKey: .toolCallId)
        try values.encode(toolName, forKey: .toolName)
        try values.encodeIfPresent(toolLabel, forKey: .toolLabel)
        try values.encodeIfPresent(order, forKey: .order)
        try values.encode(status, forKey: .status)
        try values.encode(arguments, forKey: .arguments)
        try values.encodeIfPresent(partialResult, forKey: .partialResult)
        try values.encodeIfPresent(result, forKey: .result)
        try values.encodeIfPresent(nestedCalls, forKey: .nestedCalls)
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
        try values.encodeIfPresent(toolSegmentId, forKey: .toolSegmentId)
        try values.encodeIfPresent(groupId, forKey: .groupId)
        try values.encodeIfPresent(groupIndex, forKey: .groupIndex)
        try values.encodeIfPresent(groupCount, forKey: .groupCount)
        try values.encodeIfPresent(groupFinalized, forKey: .groupFinalized)
    }
}

package struct RetryState: Codable, Hashable, Sendable {
    enum Source: String, Codable, Sendable { case agent, compaction, branchSummary }
    let source: Source
    let attempt: Int
    let maxAttempts: Int?
    let delayMs: Int?
    let errorMessage: String?
}

package enum InvocationLifecycle: String, Codable, Sendable {
    case staged, accepted, running, waitingForInput, queued, retrying, settling, completed, failed, interrupted, outcomeUnknown
}
package struct SessionOperationState: Codable, Hashable, Sendable {
    package enum Kind: String, Codable, Sendable { case prompt, command, compaction, branchSummary, bash, retry }
    package let id: String?
    package let kind: Kind
    let startedAt: String
    let reason: String?
    let invocationId: String?
    let lifecycle: InvocationLifecycle?
    init(id: String? = nil, kind: Kind, startedAt: String, reason: String? = nil, invocationId: String? = nil, lifecycle: InvocationLifecycle? = nil) {
        self.id = id; self.kind = kind; self.startedAt = startedAt; self.reason = reason
        self.invocationId = invocationId; self.lifecycle = lifecycle
    }
}

package struct RuntimeDiagnostic: Codable, Hashable, Sendable {
    package let type: String
    package let message: String
}

package struct SessionStats: Codable, Hashable, Sendable {
    package struct Tokens: Codable, Hashable, Sendable {
        package let input: Int
        package let output: Int
        package let cacheRead: Int
        package let cacheWrite: Int
        let total: Int

        package init(input: Int, output: Int, cacheRead: Int, cacheWrite: Int, total: Int) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
            self.total = total
        }
    }
    let userMessages: Int
    package let assistantMessages: Int
    package let toolCalls: Int
    let toolResults: Int
    package let totalMessages: Int
    package let tokens: Tokens
    package let latestCacheHitRate: Double?
    package let cost: Double

    package init(userMessages: Int, assistantMessages: Int, toolCalls: Int, toolResults: Int, totalMessages: Int, tokens: Tokens, latestCacheHitRate: Double?, cost: Double) {
        self.userMessages = userMessages
        self.assistantMessages = assistantMessages
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.totalMessages = totalMessages
        self.tokens = tokens
        self.latestCacheHitRate = latestCacheHitRate
        self.cost = cost
    }
}

package struct ContextWindowPolicy: Codable, Hashable, Sendable {
    package let model: ModelRef
    package let minimum: Int
    package let maximum: Int
    package let `default`: Int
    package let effective: Int
    package let override: Int?
    package let source: String
    package let warning: String?
}

package struct CompactionConfiguration: Codable, Hashable, Sendable {
    let enabled: Bool
    package let reserveTokens: Int
    package let keepRecentTokens: Int
    let thinkingLevel: String
    package let instructions: String
    let source: [String: String]
    package let model: ModelRef?
    package let requestedThinkingLevel: String
    package let effectiveThinkingLevel: String?
    let reason: String?

    package init(
        enabled: Bool, reserveTokens: Int, keepRecentTokens: Int, thinkingLevel: String,
        instructions: String, source: [String: String], model: ModelRef?, requestedThinkingLevel: String,
        effectiveThinkingLevel: String?, reason: String?
    ) {
        self.enabled = enabled
        self.reserveTokens = reserveTokens
        self.keepRecentTokens = keepRecentTokens
        self.thinkingLevel = thinkingLevel
        self.instructions = instructions
        self.source = source
        self.model = model
        self.requestedThinkingLevel = requestedThinkingLevel
        self.effectiveThinkingLevel = effectiveThinkingLevel
        self.reason = reason
    }

    var isValid: Bool {
        let levels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
        return (1_024...1_000_000).contains(reserveTokens)
            && (0...1_000_000).contains(keepRecentTokens)
            && (thinkingLevel == "inherit" || levels.contains(thinkingLevel))
            && levels.contains(requestedThinkingLevel)
            && (effectiveThinkingLevel.map { levels.contains($0) } ?? (model == nil))
            && instructions.utf16.count <= 4_000
            && Set(source.keys) == Set(["enabled", "reserveTokens", "keepRecentTokens", "thinkingLevel", "instructions"])
            && source.values.allSatisfy { ["global", "project", "default"].contains($0) }
    }
}

package struct CompactionPolicyProjection: Codable, Hashable, Sendable {
    package struct Budgets: Codable, Hashable, Sendable {
        package let enabled: Bool
        package let reserveTokens: Int
        package let keepRecentTokens: Int

        package init(enabled: Bool, reserveTokens: Int, keepRecentTokens: Int) {
            self.enabled = enabled
            self.reserveTokens = reserveTokens
            self.keepRecentTokens = keepRecentTokens
        }
    }
    package let next: CompactionConfiguration
    package let currentBudgets: Budgets
    package let active: CompactionConfiguration?
    package let extensionMayOverride: Bool
    package let warning: String?

    package init(
        next: CompactionConfiguration, currentBudgets: Budgets, active: CompactionConfiguration?,
        extensionMayOverride: Bool, warning: String?
    ) {
        self.next = next
        self.currentBudgets = currentBudgets
        self.active = active
        self.extensionMayOverride = extensionMayOverride
        self.warning = warning
    }
}

package struct ComposerResourceInvocation: Codable, Equatable, Hashable, Sendable {
    package enum Source: String, Codable, Sendable { case skill, prompt, `extension` }
    static let maximumNameBytes = 512
    package static let maximumArgumentBytes = 5_000

    package let source: Source
    package let name: String
    package let arguments: String

    package var isExtensionCommand: Bool { source == .extension }

    package init(source: Source, name: String, arguments: String) {
        self.source = source
        self.name = name
        self.arguments = arguments
    }
    package var isTransportValid: Bool {
        !name.isEmpty
            && name.utf8.count <= Self.maximumNameBytes
            && !name.contains(where: \.isWhitespace)
            && arguments.utf8.count <= Self.maximumArgumentBytes
            && !arguments.unicodeScalars.contains(where: { scalar in
                (scalar.value < 0x20 && ![0x09, 0x0a, 0x0d].contains(scalar.value))
                    || scalar.value == 0x7f
            })
    }
}

package struct SessionSnapshot: Codable, Hashable, Sendable {
    /// Gateway's bounded authoritative queue capacity. Rich queue projections
    /// exceeding this limit are invalid and must not reach row rendering.
    package static let maximumQueuedMessages = 32
    /// Gateway's canonical count bound for one authoritative transcript tail.
    package static let maximumTranscriptItems = 512
    package var sessionId: String
    package var runtimeGeneration: String
    package var revision: Int
    package var eventSequence: Int
    package var phase: SessionPhase
    /// Exact Gateway/Pi admission capability. Older compatible snapshots omit
    /// it and use the conservative running-phase fallback at presentation.
    package var acceptsQueuedPrompts: Bool? = nil
    /// Disposable Gateway annotation for the inherited-to-child transition.
    package var forkBoundary: TranscriptForkBoundary? = nil
    package var name: String?
    package var cwd: String
    var parentSessionId: String?
    package var model: ModelRef?
    package var thinkingLevel: String
    package var availableThinkingLevels: [String]
    package var contextUsage: ContextUsage?
    package var stats: SessionStats
    package var queueRevision: Int
    package var queuedItems: [QueuedMessage]
    package var pendingPrompt: PendingPrompt? = nil
    package var compactionQueued: Bool? = nil
    var automaticCompactionEnabled: Bool
    package var transcript: [TranscriptItem]
    package var transcriptStart: Int?
    package var transcriptTotal: Int?
    package var streaming: TranscriptItem?
    package var leafEntryId: String?
    package var operation: SessionOperationState?
    var retry: RetryState?
    /// Exact Gateway-owned segment authority for the running streaming agent;
    /// a barrier generation may match no declaration yet. Older compatible
    /// Gateways omit it and retain phase-based presentation.
    package var activeToolSegmentId: String? = nil
    package var toolExecutions: [ToolExecutionState]
    package var extensionActivities: [ExtensionRunActivity]? = nil
    var extensionActivityOmissions: ExtensionActivityOmissions? = nil
    /// Monotonic Gateway facts for the disposable current/recent projection.
    package var liveActivityRevision: Int? = nil
    package var extensionActivityAsOf: String? = nil
    /// Atomic, disposable process projection.
    package var processOverview: SessionProcessOverview? = nil
    package var processActivities: [SessionProcessActivity]? = nil
    package var extensionPresentation: ExtensionPresentationState
    var diagnostics: [RuntimeDiagnostic]
    /// Set only on the disposable offline cache projection. Gateway snapshots
    /// leave this absent so canonical runtime state remains authoritative.
    package var isCachedProjection: Bool? = nil
    /// Optional on rolling gateways that do not advertise context-window.v1.
    package var contextWindowPolicy: ContextWindowPolicy? = nil
    package var compactionPolicy: CompactionPolicyProjection? = nil
    /// Gateway archive projection for this exact session: present while it is
    /// archived, absent while it is visible. The Gateway republishes the
    /// snapshot on an archive change, so an open chat never infers it.
    var archivedAt: String? = nil

    package init(
        sessionId: String, runtimeGeneration: String, revision: Int, eventSequence: Int, phase: SessionPhase,
        acceptsQueuedPrompts: Bool? = nil, forkBoundary: TranscriptForkBoundary? = nil, name: String?,
        cwd: String, parentSessionId: String?, model: ModelRef?, thinkingLevel: String,
        availableThinkingLevels: [String], contextUsage: ContextUsage?, stats: SessionStats,
        queueRevision: Int, queuedItems: [QueuedMessage], pendingPrompt: PendingPrompt? = nil,
        compactionQueued: Bool? = nil, automaticCompactionEnabled: Bool, transcript: [TranscriptItem],
        transcriptStart: Int?, transcriptTotal: Int?, streaming: TranscriptItem?, leafEntryId: String?,
        operation: SessionOperationState?, retry: RetryState?, activeToolSegmentId: String? = nil,
        toolExecutions: [ToolExecutionState], extensionActivities: [ExtensionRunActivity]? = nil,
        extensionActivityOmissions: ExtensionActivityOmissions? = nil, liveActivityRevision: Int? = nil,
        extensionActivityAsOf: String? = nil, processOverview: SessionProcessOverview? = nil,
        processActivities: [SessionProcessActivity]? = nil, extensionPresentation: ExtensionPresentationState,
        diagnostics: [RuntimeDiagnostic], isCachedProjection: Bool? = nil,
        contextWindowPolicy: ContextWindowPolicy? = nil, compactionPolicy: CompactionPolicyProjection? = nil,
        archivedAt: String? = nil
    ) {
        self.sessionId = sessionId
        self.runtimeGeneration = runtimeGeneration
        self.revision = revision
        self.eventSequence = eventSequence
        self.phase = phase
        self.acceptsQueuedPrompts = acceptsQueuedPrompts
        self.forkBoundary = forkBoundary
        self.name = name
        self.cwd = cwd
        self.parentSessionId = parentSessionId
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.availableThinkingLevels = availableThinkingLevels
        self.contextUsage = contextUsage
        self.stats = stats
        self.queueRevision = queueRevision
        self.queuedItems = queuedItems
        self.pendingPrompt = pendingPrompt
        self.compactionQueued = compactionQueued
        self.automaticCompactionEnabled = automaticCompactionEnabled
        self.transcript = transcript
        self.transcriptStart = transcriptStart
        self.transcriptTotal = transcriptTotal
        self.streaming = streaming
        self.leafEntryId = leafEntryId
        self.operation = operation
        self.retry = retry
        self.activeToolSegmentId = activeToolSegmentId
        self.toolExecutions = toolExecutions
        self.extensionActivities = extensionActivities
        self.extensionActivityOmissions = extensionActivityOmissions
        self.liveActivityRevision = liveActivityRevision
        self.extensionActivityAsOf = extensionActivityAsOf
        self.processOverview = processOverview
        self.processActivities = processActivities
        self.extensionPresentation = extensionPresentation
        self.diagnostics = diagnostics
        self.isCachedProjection = isCachedProjection
        self.contextWindowPolicy = contextWindowPolicy
        self.compactionPolicy = compactionPolicy
        self.archivedAt = archivedAt
    }

    package struct PromptAttachment: Codable, Hashable, Identifiable, Sendable {
        package let id: String
        package let name: String
        package let mimeType: String
        package let size: Int

        package init(id: String, name: String, mimeType: String, size: Int) {
            self.id = id
            self.name = name
            self.mimeType = mimeType
            self.size = size
        }
    }

    package struct QueuedMessage: Codable, Hashable, Identifiable, Sendable {
        package enum Behavior: String, Codable, Hashable, Sendable {
            case steer, followUp
        }

        package let id: String
        package var behavior: Behavior
        package var text: String
        /// Total uploaded items represented by this queued prompt.
        package let attachmentCount: Int
        package var photoCount: Int? = nil
        package var fileAttachmentCount: Int? = nil
        /// Optional exact descriptors from newer Gateways; payload bytes remain remote.
        package var attachments: [PromptAttachment]? = nil
        package var resourceInvocation: ComposerResourceInvocation? = nil

        package init(
            id: String, behavior: Behavior, text: String, attachmentCount: Int,
            photoCount: Int? = nil, fileAttachmentCount: Int? = nil, attachments: [PromptAttachment]? = nil,
            resourceInvocation: ComposerResourceInvocation? = nil
        ) {
            self.id = id
            self.behavior = behavior
            self.text = text
            self.attachmentCount = attachmentCount
            self.photoCount = photoCount
            self.fileAttachmentCount = fileAttachmentCount
            self.attachments = attachments
            self.resourceInvocation = resourceInvocation
        }
    }

    package struct PendingPrompt: Codable, Hashable, Identifiable, Sendable {
        package let id: String
        package let createdAt: String?
        package let behavior: QueuedMessage.Behavior?
        package let text: String
        package let attachmentCount: Int
        package var photoCount: Int? = nil
        package var fileAttachmentCount: Int? = nil
        /// Optional exact descriptors from newer Gateways; payload bytes remain remote.
        package var attachments: [PromptAttachment]? = nil
        package var resourceInvocation: ComposerResourceInvocation? = nil

        package init(
            id: String, createdAt: String?, behavior: QueuedMessage.Behavior?, text: String,
            attachmentCount: Int, photoCount: Int? = nil, fileAttachmentCount: Int? = nil,
            attachments: [PromptAttachment]? = nil, resourceInvocation: ComposerResourceInvocation? = nil
        ) {
            self.id = id
            self.createdAt = createdAt
            self.behavior = behavior
            self.text = text
            self.attachmentCount = attachmentCount
            self.photoCount = photoCount
            self.fileAttachmentCount = fileAttachmentCount
            self.attachments = attachments
            self.resourceInvocation = resourceInvocation
        }
    }

    package var displayedQueuedMessages: [QueuedMessage] { queuedItems }
}

package enum SessionSnapshotTranscriptAdmissionPolicy {
    static let maximumItemIdentityUTF8Bytes = 512

    package static func admit(_ snapshot: SessionSnapshot) -> Bool {
        guard admitsContextWindowPolicy(snapshot),
              admitsCompactionPolicy(snapshot),
              admitsItems(snapshot.transcript),
              snapshot.streaming.map(admitsItem) ?? true,
              snapshot.activeToolSegmentId.map({
                  !$0.isEmpty && $0.utf8.count <= maximumItemIdentityUTF8Bytes
                      && snapshot.phase == .running
                      && snapshot.acceptsQueuedPrompts != false
              }) ?? true else { return false }
        switch (snapshot.transcriptStart, snapshot.transcriptTotal) {
        case (nil, nil):
            // Legacy/test projections without paging metadata remain valid. A
            // partial pair cannot establish a canonical range.
            return true
        case let (start?, total?):
            guard start >= 0, total >= start else { return false }
            let (end, overflow) = start.addingReportingOverflow(snapshot.transcript.count)
            return !overflow && end == total
        default:
            return false
        }
    }

    package static func admitsPage(_ items: [TranscriptItem]) -> Bool {
        admitsItems(items)
    }

    package static func admitsItem(_ item: TranscriptItem) -> Bool {
        !item.id.isEmpty && item.id.utf8.count <= maximumItemIdentityUTF8Bytes
    }

    private static func admitsCompactionPolicy(_ snapshot: SessionSnapshot) -> Bool {
        guard let policy = snapshot.compactionPolicy else { return true }
        guard policy.next.isValid, policy.next.model == snapshot.model,
              (1_024...1_000_000).contains(policy.currentBudgets.reserveTokens),
              (0...1_000_000).contains(policy.currentBudgets.keepRecentTokens),
              policy.warning.map({ $0.utf8.count <= 4_096 }) ?? true else { return false }
        guard let active = policy.active else { return true }
        // The SDK can admit the successor Agent turn before compaction_end;
        // active is still authoritative during that running handoff. It must
        // not survive into an idle/settled frame.
        return active.isValid && ["manual", "threshold", "overflow"].contains(active.reason ?? "")
            && (snapshot.phase == .compacting || snapshot.phase == .retrying || snapshot.phase == .running)
    }

    private static func admitsContextWindowPolicy(_ snapshot: SessionSnapshot) -> Bool {
        guard let policy = snapshot.contextWindowPolicy else { return true }
        // Saved overrides may be outside today's capacity after a catalog change.
        // They are displayed with the server's adjustment warning, not discarded
        // along with the authoritative transcript. Effective is the actual live
        // budget, which can briefly precede application of refreshed metadata.
        guard policy.model == snapshot.model,
              !policy.model.provider.isEmpty, policy.model.provider.utf8.count <= 480,
              !policy.model.id.isEmpty, policy.model.id.utf8.count <= 1_200,
              policy.minimum > 0, policy.maximum >= policy.minimum, policy.maximum <= 100_000_000,
              policy.default >= policy.minimum, policy.default <= policy.maximum,
              policy.effective > 0, policy.effective <= 100_000_000,
              policy.override == nil || (policy.override! > 0 && policy.override! <= 100_000_000),
              ["model", "global", "project", "session"].contains(policy.source),
              (policy.source == "session") == (policy.override != nil),
              snapshot.contextUsage == nil || snapshot.contextUsage?.contextWindow == policy.effective else { return false }
        if let warning = policy.warning { return warning.utf8.count <= 4_096 }
        return true
    }

    private static func admitsItems(_ items: [TranscriptItem]) -> Bool {
        guard items.count <= SessionSnapshot.maximumTranscriptItems,
              items.allSatisfy(admitsItem) else { return false }
        return Set(items.map(\.id)).count == items.count
    }
}

package enum SessionSnapshotQueueAdmissionPolicy {
    package static func admit(_ snapshot: SessionSnapshot) -> Bool {
        let displayed = snapshot.displayedQueuedMessages
        guard displayed.count <= SessionSnapshot.maximumQueuedMessages else { return false }
        let ids = displayed.map(\.id)
        guard ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else { return false }
        guard displayed.allSatisfy({ message in
            admits(
                message.resourceInvocation,
                text: message.text,
                attachmentCount: message.attachmentCount
            )
        }) else { return false }
        guard let pending = snapshot.pendingPrompt else { return true }
        return admits(
            pending.resourceInvocation,
            text: pending.text,
            attachmentCount: pending.attachmentCount
        )
    }

    private static func admits(
        _ resource: ComposerResourceInvocation?,
        text: String,
        attachmentCount: Int
    ) -> Bool {
        guard attachmentCount >= 0 else { return false }
        guard let resource else { return true }
        guard resource.arguments == text, resource.isTransportValid else { return false }
        // Extension commands execute immediately and never belong to prompt queue state.
        return resource.source != .extension
    }
}

/// Narrow, immutable facts used by Manage Session. Streaming transcript content
/// is deliberately absent so its publication cannot invalidate that surface.
package struct SessionContextPresentation: Hashable, Sendable {
    package let runtimeGeneration: String
    package let sessionID: String
    package let phase: SessionPhase
    package let operationKind: SessionOperationState.Kind?
    package let compactionQueued: Bool
    package let contextUsage: ContextUsage?
    package let stats: SessionStats
    package let lastTranscriptKind: TranscriptItem.Kind?
    package let automaticCompactionEnabled: Bool
    package let processOverview: SessionProcessOverview?
    package let model: ModelRef?
    package let thinkingLevel: String
    package let availableThinkingLevels: [String]
    package let name: String?
    package let cwd: String
    package let diagnostics: [RuntimeDiagnostic]
    package let contextWindowPolicy: ContextWindowPolicy?
    /// Gateway-owned archive state, so Manage Session needs no second read.
    package let archivedAt: String?

    package init(_ snapshot: SessionSnapshot) {
        runtimeGeneration = snapshot.runtimeGeneration
        sessionID = snapshot.sessionId
        phase = snapshot.phase
        operationKind = snapshot.operation?.kind
        compactionQueued = snapshot.compactionQueued == true
        contextUsage = snapshot.contextUsage
        stats = snapshot.stats
        lastTranscriptKind = snapshot.transcript.last?.kind
        automaticCompactionEnabled = snapshot.automaticCompactionEnabled
        processOverview = snapshot.processOverview
        model = snapshot.model
        thinkingLevel = snapshot.thinkingLevel
        availableThinkingLevels = snapshot.availableThinkingLevels
        name = snapshot.name
        cwd = snapshot.cwd
        diagnostics = snapshot.diagnostics
        contextWindowPolicy = snapshot.contextWindowPolicy
        archivedAt = snapshot.archivedAt
    }
}

package struct SessionEventEnvelope: Codable, Hashable, Sendable {
    package let runtimeGeneration: String
    package let eventSequence: Int
    package let revision: Int
    package let data: JSONValue
}

package struct SessionTreeNode: Codable, Hashable, Identifiable, Sendable {
    package var bookmarkTargetId: String? = nil
    package let id: String
    let parentId: String?
    package let timestamp: String
    package let kind: String
    package let label: String?
    package let preview: String
    package let role: TranscriptItem.Role?
    let depth: Int
    package let childCount: Int
    package let isCurrentPath: Bool

    package init(
        bookmarkTargetId: String? = nil, id: String, parentId: String?, timestamp: String,
        kind: String, label: String?, preview: String, role: TranscriptItem.Role?, depth: Int,
        childCount: Int, isCurrentPath: Bool
    ) {
        self.bookmarkTargetId = bookmarkTargetId
        self.id = id
        self.parentId = parentId
        self.timestamp = timestamp
        self.kind = kind
        self.label = label
        self.preview = preview
        self.role = role
        self.depth = depth
        self.childCount = childCount
        self.isCurrentPath = isCurrentPath
    }
}

package enum SessionTreePolicy {
    static let maximumNodes = 1_000
    static let maximumStringBytes = 8_192
    static let maximumTimestampBytes = 64
    static let maximumEncodedBytes = 700_000

    package static func admit(_ nodes: [SessionTreeNode]) throws -> [SessionTreeNode] {
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
                  node.bookmarkTargetId.map({ !$0.isEmpty && $0.utf8.count <= maximumStringBytes }) ?? true,
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
