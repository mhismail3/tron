import Foundation

// MARK: - Engine Client Errors

enum EngineClientError: Error, LocalizedError {
    case noActiveSession
    case invalidURL
    case connectionNotEstablished

    var errorDescription: String? {
        switch self {
        case .noActiveSession: return "No active session"
        case .invalidURL: return "Invalid server URL"
        case .connectionNotEstablished: return "Connection not established"
        }
    }
}

enum EngineClientConnectionPolicy {
    static func shouldSkipConnect(state: ConnectionState) -> Bool {
        switch state {
        case .connected, .connecting, .reconnecting, .deployRestarting:
            return true
        case .disconnected, .failed, .unauthorized:
            return false
        }
    }

    static func shouldDiscardExistingTransport(hasTransport: Bool, state: ConnectionState) -> Bool {
        hasTransport && !shouldSkipConnect(state: state)
    }
}

// MARK: - Engine Client

@Observable
@MainActor
final class EngineClient: EngineTransport {
    private(set) var engineConnection: EngineConnection?

    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var currentSessionId: String?
    private(set) var currentModel: String = ""
    private let streamCursorStore: EngineStreamCursorStore
    private var streamSubscriptions: [EngineStreamCursorKey: EngineSubscription] = [:]
    private var streamSubscriptionKeysById: [String: EngineStreamCursorKey] = [:]

    // MARK: - Domain Clients

    /// Session management client
    @ObservationIgnored
    lazy var session: SessionClient = SessionClient(transport: self)

    /// Agent operations client
    @ObservationIgnored
    lazy var agent: AgentClient = AgentClient(transport: self)

    /// Model operations client
    @ObservationIgnored
    lazy var model: ModelClient = ModelClient(transport: self)

    /// Filesystem operations client
    @ObservationIgnored
    lazy var filesystem: FilesystemClient = FilesystemClient(transport: self)

    /// Event sync operations client
    @ObservationIgnored
    lazy var eventSync: EventSyncClient = EventSyncClient(transport: self)

    /// Context management client
    @ObservationIgnored
    lazy var context: ContextClient = ContextClient(transport: self)

    /// Media operations client (transcription, voice notes, browser)
    @ObservationIgnored
    lazy var media: MediaClient = MediaClient(transport: self)

    /// Settings operations client (server-authoritative settings)
    @ObservationIgnored
    lazy var settings: SettingsClient = SettingsClient(transport: self)

    /// Miscellaneous operations client (system, device, memory, message, logs)
    @ObservationIgnored
    lazy var misc: MiscClient = MiscClient(transport: self)

    /// Worktree operations client (status, commits, merges, diffs, branches)
    @ObservationIgnored
    lazy var worktree: WorktreeClient = WorktreeClient(transport: self)

    /// Skill operations client (list, get, refresh, remove)
    @ObservationIgnored
    lazy var skill: SkillClient = SkillClient(transport: self)

    /// Sandbox container management client (list, start, stop, kill, remove)
    @ObservationIgnored
    lazy var sandbox: SandboxClient = SandboxClient(transport: self)

    /// Cron scheduling operations client (automations)
    @ObservationIgnored
    lazy var cron: CronClient = CronClient(transport: self)

    /// Prompt Library operations client (history + snippets)
    @ObservationIgnored
    lazy var promptLibrary: PromptLibraryClient = PromptLibraryClient(transport: self)

    /// Notification inbox operations client
    @ObservationIgnored
    lazy var notifications: NotificationClient = NotificationClient(transport: self)

    /// Auth/provider operations client (API keys, OAuth tokens)
    @ObservationIgnored
    lazy var auth: AuthClient = AuthClient(transport: self)

    /// MCP server management client (status, add, remove, enable, disable, restart, reload)
    @ObservationIgnored
    lazy var mcp: MCPClient = MCPClient(transport: self)

    /// Server-owned Codex App Server lifecycle discovery.
    @ObservationIgnored
    lazy var codexAppServer: CodexAppServerClient = CodexAppServerClient(transport: self)

    /// Blob storage client (for Display tool image loading).
    @ObservationIgnored
    lazy var blob: BlobClient = BlobClient(transport: self)

