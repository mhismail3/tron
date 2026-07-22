import Foundation

// MARK: - Default Connection Repository

@MainActor
final class DefaultAppConnectionRepository: AppConnectionRepository {
    private let client: EngineClient

    init(client: EngineClient) {
        self.client = client
    }

    var connectionState: ConnectionState {
        client.connectionState
    }

    func connect() async {
        await client.connect()
    }
}

// MARK: - Default Session Event Repository

@MainActor
final class DefaultSessionEventRepository: SessionEventRepository {
    private let client: EngineClient

    init(client: EngineClient) {
        self.client = client
    }

    var currentSessionId: String? {
        client.currentSessionId
    }

    var currentModel: String {
        client.currentModel
    }

    var hasActiveSession: Bool {
        client.hasActiveSession
    }

    func events(for sessionId: String?) -> AsyncStream<ParsedEventV2> {
        client.events(for: sessionId)
    }

    func ensureSessionEventSubscription(sessionId: String, workspaceId: String?) async throws {
        try await client.ensureSessionEventSubscription(sessionId: sessionId, workspaceId: workspaceId)
    }
}

// MARK: - Default Settings Repository

@MainActor
final class DefaultSettingsRepository: SettingsRepository {
    private let settingsClient: SettingsClient

    init(settingsClient: SettingsClient) {
        self.settingsClient = settingsClient
    }

    func get() async throws -> ServerSettingsSnapshot {
        ServerSettingsSnapshot(try await settingsClient.get())
    }

    func update(_ mutation: SettingsMutation, idempotencyKey: EngineIdempotencyKey) async throws {
        try await settingsClient.update(mutation.toServerSettingsUpdate(), idempotencyKey: idempotencyKey)
    }

    func resetToDefaults(idempotencyKey: EngineIdempotencyKey) async throws -> ServerSettingsSnapshot {
        ServerSettingsSnapshot(try await settingsClient.resetToDefaults(idempotencyKey: idempotencyKey))
    }
}

private extension SettingsMutation {
    func toServerSettingsUpdate() -> ServerSettingsUpdate {
        switch self {
        case .defaultWorkspace(let workspace):
            return ServerSettingsUpdate(server: .init(defaultWorkspace: workspace))
        case .defaultModel(let model):
            return ServerSettingsUpdate(server: .init(defaultModel: model))
        case .ollamaBaseUrl(let baseUrl):
            return ServerSettingsUpdate(api: .init(ollama: .init(baseUrl: baseUrl)))
        case .compactionTriggerTokenThreshold(let threshold):
            return ServerSettingsUpdate(context: .init(compactor: .init(triggerTokenThreshold: threshold)))
        case .compactionPreserveRecentCount(let count):
            return ServerSettingsUpdate(context: .init(compactor: .init(preserveRecentCount: count)))
        }
    }
}

// MARK: - Default Auth Repository

@MainActor
final class DefaultAuthRepository: AuthRepository {
    private let authClient: AuthClient

    init(authClient: AuthClient) {
        self.authClient = authClient
    }

    func get() async throws -> AuthSnapshot {
        AuthSnapshot(try await authClient.get())
    }

    func update(_ mutation: AuthMutation, idempotencyKey: EngineIdempotencyKey) async throws -> AuthSnapshot {
        AuthSnapshot(try await authClient.update(mutation.toAuthUpdateParams(), idempotencyKey: idempotencyKey))
    }

    func clear(_ target: AuthClearTarget, idempotencyKey: EngineIdempotencyKey) async throws -> AuthSnapshot {
        AuthSnapshot(try await authClient.clear(target.toAuthClearParams(), idempotencyKey: idempotencyKey))
    }

    func oauthBegin(provider: String, idempotencyKey: EngineIdempotencyKey) async throws -> OAuthBeginSnapshot {
        OAuthBeginSnapshot(try await authClient.oauthBegin(provider: provider, idempotencyKey: idempotencyKey))
    }

    func oauthComplete(flowId: String, code: String, label: String, idempotencyKey: EngineIdempotencyKey) async throws -> AuthSnapshot {
        AuthSnapshot(try await authClient.oauthComplete(flowId: flowId, code: code, label: label, idempotencyKey: idempotencyKey))
    }

    func setActive(provider: String, credential: AuthCredentialSelection, idempotencyKey: EngineIdempotencyKey) async throws -> AuthSnapshot {
        AuthSnapshot(try await authClient.setActive(
            provider: provider,
            credential: credential.toActiveCredentialParam(),
            idempotencyKey: idempotencyKey
        ))
    }

    func removeAccount(provider: String, label: String, idempotencyKey: EngineIdempotencyKey) async throws -> AuthSnapshot {
        AuthSnapshot(try await authClient.removeAccount(provider: provider, label: label, idempotencyKey: idempotencyKey))
    }

    func removeApiKey(provider: String, label: String, idempotencyKey: EngineIdempotencyKey) async throws -> AuthSnapshot {
        AuthSnapshot(try await authClient.removeApiKey(provider: provider, label: label, idempotencyKey: idempotencyKey))
    }

    func addNamedApiKey(provider: String, label: String, key: String, idempotencyKey: EngineIdempotencyKey) async throws -> AuthSnapshot {
        AuthSnapshot(try await authClient.addNamedApiKey(provider: provider, label: label, key: key, idempotencyKey: idempotencyKey))
    }
}

