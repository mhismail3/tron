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

    var isConnected: Bool {
        client.isConnected
    }

    func connect() async {
        await client.connect()
    }

    func disconnect() async {
        await client.disconnect()
    }

    func verifyConnection() async -> Bool {
        await client.verifyConnection()
    }

    func manualRetry() async {
        await client.manualRetry()
    }

    func setBackgroundState(_ inBackground: Bool) {
        client.setBackgroundState(inBackground)
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
        case .defaultProvider(let provider):
            return ServerSettingsUpdate(server: .init(defaultProvider: provider))
        case .defaultWorkspace(let workspace):
            return ServerSettingsUpdate(server: .init(defaultWorkspace: workspace))
        case .defaultModel(let model):
            return ServerSettingsUpdate(server: .init(defaultModel: model))
        case .compactionTriggerTokenThreshold(let threshold):
            return ServerSettingsUpdate(context: .init(compactor: .init(triggerTokenThreshold: threshold)))
        case .compactionPreserveRecentCount(let count):
            return ServerSettingsUpdate(context: .init(compactor: .init(preserveRecentCount: count)))
        case .observabilityLogLevel(let level):
            var update = ServerSettingsUpdate()
            update.observability = .init(logLevel: level)
            return update
        case .observabilityVerboseRetentionDays(let days):
            var update = ServerSettingsUpdate()
            update.observability = .init(verboseRetentionDays: days)
            return update
        case .storageRetentionEnabled(let enabled):
            var update = ServerSettingsUpdate()
            update.storage = .init(retentionEnabled: enabled)
            return update
        case .storageMaxDatabaseMb(let megabytes):
            var update = ServerSettingsUpdate()
            update.storage = .init(maxDatabaseMb: megabytes)
            return update
        case .transcriptionEnabled(let enabled):
            return ServerSettingsUpdate(server: .init(transcription: .init(enabled: enabled)))
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
        case .serviceApiKey(let service, let key):
            return AuthUpdateParams(service: service, apiKey: .value(key))
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
        case .service(let service):
            return AuthClearParams(service: service)
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

// MARK: - Default Transcription Repository

@MainActor
final class DefaultTranscriptionRepository: TranscriptionRepository {
    private let client: TranscriptionClient

    init(client: TranscriptionClient) {
        self.client = client
    }

    func transcribeAudio(
        data: Data,
        mimeType: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> TranscribeAudioResult {
        try await client.transcribeAudio(
            audioData: data,
            mimeType: mimeType,
            idempotencyKey: idempotencyKey
        )
    }

    func listModels() async throws -> TranscriptionModelsResult {
        try await client.listModels()
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

// MARK: - Default Worker Lifecycle Repository

@MainActor
final class DefaultWorkerLifecycleRepository: WorkerLifecycleRepository {
    private let client: WorkerLifecycleClient

    init(client: WorkerLifecycleClient) {
        self.client = client
    }

    func overview(afterRevision: UInt64?) async throws -> CatalogWatchSnapshotDTO {
        try await client.overview(afterRevision: afterRevision)
    }

    func listResources(
        kind: WorkerLifecycleResourceKind,
        lifecycle: String?,
        limit: UInt64
    ) async throws -> ResourceListResultDTO {
        try await client.listResources(kind: kind, lifecycle: lifecycle, limit: limit)
    }

    func inspectResource(_ resourceId: String) async throws -> ResourceInspectResultDTO {
        try await client.inspectResource(resourceId)
    }

    func moduleActivityOverview(limit: UInt64) async throws -> ModuleActivityOverviewDTO {
        try await client.moduleActivityOverview(limit: limit)
    }

    func proposePackageChange(
        manifest: [String: AnyCodable],
        summary: String,
        sessionId: String?,
        workspaceId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerLifecycleResultDTO {
        try await client.proposePackageChange(
            manifest: manifest,
            summary: summary,
            sessionId: sessionId,
            workspaceId: workspaceId,
            idempotencyKey: idempotencyKey
        )
    }

    func installPackage(
        manifest: [String: AnyCodable],
        sessionId: String?,
        workspaceId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerLifecycleResultDTO {
        try await client.installPackage(
            manifest: manifest,
            sessionId: sessionId,
            workspaceId: workspaceId,
            idempotencyKey: idempotencyKey
        )
    }

    func enablePackage(
        packageId: String,
        packageVersion: String,
        reason: String?,
        sessionId: String?,
        workspaceId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerLifecycleResultDTO {
        try await client.enablePackage(
            packageId: packageId,
            packageVersion: packageVersion,
            reason: reason,
            sessionId: sessionId,
            workspaceId: workspaceId,
            idempotencyKey: idempotencyKey
        )
    }

    func disablePackage(
        packageId: String,
        packageVersion: String,
        reason: String?,
        sessionId: String?,
        workspaceId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerLifecycleResultDTO {
        try await client.disablePackage(
            packageId: packageId,
            packageVersion: packageVersion,
            reason: reason,
            sessionId: sessionId,
            workspaceId: workspaceId,
            idempotencyKey: idempotencyKey
        )
    }

    func launchWorker(
        packageId: String,
        packageVersion: String,
        reason: String?,
        sessionId: String?,
        workspaceId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerLifecycleResultDTO {
        try await client.launchWorker(
            packageId: packageId,
            packageVersion: packageVersion,
            reason: reason,
            sessionId: sessionId,
            workspaceId: workspaceId,
            idempotencyKey: idempotencyKey
        )
    }

    func stopWorker(
        launchAttemptResourceId: String,
        reason: String?,
        sessionId: String?,
        workspaceId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerLifecycleResultDTO {
        try await client.stopWorker(
            launchAttemptResourceId: launchAttemptResourceId,
            reason: reason,
            sessionId: sessionId,
            workspaceId: workspaceId,
            idempotencyKey: idempotencyKey
        )
    }

    func createCatalogDiscoveryReport(
        reason: String?,
        sessionId: String?,
        workspaceId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> CatalogDiscoveryReportResultDTO {
        try await client.createCatalogDiscoveryReport(
            reason: reason,
            includeProtectedCounts: true,
            sessionId: sessionId,
            workspaceId: workspaceId,
            idempotencyKey: idempotencyKey
        )
    }

    func retirePackage(
        packageId: String,
        packageVersion: String,
        reason: String?,
        sessionId: String?,
        workspaceId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerLifecycleResultDTO {
        try await client.retirePackage(
            packageId: packageId,
            packageVersion: packageVersion,
            reason: reason,
            sessionId: sessionId,
            workspaceId: workspaceId,
            idempotencyKey: idempotencyKey
        )
    }
}
