import Foundation

// MARK: - Connection Repository

/// Black-box connection contract for UI and session layers.
@MainActor
protocol AppConnectionRepository: AnyObject {
    var connectionState: ConnectionState { get }
    /// Monotonic ready-socket epoch. This advances even when an intermediate
    /// reconnect state is coalesced into connected-to-connected observation.
    var continuityGeneration: UInt64 { get }
    /// Stable identity for the installed server-bound connection owner.
    var continuityOwnerId: UUID { get }

    func connect() async
}

extension AppConnectionRepository {
    var continuityGeneration: UInt64 { 0 }
    var continuityOwnerId: UUID { EngineConnectionContinuity.fallbackOwnerId }

    var continuity: EngineConnectionContinuity {
        EngineConnectionContinuity(
            state: connectionState,
            generation: continuityGeneration,
            ownerId: continuityOwnerId
        )
    }
}

// MARK: - Session Event Repository

/// Black-box live event contract for session view models.
@MainActor
protocol SessionEventRepository: AnyObject {
    var currentSessionId: String? { get }
    var currentModel: String { get }
    var hasActiveSession: Bool { get }

    func events(for sessionId: String?) -> AsyncStream<ParsedEventV2>
    func ensureSessionEventSubscription(sessionId: String, workspaceId: String?) async throws
    func releaseSessionEventSubscription(sessionId: String, workspaceId: String?) async
}

// MARK: - Settings Repository

/// UI/session-facing settings snapshot. The engine repository maps the wire
/// `ServerSettings` DTO into this contract before it crosses into SwiftUI.
struct ServerSettingsSnapshot: Equatable, Sendable {
    let defaultModel: String
    let defaultWorkspace: String?
    let tailscaleIp: String?
    let ollamaBaseUrl: String
    let compactionPreserveRecentCount: Int
    let compactionTriggerTokenThreshold: Double

    init(
        defaultModel: String,
        defaultWorkspace: String?,
        tailscaleIp: String?,
        ollamaBaseUrl: String,
        compactionPreserveRecentCount: Int,
        compactionTriggerTokenThreshold: Double
    ) {
        self.defaultModel = defaultModel
        self.defaultWorkspace = defaultWorkspace
        self.tailscaleIp = tailscaleIp
        self.ollamaBaseUrl = ollamaBaseUrl
        self.compactionPreserveRecentCount = compactionPreserveRecentCount
        self.compactionTriggerTokenThreshold = compactionTriggerTokenThreshold
    }

    init(_ settings: ServerSettings) {
        self.init(
            defaultModel: settings.defaultModel,
            defaultWorkspace: settings.defaultWorkspace,
            tailscaleIp: settings.tailscaleIp,
            ollamaBaseUrl: settings.ollamaBaseUrl,
            compactionPreserveRecentCount: settings.compaction.preserveRecentCount,
            compactionTriggerTokenThreshold: settings.compaction.triggerTokenThreshold
        )
    }
}

/// UI-owned settings mutation vocabulary translated to wire DTOs inside the
/// settings repository boundary.
enum SettingsMutation {
    case defaultWorkspace(String)
    case defaultModel(String)
    case ollamaBaseUrl(String)
    case compactionTriggerTokenThreshold(Double)
    case compactionPreserveRecentCount(Int)
}

/// Black-box settings contract for server-authoritative settings.
@MainActor
protocol SettingsRepository: AnyObject {
    func get() async throws -> ServerSettingsSnapshot
    func update(_ mutation: SettingsMutation, idempotencyKey: EngineIdempotencyKey) async throws
    func resetToDefaults(idempotencyKey: EngineIdempotencyKey) async throws -> ServerSettingsSnapshot
}

// MARK: - Auth Repository

struct AuthSnapshot: Equatable {
    let providers: [String: ProviderAuthSnapshot]

    init(providers: [String: ProviderAuthSnapshot]) {
        self.providers = providers
    }

    init(_ state: AuthState) {
        self.init(providers: state.providers.mapValues(ProviderAuthSnapshot.init))
    }
}

struct ProviderAuthSnapshot: Equatable {
    let hasApiKey: Bool
    let apiKeyHint: String?
    let hasOAuth: Bool
    let accounts: [ProviderAccountSnapshot]
    let apiKeys: [ProviderApiKeySnapshot]
    let activeCredential: AuthCredentialSelection?
    let projectId: String?
    let hasClientId: Bool
    let hasClientSecret: Bool

    init(
        hasApiKey: Bool,
        apiKeyHint: String?,
        hasOAuth: Bool,
        accounts: [ProviderAccountSnapshot],
        apiKeys: [ProviderApiKeySnapshot],
        activeCredential: AuthCredentialSelection?,
        projectId: String?,
        hasClientId: Bool,
        hasClientSecret: Bool
    ) {
        self.hasApiKey = hasApiKey
        self.apiKeyHint = apiKeyHint
        self.hasOAuth = hasOAuth
        self.accounts = accounts
        self.apiKeys = apiKeys
        self.activeCredential = activeCredential
        self.projectId = projectId
        self.hasClientId = hasClientId
        self.hasClientSecret = hasClientSecret
    }