    /// Display stream control client (stop streams on demand).
    @ObservationIgnored
    lazy var display: DisplayClient = DisplayClient(transport: self)

    /// Claude Code session import client (discover, preview, execute).
    @ObservationIgnored
    lazy var importClient: ImportClient = ImportClient(transport: self)

    /// Unified job management client (background, cancel, subscribe, unsubscribe).
    @ObservationIgnored
    lazy var job: JobClient = JobClient(transport: self)

    /// Git workflow client — `git.syncMain`, `git.push`.
    @ObservationIgnored
    lazy var git: GitClient = GitClient(transport: self)

    /// Repo-scoped queries spanning sibling sessions.
    @ObservationIgnored
    lazy var repo: RepoClient = RepoClient(transport: self)

    // MARK: - Unified Event Stream
    //
    // Plugin-based event system replaces 30+ individual callbacks.
    // Consumers subscribe via async stream:
    //
    //   for await event in engineClient.events(for: mySessionId) {
    //       switch event.eventType { ... }
    //   }
    //
    @ObservationIgnored
    private let _eventStream = AsyncEventStream<ParsedEventV2>()

    private let serverURL: URL

    /// Bearer-token resolver passed through to the underlying `EngineConnection`
    /// on every `connect()`. Re-evaluated at upgrade time, so token rotations
    /// (e.g. user re-pairs after `.unauthorized`) flow through without
    /// recreating the EngineClient.
    @ObservationIgnored
    private let bearerTokenProvider: BearerTokenProvider?

    /// Server origin string (host:port) for tagging sessions
    var serverOrigin: String {
        let host = serverURL.host ?? "localhost"
        let port = serverURL.port ?? 8080
        return "\(host):\(port)"
    }

    init(
        serverURL: URL,
        bearerTokenProvider: BearerTokenProvider? = nil,
        streamCursorStore: EngineStreamCursorStore = EngineStreamCursorStore()
    ) {
        self.serverURL = serverURL
        self.bearerTokenProvider = bearerTokenProvider
        self.streamCursorStore = streamCursorStore
    }

    deinit {
        MainActor.assumeIsolated {
            observationTask?.cancel()
        }
    }

    // MARK: - Async Event Stream API

    /// Get an async stream of all events.
    /// Each call creates a new subscription.
    var events: AsyncStream<ParsedEventV2> {
        _eventStream.events
    }

    /// Get an async stream of events for a specific session.
    /// - Parameter sessionId: The session ID to filter events for
    /// - Returns: Filtered async stream of events
    func events(for sessionId: String?) -> AsyncStream<ParsedEventV2> {
        _eventStream.events(for: sessionId)
    }

    // MARK: - Connection

    func connect() async {
        // Also check connection state to prevent races during state transitions.
        // If we're already connecting or reconnecting, don't start another connection.
        if EngineClientConnectionPolicy.shouldSkipConnect(state: connectionState) {
            logger.debug("Connection already in progress (\(connectionState)), skipping", category: .engine)
            return
        }

        if EngineClientConnectionPolicy.shouldDiscardExistingTransport(
            hasTransport: engineConnection != nil,
            state: connectionState
        ) {
            logger.debug("Discarding stale WebSocket before connect (state: \(connectionState))", category: .engine)
            observationTask?.cancel()
            observationTask = nil
            engineConnection?.disconnect()
            engineConnection = nil
        }

        // Set connecting state BEFORE creating WebSocket to prevent concurrent attempts.
        // This is critical: if another connect() call comes in during the await below,
        // it will see .connecting state and bail out.
        connectionState = .connecting

        logger.info("Initializing connection to \(self.serverURL.absoluteString)", category: .engine)

        let ws = installEngineConnection()
        await ws.connect()

        // Sync state immediately — the observation task may not have run yet,
        // so it can miss the .connecting → .connected transition.
        connectionState = ws.connectionState
        if connectionState.isConnected, let currentSessionId {
            await subscribeToSessionEvents(sessionId: currentSessionId, workspaceId: nil)
        }
    }

    func disconnect() async {
        logger.info("Disconnecting from server", category: .engine)
        observationTask?.cancel()
        observationTask = nil
        currentSessionId = nil
        streamSubscriptions.removeAll()
        streamSubscriptionKeysById.removeAll()
        engineConnection?.disconnect()
        engineConnection = nil
        // Explicitly reset state to allow future connections.
        connectionState = .disconnected
    }

