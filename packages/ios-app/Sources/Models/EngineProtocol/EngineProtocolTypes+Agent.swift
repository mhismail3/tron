import Foundation

// MARK: - Agent Methods

struct AgentPromptParams: Encodable {
    let sessionId: String
    let prompt: String
    let images: [ImageAttachment]?
    let attachments: [FileAttachment]?
    let reasoningLevel: String?

    init(
        sessionId: String,
        prompt: String,
        images: [ImageAttachment]? = nil,
        attachments: [FileAttachment]? = nil,
        reasoningLevel: String? = nil
    ) {
        self.sessionId = sessionId
        self.prompt = prompt
        self.images = images
        self.attachments = attachments
        self.reasoningLevel = reasoningLevel
    }
}

// MARK: - Session-Scoped Skill engine protocols

struct SkillActivateParams: Encodable {
    let sessionId: String
    let skillName: String
}

struct SkillDeactivateParams: Encodable {
    let sessionId: String
    let skillName: String
}

struct SkillActiveParams: Encodable {
    let sessionId: String
}

struct SkillActivateResult: Decodable {
    let success: Bool
    let skill: SkillActivateInfo?

    struct SkillActivateInfo: Decodable {
        let name: String
        let source: String
        /// Service folder that produced the skill (`"tron"`, `"claude"`, …).
        let service: String
    }
}

struct SkillDeactivateResult: Decodable {
    let success: Bool
    let deactivatedSkill: String?
}

struct SkillActiveResult: Decodable {
    let skills: [ActiveSkillInfo]

    struct ActiveSkillInfo: Decodable {
        let name: String
        let source: String
        /// Service folder that produced the skill (`"tron"`, `"claude"`, …).
        let service: String
    }
}

struct ImageAttachment: Encodable {
    let data: String  // base64 encoded
    let mimeType: String

    init(data: Data, mimeType: String = "image/jpeg") {
        self.data = data.base64EncodedString()
        self.mimeType = mimeType
    }
}

/// Unified file attachment for images, PDFs, and documents
struct FileAttachment: Encodable {
    let data: String  // base64 encoded
    let mimeType: String
    let fileName: String?

    init(data: Data, mimeType: String, fileName: String? = nil) {
        self.data = data.base64EncodedString()
        self.mimeType = mimeType
        self.fileName = fileName
    }

    /// Create from an Attachment model
    init(attachment: Attachment) {
        self.data = attachment.data.base64EncodedString()
        self.mimeType = attachment.mimeType
        self.fileName = attachment.fileName
    }
}

struct AgentPromptResult: Decodable {
    let acknowledged: Bool
}

struct AgentAbortParams: Encodable {
    let sessionId: String
}

struct AgentAbortInvocationParams: Encodable {
    let sessionId: String
    let invocationId: String
}

struct AgentAbortInvocationResult: Decodable {
    let aborted: Bool
}

// MARK: - Work Snapshot

struct AgentWorkSnapshotParams: Encodable {
    let sessionId: String?
    let workspaceId: String?
    let limit: Int
}

struct WorkSnapshotDTO: Decodable, Equatable {
    let autonomy: WorkAutonomyDTO
    let activeWork: [WorkActiveItemDTO]
    let workers: [WorkWorkerDTO]
    let recentMilestones: [WorkMilestoneDTO]
    let guardrails: [WorkGuardrailDTO]
    let auditRefs: [WorkAuditRefDTO]
    let scope: WorkScopeDTO?
}

struct WorkAutonomyDTO: Decodable, Equatable {
    let mode: String
    let approvalPromptMode: String
    let interactiveApprovalPrompts: Bool
    let statusLabel: String
    let summary: String
}

struct WorkActiveItemDTO: Decodable, Equatable, Identifiable {
    let kind: String
    let status: String
    let functionId: String?
    let approvalId: String?
    let traceId: String?

    var id: String {
        approvalId ?? traceId ?? [kind, status, functionId].compactMap { $0 }.joined(separator: ":")
    }
}

struct WorkWorkerDTO: Decodable, Equatable, Identifiable {
    let workerId: String
    let label: String
    let status: String
    let health: String
    let abilityCount: Int
    let abilities: [WorkAbilityDTO]
    let namespaceClaims: [String]
    let workerType: String?
    let runId: String?
    let elapsedMs: UInt64?
    let auditRef: WorkAuditRefDTO?

    var id: String { workerId }
}

struct WorkAbilityDTO: Decodable, Equatable, Identifiable {
    let functionId: String
    let label: String
    let risk: String
    let effect: String
    let health: String

    var id: String { functionId }
}

