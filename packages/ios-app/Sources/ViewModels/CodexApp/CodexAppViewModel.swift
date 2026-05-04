import Foundation
import Observation

@Observable
@MainActor
final class CodexAppViewModel {
    typealias TransportFactory = @MainActor (CodexAppEndpoint, CodexBearerTokenProvider?) -> any CodexAppTransporting
    typealias ServerStatusProvider = @MainActor () async throws -> CodexAppServerStatusResult

    private let transportFactory: TransportFactory
    private var serverStatusProvider: ServerStatusProvider?
    private var transport: (any CodexAppTransporting)?
    private var client: CodexAppClient?
    private var activeServer: PairedServer?
    private var activeBearerToken: String?
    private var dashboardRefreshInFlight = false

    var activeConfig: CodexAppServerConfig?
    var activeEndpoint: CodexAppEndpoint?
    var serverStatus: CodexAppServerStatusResult?
    var connectionState: ConnectionState = .disconnected
    var state = CodexAppState()
    var isRefreshingDashboard = false
    var isLoadingThreads = false
    var isLoadingThread = false
    var isLoadingEarlierThreadEntries = false

    var hasEarlierThreadEntries: Bool {
        state.hasEarlierEntries
    }

    init(
        transportFactory: @escaping TransportFactory = { endpoint, tokenProvider in
            CodexJSONRPCTransport(endpoint: endpoint, bearerTokenProvider: tokenProvider)
        }
    ) {
        self.transportFactory = transportFactory
    }

    func configure(activeServer: PairedServer?, serverStatusProvider: ServerStatusProvider? = nil) {
        let previousServerId = self.activeServer?.id
        let serverChanged = previousServerId != activeServer?.id
        self.activeServer = activeServer
        self.serverStatusProvider = serverStatusProvider
        if serverChanged {
            let previousClient = client
            activeConfig = nil
            activeEndpoint = nil
            activeBearerToken = nil
            transport = nil
            client = nil
            if previousClient != nil {
                Task { await previousClient?.disconnect() }
            }
            state = CodexAppState()
            serverStatus = nil
            dashboardRefreshInFlight = false
        }
        guard activeServer != nil else {
            activeConfig = nil
            activeEndpoint = nil
            activeBearerToken = nil
            serverStatus = nil
            transport = nil
            client = nil
            connectionState = .failed(reason: CodexAppServerConfigError.noActiveServer.localizedDescription)
            return
        }

        guard serverStatusProvider != nil else {
            let previousClient = client
            activeConfig = nil
            activeEndpoint = nil
            activeBearerToken = nil
            transport = nil
            client = nil
            if previousClient != nil {
                Task { await previousClient?.disconnect() }
            }
            connectionState = .failed(reason: "Connect to the active Tron server before using Codex.")
            return
        }

        if previousServerId == activeServer?.id, client != nil {
            syncConnectionState()
            Task { await refreshDashboard() }
            return
        }

        connectionState = .disconnected
        Task { await refreshDashboard() }
    }

    func refreshManagedServerStatus() async throws {
        guard let provider = serverStatusProvider, let activeServer else {
            throw CodexAppServerConfigError.noActiveServer
        }
        try await refreshManagedServerStatus(using: provider, activeServer: activeServer)
    }