private extension AuthMutation {
    func toAuthUpdateParams() -> AuthUpdateParams {
        switch self {
        case .googleCloud(let provider, let clientId, let clientSecret, let projectId):
            var params = AuthUpdateParams(provider: provider)
            params.clientId = clientId
            params.clientSecret = clientSecret
            params.projectId = projectId
            return params
        }
    }
}

private extension AuthClearTarget {
    func toAuthClearParams() -> AuthClearParams {
        switch self {
        case .provider(let provider):
            return AuthClearParams(provider: provider)
        }
    }
}

private extension AuthCredentialSelection {
    func toActiveCredentialParam() -> ActiveCredentialParam {
        ActiveCredentialParam(type: kind.rawValue, label: label)
    }
}

// MARK: - Default Message Repository

@MainActor
final class DefaultMessageRepository: MessageRepository {
    private let messageClient: MessageClient

    init(messageClient: MessageClient) {
        self.messageClient = messageClient
    }

    func deleteMessage(
        sessionId: String,
        targetEventId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> MessageDeleteResult {
        try await messageClient.deleteMessage(
            sessionId,
            targetEventId: targetEventId,
            idempotencyKey: idempotencyKey
        )
    }
}

// MARK: - Default Workspace Browser Repository

@MainActor
final class DefaultWorkspaceBrowserRepository: WorkspaceBrowserRepository {
    private let client: WorkspaceBrowserClient

    init(client: WorkspaceBrowserClient) {
        self.client = client
    }

    func getHome() async throws -> WorkspaceHomeResult {
        try await client.getHome()
    }

    func listDirectory(path: String?, showHidden: Bool) async throws -> WorkspaceDirectoryListResult {
        try await client.listDirectory(path: path, showHidden: showHidden)
    }

    func createDirectory(
        path: String,
        recursive: Bool,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkspaceCreateDirectoryResult {
        try await client.createDirectory(
            path: path,
            recursive: recursive,
            idempotencyKey: idempotencyKey
        )
    }
}

// MARK: - Default Worker Kernel Repository

@MainActor
final class DefaultWorkerKernelRepository: WorkerKernelRepository {
    private let client: WorkerKernelClient

    init(client: WorkerKernelClient) {
        self.client = client
    }

    func engineSurfaceSnapshot(
        sessionId: String?,
        relevanceQuery: String?
    ) async throws -> EngineIntrospectionSnapshotDTO {
        try await client.engineSurfaceSnapshot(
            sessionId: sessionId,
            relevanceQuery: relevanceQuery
        )
    }

    func workers(includeRetired: Bool) async throws -> WorkerListResultDTO {
        try await client.workers(includeRetired: includeRetired)
    }

    func inspectWorker(_ workerId: String) async throws -> WorkerInspectResultDTO {
        try await client.inspectWorker(workerId)
    }

    func workerRuns(workerId: String?, limit: UInt64) async throws -> WorkerRunsResultDTO {
        try await client.workerRuns(workerId: workerId, limit: limit)
    }

    func workerInbox(workerId: String?, limit: UInt64) async throws -> WorkerInboxResultDTO {
        try await client.workerInbox(workerId: workerId, limit: limit)
    }

    func invokeWorker(
        workerId: String,
        input: AnyCodable,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO {
        try await client.invokeWorker(
            workerId: workerId,
            input: input,
            idempotencyKey: idempotencyKey,
            mode: .wait
        )
    }

    func enqueueWorker(
        workerId: String,
        input: AnyCodable,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO {
        try await client.invokeWorker(
            workerId: workerId,
            input: input,
            idempotencyKey: idempotencyKey,
            mode: .enqueue
        )
    }

    func cancelWorkerInvocation(
        invocationId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO {
        try await client.cancelWorkerInvocation(
            invocationId: invocationId,
            idempotencyKey: idempotencyKey
        )
    }

    func setWorkerEnabled(
        _ enabled: Bool,
        workerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerSummaryDTO {
        try await client.setWorkerEnabled(
            enabled,
            workerId: workerId,
            idempotencyKey: idempotencyKey
        )
    }

    func stopWorker(
        workerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerSummaryDTO {
        try await client.stopWorker(workerId: workerId, idempotencyKey: idempotencyKey)
    }

    func rollbackWorker(
        workerId: String,
        version: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerRollbackResultDTO {
        try await client.rollbackWorker(
            workerId: workerId,
            version: version,
            idempotencyKey: idempotencyKey
        )
    }

    func retireWorker(
        workerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerSummaryDTO {
        try await client.retireWorker(workerId: workerId, idempotencyKey: idempotencyKey)
    }

    func purgeWorker(
        workerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerPurgeResultDTO {
        try await client.purgeWorker(workerId: workerId, idempotencyKey: idempotencyKey)
    }

    func setWorkersStopped(
        _ stopped: Bool,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerStopAllResultDTO {
        try await client.setWorkersStopped(stopped, idempotencyKey: idempotencyKey)
    }

    func rotateWorkerWebhook(
        workerId: String,
        triggerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerWebhookCredentialDTO {
        try await client.rotateWorkerWebhook(
            workerId: workerId,
            triggerId: triggerId,
            idempotencyKey: idempotencyKey
        )
    }

    func pollWorkerEvents(
        topic: String,
        cursor: EngineStreamCursor
    ) async throws -> EngineStreamPage {
        try await client.pollWorkerEvents(topic: topic, cursor: cursor)
    }
}