struct WorkMilestoneDTO: Decodable, Equatable, Identifiable {
    let kind: String
    let status: String
    let functionId: String?
    let workerId: String?
    let invocationId: String?
    let traceId: String?
    let auditRef: WorkAuditRefDTO?

    var id: String {
        invocationId ?? traceId ?? [kind, status, functionId, workerId].compactMap { $0 }.joined(separator: ":")
    }
}

struct WorkGuardrailDTO: Decodable, Equatable, Identifiable {
    let kind: String
    let status: String
    let functionId: String?
    let approvalId: String?
    let traceId: String?
    let risk: String?
    let summary: String?
    let auditRef: WorkAuditRefDTO?

    var id: String {
        approvalId ?? traceId ?? [kind, status, functionId].compactMap { $0 }.joined(separator: ":")
    }
}

struct WorkAuditRefDTO: Decodable, Equatable {
    let kind: String
    let id: String?
    let traceId: String?
    let catalogRevision: UInt64?
}

struct WorkScopeDTO: Decodable, Equatable {
    let sessionId: String?
    let workspaceId: String?
}

// MARK: - Prompt Queue engine protocols

struct QueuePromptParams: Encodable {
    let sessionId: String
    let prompt: String
}

struct DequeuePromptParams: Encodable {
    let sessionId: String
    let queueId: String
}

struct ClearQueueParams: Encodable {
    let sessionId: String
}

/// Server-side pending queue item (from agent.queuePrompt or reconstruction).
struct PendingQueueItem: Decodable, Identifiable, Equatable {
    let queueId: String
    let text: String
    let position: UInt32
    let timestamp: String

    var id: String { queueId }
}

struct ClearQueueResult: Decodable {
    let cleared: UInt32
}

struct DequeueResult: Decodable {
    let ok: Bool
}

/// Capability invocation info for in-progress turn (used by session::reconstruct inFlight state)
struct CurrentTurnCapabilityInvocation: Decodable {
    let invocationId: String
    let arguments: [String: AnyCodable]?
    let status: String  // "generating" | "running" | "completed" | "error"
    let result: String?
    let isError: Bool?
    let startedAt: String?
    let completedAt: String?
    /// Progressive output accumulated during execution
    let streamingOutput: String?
    let modelPrimitiveName: String?
    let contractId: String?
    let implementationId: String?
    let functionId: String?
    let pluginId: String?
    let workerId: String?
    let schemaDigest: String?
    let catalogRevision: UInt64?
    let trustTier: String?
    let riskLevel: String?
    let effectClass: String?
    let traceId: String?
    let rootInvocationId: String?
    let bindingDecisionId: String?
}

/// Structured content sequence item (interleaved text/thinking/capability_ref)
enum ContentSequenceItem: Decodable {
    case text(String)
    case thinking(String)
    case capabilityRef(invocationId: String)

    private enum CodingKeys: String, CodingKey {
        case type, text, thinking, invocationId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "thinking":
            self = .thinking(try container.decode(String.self, forKey: .thinking))
        case "capability_ref":
            self = .capabilityRef(invocationId: try container.decode(String.self, forKey: .invocationId))
        default:
            self = .text("")
        }
    }
}

// MARK: - Token Usage Types

struct TokenUsage: Decodable, Equatable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int?
    let cacheCreationTokens: Int?

    var totalTokens: Int { inputTokens + outputTokens }

    var formattedInput: String { inputTokens.formattedTokenCount }
    var formattedOutput: String { outputTokens.formattedTokenCount }
    var formattedTotal: String { totalTokens.formattedTokenCount }

    /// Format server-provided cache read tokens (e.g., 20000 → "20k"). Returns nil if not provided or zero.
    var formattedCacheRead: String? {
        guard let tokens = cacheReadTokens, tokens > 0 else { return nil }
        return tokens.formattedTokenCount
    }

    /// Format server-provided cache write tokens. Returns nil if not provided or zero.
    var formattedCacheWrite: String? {
        guard let tokens = cacheCreationTokens, tokens > 0 else { return nil }
        return tokens.formattedTokenCount
    }

    /// Check if server provided any cache tokens to display
    var hasCacheActivity: Bool {
        (cacheReadTokens ?? 0) > 0 || (cacheCreationTokens ?? 0) > 0
    }
}

// MARK: - Answer Submission

struct AnswerSubmission: Encodable {
    let id: String
    let question: String
    let selectedValues: [String]
    let otherValue: String?
}

struct SubmitAnswersParams: Encodable {
    let sessionId: String
    let pauseId: String
    let invocationId: String
    let questions: [AnswerSubmission]
}

struct SubmitAnswersResponse: Decodable {
    let acknowledged: Bool
    let queued: Bool
    let runId: String?
}