    @ObservationIgnored
    private var observationTask: Task<Void, Never>?

    /// Continuation-based observation loop that mirrors EngineConnection.connectionState.
    /// Cancelled in disconnect() — no recursive re-registration needed.
    /// Syncs state at the TOP of each iteration so the initial state is never missed.
    private func startConnectionStateObservation() {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                // Sync current state FIRST, then register for next change.
                // This prevents missing the initial .connecting → .connected transition
                // when ws.connect() completes before this Task starts executing.
                guard !Task.isCancelled, let self, let ws = self.engineConnection else { return }
                self.connectionState = ws.connectionState

                await withCheckedContinuation { cont in
                    withObservationTracking {
                        _ = ws.connectionState
                    } onChange: {
                        cont.resume()
                    }
                }
            }
        }
    }

    private func installEngineConnection() -> EngineConnection {
        let ws = EngineConnection(serverURL: serverURL, bearerTokenProvider: bearerTokenProvider)
        self.engineConnection = ws

        // Observe connection state via @Observable property.
        startConnectionStateObservation()

        // Set event handler callback — receives the neutral server event plus stream cursor metadata.
        ws.onEvent = { [weak self] delivery in
            self?.handleEventDelivery(delivery)
            // Engine responses are handled by EngineConnection via pendingRequests.
        }

        return ws
    }

    func reconnect() async {
        await disconnect()
        try? await Task.sleep(for: .milliseconds(500))
        await connect()
    }

    /// Forward background state to EngineConnection to pause heartbeats and save battery
    func setBackgroundState(_ inBackground: Bool) {
        engineConnection?.setBackgroundState(inBackground)
    }

    /// Verify connection is alive (proxy to EngineConnection).
    /// Returns true if connection responds to ping, false if dead.
    func verifyConnection() async -> Bool {
        guard let ws = engineConnection else { return false }
        return await ws.verifyConnection()
    }

    /// Manual retry triggered from UI — runs one short connection probe immediately.
    /// Use this when user taps the reconnection pill.
    func manualRetry() async {
        logger.info("Manual retry triggered from UI", category: .engine)

        let ws = engineConnection ?? installEngineConnection()
        await ws.manualRetry()
        connectionState = ws.connectionState
    }

    // MARK: - Event Handling

    private func handleEventDelivery(_ delivery: EngineEventDelivery) {
        let eventType = delivery.event.type

        // Parse event using plugin system (no re-parsing of JSON for type extraction)
        guard let eventV2 = EventRegistry.shared.parse(type: eventType, data: delivery.eventData) else {
            logger.warning("Failed to parse event: \(eventType)", category: .events)
            return
        }

        // Log connection events
        if eventType == ConnectedPlugin.eventType,
           let result = eventV2.getResult() as? ConnectedPlugin.Result {
            logger.info("Server version: \(result.version ?? "unknown")", category: .engine)
        }

        // Handle server restart notification at the transport level
        // (sets deploy-aware reconnection before any ChatViewModel sees the event)
        if eventType == ServerRestartingPlugin.eventType,
           let result = eventV2.getResult() as? ServerRestartingPlugin.Result {
            logger.info("Server restarting: reason=\(result.reason), commit=\(result.commit), expectedMs=\(result.restartExpectedMs)", category: .engine)
            engineConnection?.setDeployRestarting(expectedMs: result.restartExpectedMs)
        }

        // Handle auth updated — notify observers so Providers page refreshes
        if eventType == AuthUpdatedPlugin.eventType {
            NotificationCenter.default.post(name: .authDidUpdate, object: nil)
        }

        // Handle MCP status changed — notify observers so MCP servers page refreshes
        if eventType == MCPStatusChangedPlugin.eventType {
            NotificationCenter.default.post(name: .mcpStatusChanged, object: nil)
        }

        // Publish event to async stream
        _eventStream.send(eventV2)

        recordAndAck(delivery)
    }

    // extractEventType removed — type is now pre-extracted by EngineConnection.handleMessage

    // MARK: - State Accessors

    var isConnected: Bool {
        connectionState.isConnected
    }

    var hasActiveSession: Bool {
        currentSessionId != nil
    }

    // MARK: - EngineTransport Setters

    func invokeRead<P: Encodable, R: Decodable>(
        functionId: EngineFunctionId,
        payload: P,
        options: EngineInvocationOptions = EngineInvocationOptions()
    ) async throws -> R {
        let ws = try requireConnection()
        return try await ws.invokeRead(functionId: functionId, payload: payload, options: options)
    }

    func invokeWrite<P: Encodable, R: Decodable>(
        functionId: EngineFunctionId,
        payload: P,
        idempotencyKey: EngineIdempotencyKey,
        options: EngineInvocationOptions = EngineInvocationOptions()
    ) async throws -> R {
        let ws = try requireConnection()
        return try await ws.invokeWrite(
            functionId: functionId,
            payload: payload,
            idempotencyKey: idempotencyKey,
            options: options
        )
    }

    func setCurrentSessionId(_ id: String?) {
        currentSessionId = id
        guard connectionState.isConnected, let id else { return }
        Task { @MainActor [weak self] in
            await self?.subscribeToSessionEvents(sessionId: id, workspaceId: nil)
        }
    }

    func setCurrentModel(_ model: String) {
        currentModel = model
    }

    private func subscribeToSessionEvents(sessionId: String, workspaceId: String?) async {
        guard let ws = engineConnection, connectionState.isConnected else { return }
        let filters = Self.sessionEventFilters(sessionId: sessionId, workspaceId: workspaceId)
        let key = streamKey(
            topic: "events.session",
            sessionId: sessionId,
            workspaceId: workspaceId,
            filterHash: Self.sessionEventFilterHash(sessionId: sessionId, workspaceId: workspaceId)
        )
        guard streamSubscriptions[key] == nil else { return }
        do {
            let cursor = streamCursorStore.cursor(for: key)
            let subscription = try await ws.subscribe(
                topic: key.topic,
                cursor: cursor,
                filters: filters,
                context: EngineInvocationContext(sessionId: sessionId, workspaceId: workspaceId)
            )
            streamSubscriptions[key] = subscription
            streamSubscriptionKeysById[subscription.subscriptionId] = key
            logger.info(
                "Subscribed to \(key.topic) for session \(sessionId) from cursor \(cursor?.rawValue.description ?? "start")",
                category: .events
            )
        } catch {
            logger.warning("Failed to subscribe to session events: \(error.localizedDescription)", category: .events)
        }
    }

    static func sessionEventFilters(sessionId: String, workspaceId: String?) -> [String: AnyCodable] {
        var filters: [String: AnyCodable] = ["sessionId": AnyCodable(sessionId)]
        if let workspaceId {
            filters["workspaceId"] = AnyCodable(workspaceId)
        }
        return filters
    }

    static func sessionEventFilterHash(sessionId: String, workspaceId: String?) -> String {
        if let workspaceId {
            return "sessionId=\(sessionId);workspaceId=\(workspaceId)"
        }
        return "sessionId=\(sessionId)"
    }

    private func recordAndAck(_ delivery: EngineEventDelivery) {
        guard let topic = delivery.topic, let cursor = delivery.cursor else { return }
        let key = delivery.subscriptionId.flatMap { streamSubscriptionKeysById[$0] }
            ?? streamKey(
                topic: topic,
                sessionId: delivery.event.sessionId,
                workspaceId: delivery.event.workspaceId,
                filterHash: "none"
            )
        streamCursorStore.save(cursor, for: key)
        guard let subscriptionId = delivery.subscriptionId else { return }
        Task { @MainActor [weak self] in
            do {
                try await self?.engineConnection?.ack(subscriptionId: subscriptionId, cursor: cursor)
            } catch {
                logger.debug("Engine stream ack failed for \(subscriptionId)@\(cursor.rawValue): \(error.localizedDescription)", category: .events)
            }
        }
    }

    private func streamKey(
        topic: String,
        sessionId: String?,
        workspaceId: String?,
        filterHash: String
    ) -> EngineStreamCursorKey {
        EngineStreamCursorKey(
            serverOrigin: serverOrigin,
            topic: topic,
            sessionId: sessionId,
            workspaceId: workspaceId,
            filterHash: filterHash
        )
    }
}
