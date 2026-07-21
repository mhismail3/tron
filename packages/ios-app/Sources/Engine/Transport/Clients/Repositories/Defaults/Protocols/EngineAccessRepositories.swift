import Foundation

// MARK: - Connection Repository

/// Black-box connection contract for UI and session layers.
@MainActor
protocol AppConnectionRepository: AnyObject {
    var connectionState: ConnectionState { get }

    func connect() async
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
}

// MARK: - Settings Repository

/// UI/session-facing settings snapshot. The engine repository maps the wire
/// `ServerSettings` DTO into this contract before it crosses into SwiftUI.
struct ServerSettingsSnapshot: Equatable, Sendable {
    let autonomousWorkers: Bool
    let defaultModel: String
    let defaultWorkspace: String?
    let tailscaleIp: String?
    let compactionPreserveRecentCount: Int
    let compactionTriggerTokenThreshold: Double

    init(
        defaultModel: String,
        defaultWorkspace: String?,
        tailscaleIp: String?,
        compactionPreserveRecentCount: Int,
        compactionTriggerTokenThreshold: Double,
        autonomousWorkers: Bool = false
    ) {
        self.defaultModel = defaultModel
        self.defaultWorkspace = defaultWorkspace
        self.tailscaleIp = tailscaleIp
        self.compactionPreserveRecentCount = compactionPreserveRecentCount
        self.compactionTriggerTokenThreshold = compactionTriggerTokenThreshold
        self.autonomousWorkers = autonomousWorkers
    }

    init(_ settings: ServerSettings) {
        self.init(
            defaultModel: settings.defaultModel,
            defaultWorkspace: settings.defaultWorkspace,
            tailscaleIp: settings.tailscaleIp,
            compactionPreserveRecentCount: settings.compaction.preserveRecentCount,
            compactionTriggerTokenThreshold: settings.compaction.triggerTokenThreshold,
            autonomousWorkers: settings.autonomousWorkers
        )
    }
}

/// UI-owned settings mutation vocabulary translated to wire DTOs inside the
/// settings repository boundary.
enum SettingsMutation {
    case autonomousWorkers(Bool)
    case defaultWorkspace(String)
    case defaultModel(String)
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
    let services: [String: ServiceAuthSnapshot]

    init(providers: [String: ProviderAuthSnapshot], services: [String: ServiceAuthSnapshot]) {
        self.providers = providers
        self.services = services
    }

    init(_ state: AuthState) {
        self.init(
            providers: state.providers.mapValues(ProviderAuthSnapshot.init),
            services: state.services.mapValues(ServiceAuthSnapshot.init)
        )
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

struct ServiceAuthSnapshot: Equatable {
    let hasApiKey: Bool
    let apiKeyHint: String?

    init(hasApiKey: Bool, apiKeyHint: String?) {
        self.hasApiKey = hasApiKey
        self.apiKeyHint = apiKeyHint
    }

    init(_ info: ServiceAuthInfo) {
        self.init(hasApiKey: info.hasApiKey, apiKeyHint: info.apiKeyHint)
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
    case serviceApiKey(service: String, key: String)
    case googleCloud(provider: String, clientId: String?, clientSecret: String?, projectId: String?)
}

enum AuthClearTarget: Equatable, Sendable {
    case provider(String)
    case service(String)
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
}

// MARK: - Worker Kernel Repository

/// Black-box operational contract for the profile-global worker console.
@MainActor
protocol WorkerKernelRepository: AnyObject {
    func engineSurfaceSnapshot(
        sessionId: String?,
        relevanceQuery: String?
    ) async throws -> EngineIntrospectionSnapshotDTO
    func workers(includeRetired: Bool) async throws -> WorkerListResultDTO
    func inspectWorker(_ workerId: String) async throws -> WorkerInspectResultDTO
    func workerRuns(workerId: String?, limit: UInt64) async throws -> WorkerRunsResultDTO
    func workerInbox(workerId: String?, limit: UInt64) async throws -> WorkerInboxResultDTO
    func invokeWorker(
        workerId: String,
        input: AnyCodable,
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
    /// Polls historical worker topic events after an explicit cursor. Topic polling is
    /// replay, not live subscription, so the transport must never omit the cursor.
    func pollWorkerEvents(topic: String, cursor: EngineStreamCursor) async throws -> EngineStreamPage
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