    init(_ info: ProviderAuthInfo) {
        self.init(
            hasApiKey: info.hasApiKey,
            apiKeyHint: info.apiKeyHint,
            hasOAuth: info.hasOAuth,
            accounts: info.accounts?.map(ProviderAccountSnapshot.init) ?? [],
            apiKeys: info.apiKeys?.map(ProviderApiKeySnapshot.init) ?? [],
            activeCredential: info.activeCredential.flatMap(AuthCredentialSelection.init),
            projectId: info.projectId,
            hasClientId: info.hasClientId ?? false,
            hasClientSecret: info.hasClientSecret ?? false
        )
    }
}

struct ProviderAccountSnapshot: Equatable, Identifiable {
    let label: String
    let expiresAt: Int64
    let isExpired: Bool
    let hasRefreshToken: Bool

    var id: String { label }

    init(label: String, expiresAt: Int64, isExpired: Bool, hasRefreshToken: Bool) {
        self.label = label
        self.expiresAt = expiresAt
        self.isExpired = isExpired
        self.hasRefreshToken = hasRefreshToken
    }

    init(_ account: AccountInfo) {
        self.init(
            label: account.label,
            expiresAt: account.expiresAt,
            isExpired: account.isExpired,
            hasRefreshToken: account.hasRefreshToken
        )
    }
}

struct ProviderApiKeySnapshot: Equatable, Identifiable {
    let label: String
    let keyHint: String

    var id: String { label }

    init(label: String, keyHint: String) {
        self.label = label
        self.keyHint = keyHint
    }

    init(_ key: ApiKeyInfo) {
        self.init(label: key.label, keyHint: key.keyHint)
    }
}

struct AuthCredentialSelection: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case oauth
        case apiKey
    }

    let kind: Kind
    let label: String

    var isOAuth: Bool { kind == .oauth }
    var isApiKey: Bool { kind == .apiKey }

    init(kind: Kind, label: String) {
        self.kind = kind
        self.label = label
    }

    init?(_ info: ActiveCredentialInfo) {
        guard let kind = Kind(rawValue: info.type) else { return nil }
        self.init(kind: kind, label: info.label)
    }
}

enum AuthMutation: Equatable, Sendable {
    case googleCloud(provider: String, clientId: String?, clientSecret: String?, projectId: String?)
}

enum AuthClearTarget: Equatable, Sendable {
    case provider(String)
}

struct OAuthBeginSnapshot: Equatable, Sendable {
    let flowId: String
    let authUrl: String

    init(flowId: String, authUrl: String) {
        self.flowId = flowId
        self.authUrl = authUrl
    }

    init(_ response: OAuthBeginResponse) {
        self.init(flowId: response.flowId, authUrl: response.authUrl)
    }
}

/// Black-box auth contract for provider and onboarding UI.
@MainActor
protocol AuthRepository: AnyObject {
    func get() async throws -> AuthSnapshot
    func update(_ mutation: AuthMutation, idempotencyKey: EngineIdempotencyKey) async throws -> AuthSnapshot
    func clear(_ target: AuthClearTarget, idempotencyKey: EngineIdempotencyKey) async throws -> AuthSnapshot
    func oauthBegin(provider: String, idempotencyKey: EngineIdempotencyKey) async throws -> OAuthBeginSnapshot
    func oauthComplete(flowId: String, code: String, label: String, idempotencyKey: EngineIdempotencyKey) async throws -> AuthSnapshot
    func setActive(provider: String, credential: AuthCredentialSelection, idempotencyKey: EngineIdempotencyKey) async throws -> AuthSnapshot
    func removeAccount(provider: String, label: String, idempotencyKey: EngineIdempotencyKey) async throws -> AuthSnapshot
    func removeApiKey(provider: String, label: String, idempotencyKey: EngineIdempotencyKey) async throws -> AuthSnapshot
    func addNamedApiKey(provider: String, label: String, key: String, idempotencyKey: EngineIdempotencyKey) async throws -> AuthSnapshot
}

// MARK: - Message Repository