    private func refreshManagedServerStatus(
        using provider: ServerStatusProvider,
        activeServer: PairedServer
    ) async throws {
        let status = try await provider()
        guard self.activeServer?.id == activeServer.id else { return }
        serverStatus = status

        guard status.enabled else {
            clearTransport(reason: "Codex App Server is disabled in Tron server settings.")
            return
        }
        guard status.state == "running", let managedEndpoint = status.endpoint else {
            let reason = status.lastError ?? "Codex App Server is \(status.state)."
            clearTransport(reason: reason)
            return
        }

        var config = CodexAppServerConfig(
            serverId: activeServer.id,
            scheme: CodexAppScheme(rawValue: managedEndpoint.scheme) ?? .ws,
            hostOverride: managedEndpoint.host?.nilIfBlank,
            port: managedEndpoint.port,
            path: managedEndpoint.path,
            preferredCwd: status.defaults.preferredCwd ?? "",
            preferredModel: status.defaults.preferredModel ?? "",
            approvalPolicy: status.defaults.approvalPolicy,
            sandboxMode: status.defaults.sandboxMode,
            lastConnectedAt: activeConfig?.lastConnectedAt,
            lastUserAgent: activeConfig?.lastUserAgent,
            lastKnownStatus: activeConfig?.lastKnownStatus
        )
        if config.hostOverride == nil || config.hostOverride == "0.0.0.0" || config.hostOverride == "::" {
            config.hostOverride = activeServer.host
        }

        do {
            let endpoint = try config.endpoint(activeServer: activeServer)
            let bearerToken = managedEndpoint.bearerToken?.nilIfBlank
            if managedEndpoint.requiresToken, bearerToken == nil {
                throw CodexAppServerConfigError.missingRemoteToken
            }
            try endpoint.validateSecurity(token: bearerToken, allowInsecureLocalhost: true)
            let shouldRebuildTransport = activeEndpoint != endpoint
                || client == nil

            activeConfig = config
            activeEndpoint = endpoint
            activeBearerToken = bearerToken

            guard shouldRebuildTransport else {
                syncConnectionState()
                return
            }

            let previousClient = client
            transport = nil
            client = nil
            if previousClient != nil {
                Task { await previousClient?.disconnect() }
            }

            let transport = transportFactory(endpoint, { [weak self] in self?.activeBearerToken })
            transport.onNotification = { [weak self] notification in
                self?.handle(notification)
            }
            transport.onServerRequest = { [weak self] request in
                self?.handle(request)
            }
            self.transport = transport
            self.client = CodexAppClient(transport: transport)
            connectionState = transport.connectionState
        } catch {
            clearTransport(reason: error.localizedDescription)
        }
    }

    private func clearTransport(reason: String) {
        let previousClient = client
        let token = activeBearerToken
        activeConfig = nil
        activeEndpoint = nil
        activeBearerToken = nil
        transport = nil
        client = nil
        if previousClient != nil {
            Task { await previousClient?.disconnect() }
        }
        connectionState = .failed(reason: CodexAppSecretRedactor.redact(reason, token: token))
    }

    func refreshDashboard() async {
        guard !dashboardRefreshInFlight else { return }
        dashboardRefreshInFlight = true
        isRefreshingDashboard = true
        defer {
            dashboardRefreshInFlight = false
            isRefreshingDashboard = false
        }

        do {
            if activeEndpoint == nil || client == nil {
                try await refreshManagedServerStatus()
                guard activeEndpoint != nil, client != nil else {
                    return
                }
            }
            if !connectionState.isConnected {
                try await connect()
            }
            try await loadThreads()
        } catch {
            state.errorMessage = CodexAppSecretRedactor.redact(error.localizedDescription, token: activeBearerToken)
            if !connectionState.isConnected {
                connectionState = .failed(reason: state.errorMessage ?? error.localizedDescription)
            }
        }
    }