/// Black-box message mutation contract for session view models.
@MainActor
protocol MessageRepository: AnyObject {
    func deleteMessage(
        sessionId: String,
        targetEventId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> MessageDeleteResult
}

// MARK: - Workspace Browser Repository

@MainActor
protocol WorkspaceBrowserRepository: AnyObject {
    func getHome() async throws -> WorkspaceHomeResult
    func listDirectory(path: String?, showHidden: Bool) async throws -> WorkspaceDirectoryListResult
    func createDirectory(
        path: String,
        recursive: Bool,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkspaceCreateDirectoryResult
    func inspectSourceControl(path: String) async throws -> WorkspaceSourceControlStatus
}

extension WorkspaceBrowserRepository {
    func inspectSourceControl(path _: String) async throws -> WorkspaceSourceControlStatus {
        throw URLError(.unsupportedURL)
    }
}

// MARK: - Worker Kernel Repository

/// Black-box operational contract for the engine-global worker console.
@MainActor
protocol WorkerKernelRepository: AnyObject {
    func engineSurfaceSnapshot(
        sessionId: String?,
        relevanceQuery: String?
    ) async throws -> EngineIntrospectionSnapshotDTO
    func workers(includeRetired: Bool) async throws -> WorkerListResultDTO
    func inspectWorker(_ workerId: String) async throws -> WorkerInspectResultDTO
    func workerRuns(
        workerId: String?,
        originSessionId: String?,
        limit: UInt64,
        offset: UInt64?
    ) async throws -> WorkerRunsResultDTO
    func workerRunGraph(
        invocationId: String?,
        modelToolInvocationId: String?
    ) async throws -> WorkerRunsResultDTO
    func workerRunGraphs(
        originSessionId: String,
        limit: UInt64,
        offset: UInt64?
    ) async throws -> WorkerRunsResultDTO
    func workerResult(
        invocationId: String,
        pointer: String,
        offset: UInt64,
        limit: UInt8,
        sessionId: String?
    ) async throws -> WorkerResultChunkDTO
    func createWorkerResultHandoff(
        invocationId: String,
        workingDirectory: String,
        model: String,
        title: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerResultHandoffDTO
    func workerInbox(
        workerId: String?,
        limit: UInt64,
        offset: UInt64?,
        attentionOnly: Bool
    ) async throws -> WorkerInboxResultDTO
    func scheduledWork(
        limit: UInt64,
        offset: UInt64?
    ) async throws -> WorkerScheduledWorkResultDTO
    func dismissWorkerInboxItem(
        inboxId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInboxDismissResultDTO
    func artifactDeliveries(
        limit: UInt16,
        offset: UInt64
    ) async throws -> WorkerArtifactPageDTO
    func artifactContent(
        workerId: String,
        artifactId: String
    ) async throws -> WorkerArtifactContentDTO
    func deleteArtifact(
        workerId: String,
        artifactId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerArtifactDeleteDTO
    func invokeWorker(
        workerId: String,
        input: AnyCodable,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO
    func invokeWorker(
        workerId: String,
        input: AnyCodable,
        model: String?,
        reasoningLevel: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO
    func invokeWorkerFromSession(
        workerId: String,
        input: AnyCodable,
        originSessionId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO
    func enqueueWorker(
        workerId: String,
        input: AnyCodable,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO
    func cancelWorkerInvocation(
        invocationId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO
    func detachWorkerInvocation(
        invocationId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO
    func awaitWorkerInvocation(
        invocationId: String,
        timeoutSeconds: UInt8
    ) async throws -> WorkerAwaitResultDTO
    func retryWorkerInvocation(
        invocationId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO
    func setWorkerEnabled(
        _ enabled: Bool,
        workerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerSummaryDTO
    func stopWorker(
        workerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerSummaryDTO
    func rollbackWorker(
        workerId: String,
        version: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerRollbackResultDTO
    func retireWorker(
        workerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerSummaryDTO
    func purgeWorker(
        workerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerPurgeResultDTO
    func setWorkersStopped(
        _ stopped: Bool,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerStopAllResultDTO
    func rotateWorkerWebhook(
        workerId: String,
        triggerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerWebhookCredentialDTO
    /// Starts connection-local worker invalidations at the current durable
    /// stream tail. Historical evidence remains available through bounded
    /// `runs` and `inbox` reads.
    func ensureWorkerEventSubscriptions() async throws
}

extension WorkerKernelRepository {
    func createWorkerResultHandoff(
        invocationId _: String,
        workingDirectory _: String,
        model _: String,
        title _: String,
        idempotencyKey _: EngineIdempotencyKey
    ) async throws -> WorkerResultHandoffDTO {
        throw EngineConnectionError.invalidResponse
    }

    func invokeWorker(
        workerId: String,
        input: AnyCodable,
        model _: String?,
        reasoningLevel _: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO {
        try await invokeWorker(
            workerId: workerId,
            input: input,
            idempotencyKey: idempotencyKey
        )
    }

    func artifactDeliveries(
        limit _: UInt16,
        offset _: UInt64
    ) async throws -> WorkerArtifactPageDTO {
        throw EngineConnectionError.invalidResponse
    }

    func artifactContent(
        workerId _: String,
        artifactId _: String
    ) async throws -> WorkerArtifactContentDTO {
        throw EngineConnectionError.invalidResponse
    }

    func deleteArtifact(
        workerId _: String,
        artifactId _: String,
        idempotencyKey _: EngineIdempotencyKey
    ) async throws -> WorkerArtifactDeleteDTO {
        throw EngineConnectionError.invalidResponse
    }

    /// Resolve only a just-completed bounded result needed by a native worker
    /// contract. Historical lists and presentation paths must keep references
    /// and use the explicit inspector instead.
    ///
    /// Session-originated native actions must hydrate their result with the
    /// same durable session identity that admitted the invocation. This keeps
    /// the server's narrow origin/delivery-grant authorization intact.
    func resolvedWorkerResult(
        _ invocation: WorkerInvocationDTO,
        sessionId: String? = nil
    ) async throws -> AnyCodable {
        if let legacy = invocation.output?.legacyInline {
            return legacy
        }
        guard let reference = invocation.output?.reference else {
            throw EngineConnectionError.invalidResponse
        }
        guard reference.sizeBytes <= 32_768 else {
            throw EngineConnectionError.invalidResponse
        }
        let chunk = try await workerResult(
            invocationId: reference.invocationId,
            pointer: "",
            offset: 0,
            limit: 20,
            sessionId: sessionId ?? invocation.originSessionId
        )
        guard chunk.reference == reference,
              chunk.pointer.isEmpty,
              !chunk.truncated,
              chunk.nextOffset == nil,
              chunk.children.isEmpty else {
            throw EngineConnectionError.invalidResponse
        }
        return chunk.value
    }

    func workerResult(
        invocationId: String,
        pointer: String,
        offset: UInt64,
        limit: UInt8,
        sessionId _: String?
    ) async throws -> WorkerResultChunkDTO {
        throw EngineConnectionError.invalidResponse
    }

    func workerResult(
        invocationId: String,
        pointer: String,
        offset: UInt64,
        limit: UInt8
    ) async throws -> WorkerResultChunkDTO {
        try await workerResult(
            invocationId: invocationId,
            pointer: pointer,
            offset: offset,
            limit: limit,
            sessionId: nil
        )
    }

    func workerRunGraph(
        invocationId _: String?,
        modelToolInvocationId _: String?
    ) async throws -> WorkerRunsResultDTO {
        throw EngineConnectionError.invalidResponse
    }

    func workerRunGraphs(
        originSessionId: String,
        limit: UInt64,
        offset: UInt64?
    ) async throws -> WorkerRunsResultDTO {
        try await workerRuns(
            workerId: nil,
            originSessionId: originSessionId,
            limit: limit,
            offset: offset
        )
    }

    func detachWorkerInvocation(
        invocationId _: String,
        idempotencyKey _: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO {
        throw EngineConnectionError.invalidResponse
    }

    func awaitWorkerInvocation(
        invocationId _: String,
        timeoutSeconds _: UInt8
    ) async throws -> WorkerAwaitResultDTO {
        throw EngineConnectionError.invalidResponse
    }

    func retryWorkerInvocation(
        invocationId _: String,
        idempotencyKey _: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO {
        throw EngineConnectionError.invalidResponse
    }

    func invokeWorkerFromSession(
        workerId: String,
        input: AnyCodable,
        originSessionId _: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO {
        try await invokeWorker(
            workerId: workerId,
            input: input,
            idempotencyKey: idempotencyKey
        )
    }

    func workerRuns(workerId: String?, limit: UInt64) async throws -> WorkerRunsResultDTO {
        try await workerRuns(
            workerId: workerId,
            originSessionId: nil,
            limit: limit,
            offset: nil
        )
    }

    func workerRuns(
        workerId: String?,
        originSessionId: String?,
        limit: UInt64
    ) async throws -> WorkerRunsResultDTO {
        try await workerRuns(
            workerId: workerId,
            originSessionId: originSessionId,
            limit: limit,
            offset: nil
        )
    }

    func workerInbox(workerId: String?, limit: UInt64) async throws -> WorkerInboxResultDTO {
        try await workerInbox(
            workerId: workerId,
            limit: limit,
            offset: nil,
            attentionOnly: false
        )
    }

    func workerAttention(
        workerId: String?,
        limit: UInt64,
        offset: UInt64? = nil
    ) async throws -> WorkerInboxResultDTO {
        try await workerInbox(
            workerId: workerId,
            limit: limit,
            offset: offset,
            attentionOnly: true
        )
    }

}

// MARK: - Chat Session Services

/// Protocol-typed dependency bundle for mounted chat sessions.
struct ChatSessionServices {
    let connection: any AppConnectionRepository
    let events: any SessionEventRepository
    let sessions: any NetworkSessionRepository
    let agent: any AgentRepository
    let models: any ModelRepository
    let messages: any MessageRepository
    let workerKernel: any WorkerKernelRepository
}