    func runDashboardAutoRefresh(interval: Duration = .seconds(10)) async {
        await refreshDashboard()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            if connectionState.isConnected {
                await refreshThreadsIfConnected()
            } else {
                await refreshDashboard()
            }
        }
    }

    func refreshThreadsIfConnected() async {
        guard connectionState.isConnected else { return }
        do {
            try await loadThreads()
        } catch {
            state.errorMessage = CodexAppSecretRedactor.redact(error.localizedDescription, token: activeBearerToken)
        }
    }

    func connect() async throws {
        if connectionState.isConnected {
            return
        }
        if client == nil {
            try await refreshManagedServerStatus()
        }
        guard let client else { throw CodexTransportError.notConnected }
        do {
            let initialize = try await client.connect()
            syncConnectionState()
            if var config = activeConfig {
                config.lastConnectedAt = Date()
                config.lastKnownStatus = "Connected"
                config.lastUserAgent = initialize.userAgent
                activeConfig = config
            }
        } catch {
            syncConnectionState()
            if case .unauthorized = connectionState {
                throw error
            }
            connectionState = .failed(reason: CodexAppSecretRedactor.redact(error.localizedDescription, token: activeBearerToken))
            throw error
        }
    }

    func disconnect() async {
        await client?.disconnect()
        syncConnectionState()
    }

    func loadThreads() async throws {
        guard let client else { throw CodexTransportError.notConnected }
        isLoadingThreads = true
        defer { isLoadingThreads = false }
        let response = try await client.listThreads()
        CodexAppReducer.apply(.threadsLoaded(response.threads.map(\.summary)), to: &state)
    }

    func prepareNewThread() {
        state.selectedThreadId = nil
        state.currentTurnId = nil
        state.entries.removeAll()
        state.earlierEntries.removeAll()
        state.messages.removeAll()
        state.earlierMessages.removeAll()
        state.items.removeAll()
        state.earlierItems.removeAll()
        state.pendingApprovals.removeAll()
        state.latestPlan = nil
        state.latestDiff = nil
        state.errorMessage = nil
        state.isDraftingNewThread = true
    }

    func openThread(_ threadId: String) async throws {
        state.selectedThreadId = threadId
        state.currentTurnId = nil
        state.entries.removeAll()
        state.earlierEntries.removeAll()
        state.messages.removeAll()
        state.earlierMessages.removeAll()
        state.items.removeAll()
        state.earlierItems.removeAll()
        state.pendingApprovals.removeAll()
        state.latestPlan = nil
        state.latestDiff = nil
        state.errorMessage = nil
        state.isDraftingNewThread = false
        isLoadingThread = true
        defer { isLoadingThread = false }
        try await resumeThread(threadId)
    }

    func loadEarlierThreadEntries() async {
        guard state.hasEarlierEntries, !isLoadingEarlierThreadEntries else { return }
        isLoadingEarlierThreadEntries = true
        defer { isLoadingEarlierThreadEntries = false }

        let batchSize = min(
            CodexAppHistoryWindow.additionalEntryBatchSize,
            state.earlierEntries.count
        )
        let startIndex = state.earlierEntries.count - batchSize
        let batch = Array(state.earlierEntries[startIndex...])
        state.earlierEntries.removeLast(batchSize)
        state.entries.insert(contentsOf: batch, at: 0)
        state.rebuildTranscriptCollections()
    }

    func resumeThread(_ threadId: String) async throws {
        guard let client else { throw CodexTransportError.notConnected }
        let response = try await client.resumeThread(threadId: threadId)
        CodexAppReducer.apply(.threadResumed(response.thread), to: &state)
    }

    func archiveThread(_ threadId: String) async throws {
        guard let client else { throw CodexTransportError.notConnected }
        try await client.archiveThread(threadId: threadId)
        CodexAppReducer.apply(.threadArchived(threadId), to: &state)
    }

    func sendText(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let client else { throw CodexTransportError.notConnected }

        let threadId: String
        if let selected = state.selectedThreadId {
            threadId = selected
        } else {
            let response = try await client.startThread(CodexThreadStartParams(
                model: activeConfig?.preferredModel.nilIfBlank,
                cwd: activeConfig?.preferredCwd.nilIfBlank,
                approvalPolicy: activeConfig?.approvalPolicy,
                sandbox: activeConfig?.sandboxMode
            ))
            let summary = response.thread.summary
            CodexAppReducer.apply(.threadStarted(summary), to: &state)
            threadId = summary.id
            Task { await refreshThreadsIfConnected() }
        }

        CodexAppReducer.apply(.userMessage(threadId: threadId, text: trimmed), to: &state)
        let response = try await client.startTurn(CodexTurnStartParams(
            threadId: threadId,
            input: [.text(trimmed)],
            cwd: activeConfig?.preferredCwd.nilIfBlank,
            approvalPolicy: activeConfig?.approvalPolicy,
            sandboxPolicy: nil,
            model: activeConfig?.preferredModel.nilIfBlank,
            effort: nil,
            summary: nil
        ))
        if let turn = response.turn {
            CodexAppReducer.apply(.turnStarted(threadId: threadId, turnId: turn.id), to: &state)
        }
    }

    func interrupt() async throws {
        guard let client else { throw CodexTransportError.notConnected }
        guard let threadId = state.selectedThreadId else { return }
        try await client.interruptTurn(threadId: threadId, turnId: state.currentTurnId)
        CodexAppReducer.apply(.turnCompleted(threadId: threadId, turnId: state.currentTurnId), to: &state)
    }

    func resolveApproval(_ request: CodexApprovalRequest, decision: CodexApprovalDecision) async throws {
        if let client {
            try await client.resolveApproval(request, decision: decision)
        } else if let transport {
            try await transport.respond(CodexJSONRPCServerResponse(id: request.requestId, result: ["decision": decision.payload]))
        }
        CodexAppReducer.apply(.approvalResolved(requestId: request.requestId), to: &state)
    }

    private func handle(_ notification: CodexJSONRPCNotification) {
        CodexAppReducer.apply(CodexAppReducer.event(from: notification), to: &state)
        syncConnectionState()
        if notification.method == "turn/completed"
            || notification.method == "thread/started"
            || notification.method == "thread/archived" {
            Task { await refreshThreadsIfConnected() }
        }
    }

    private func handle(_ request: CodexJSONRPCServerRequest) {
        guard let approval = CodexAppReducer.approval(from: request) else {
            return
        }
        CodexAppReducer.apply(.approvalRequested(approval), to: &state)
    }

    private func syncConnectionState() {
        if let transport {
            connectionState = transport.connectionState
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
