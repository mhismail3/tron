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

enum EngineClientStreamSubscriptionPolicy {
    static func shouldClearSubscriptions(previous: ConnectionState, next: ConnectionState) -> Bool {
        previous.isConnected && !next.isConnected
    }

    static func shouldResubscribe(
        previous: ConnectionState,
        next: ConnectionState,
        hasCurrentSession: Bool
    ) -> Bool {
        !previous.isConnected && next.isConnected && hasCurrentSession
    }

    static func sessionEventSubscriptionCursor(stored: EngineStreamCursor?) -> EngineStreamCursor? {
        // Session history is reconstructed through `session::reconstruct`.
        // `events.session` is the live lane and must not replay old events into
        // the view state machine after reconstruction.
        nil
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
    private var streamAckCoalescer = EngineStreamAckCoalescer()
    private var streamAckTasks: [String: Task<Void, Never>] = [:]

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

    /// Media operations client (transcription, browser)
    @ObservationIgnored
    lazy var media: MediaClient = MediaClient(transport: self)

    /// Settings operations client (server-authoritative settings)
    @ObservationIgnored
    lazy var settings: SettingsClient = SettingsClient(transport: self)

    /// Miscellaneous operations client (system, device, memory, message, logs)
    @ObservationIgnored
    lazy var misc: MiscClient = MiscClient(transport: self)

    /// Cron scheduling operations client (automations)
    @ObservationIgnored
    lazy var cron: CronClient = CronClient(transport: self)

    /// Notification inbox operations client
    @ObservationIgnored
    lazy var notifications: NotificationClient = NotificationClient(transport: self)

    /// Auth/provider operations client (API keys, OAuth tokens)
    @ObservationIgnored
    lazy var auth: AuthClient = AuthClient(transport: self)

    /// plugin source server management client (status, add, remove, enable, disable, restart, reload)
    @ObservationIgnored
    lazy var pluginSources: PluginSourceClient = PluginSourceClient(transport: self)

    /// Blob storage client (for Display capability image loading).
    @ObservationIgnored
    lazy var blob: BlobClient = BlobClient(transport: self)

    /// Display stream control client (stop streams on demand).
    @ObservationIgnored
    lazy var display: DisplayClient = DisplayClient(transport: self)

    /// Unified job management client (background, cancel, subscribe, unsubscribe).
    @ObservationIgnored
    lazy var job: JobClient = JobClient(transport: self)

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
            for task in streamAckTasks.values {
                task.cancel()
            }
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
            _ = try? await ensureSessionEventSubscription(sessionId: currentSessionId, workspaceId: nil)
        }
    }

    func disconnect() async {
        logger.info("Disconnecting from server", category: .engine)
        observationTask?.cancel()
        observationTask = nil
        currentSessionId = nil
        clearActiveStreamSubscriptions(reason: "explicit disconnect")
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
                let previousState = self.connectionState
                let nextState = ws.connectionState
                self.connectionState = nextState
                if EngineClientStreamSubscriptionPolicy.shouldClearSubscriptions(
                    previous: previousState,
                    next: nextState
                ) {
                    self.clearActiveStreamSubscriptions(reason: "engine transport left connected state")
                }
                if EngineClientStreamSubscriptionPolicy.shouldResubscribe(
                    previous: previousState,
                    next: nextState,
                    hasCurrentSession: self.currentSessionId != nil
                ), let currentSessionId = self.currentSessionId {
                    _ = try? await self.ensureSessionEventSubscription(sessionId: currentSessionId, workspaceId: nil)
                }

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
        clearActiveStreamSubscriptions(reason: "installing a new engine transport")
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

    /// Manual retry triggered from UI — runs an immediate probe, then rejoins
    /// the foreground reconnect loop if the server is still restarting.
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
        logger.debug(
            "Engine stream event delivered: type=\(eventType) topic=\(delivery.topic ?? "nil") subscription=\(delivery.subscriptionId ?? "nil") cursor=\(delivery.cursor?.rawValue.description ?? "nil") session=\(delivery.event.sessionId ?? "nil")",
            category: .events
        )

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

        // Handle plugin source status changed — notify observers so plugin source servers page refreshes
        if eventType == PluginSourceStatusChangedPlugin.eventType {
            NotificationCenter.default.post(name: .mcpStatusChanged, object: nil)
        }

        // Notifications are normal engine capabilities. When the notification
        // completion event arrives over `/engine`, refresh the inbox through
        // the same thin-client notification path APNs uses. APNs is still the
        // background transport; this foreground path keeps the notification
        // bell current without adding a second server API.
        if eventType == CapabilityInvocationCompletedPlugin.eventType,
           let result = eventV2.getResult() as? CapabilityInvocationCompletedPlugin.Result,
           result.identity.contractId == "notifications::send"
                || result.identity.functionId == "notifications::send" {
            logger.info(
                "Notification capability completion received from engine stream; refreshing notification inbox",
                category: .notification
            )
            NotificationCenter.default.post(name: .notificationReceived, object: nil)
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
        logger.info("Setting current engine session id to \(id ?? "nil")", category: .events)
        currentSessionId = id
        guard connectionState.isConnected, let id else { return }
        Task { @MainActor [weak self] in
            do {
                try await self?.ensureSessionEventSubscription(sessionId: id, workspaceId: nil)
            } catch {
                logger.warning(
                    "Failed to ensure session event subscription for \(id): \(error.localizedDescription)",
                    category: .events
                )
            }
        }
    }

    func setCurrentModel(_ model: String) {
        currentModel = model
    }

    @discardableResult
    func ensureSessionEventSubscription(sessionId: String, workspaceId: String?) async throws -> EngineSubscription {
        currentSessionId = sessionId
        return try await subscribeToSessionEvents(sessionId: sessionId, workspaceId: workspaceId)
    }

    private func subscribeToSessionEvents(sessionId: String, workspaceId: String?) async throws -> EngineSubscription {
        guard let ws = engineConnection else { throw EngineClientError.connectionNotEstablished }
        guard connectionState.isConnected else { throw EngineConnectionError.notConnected }
        let filters = Self.sessionEventFilters(sessionId: sessionId, workspaceId: workspaceId)
        let key = streamKey(
            topic: "events.session",
            sessionId: sessionId,
            workspaceId: workspaceId,
            filterHash: Self.sessionEventFilterHash(sessionId: sessionId, workspaceId: workspaceId)
        )
        if let existing = streamSubscriptions[key] {
            logger.debug(
                "Session event stream already subscribed for session \(sessionId): \(existing.subscriptionId)",
                category: .events
            )
            return existing
        }
        do {
            let cursor = EngineClientStreamSubscriptionPolicy.sessionEventSubscriptionCursor(
                stored: streamCursorStore.cursor(for: key)
            )
            let subscription = try await ws.subscribe(
                topic: key.topic,
                cursor: cursor,
                filters: filters,
                context: EngineInvocationContext(sessionId: sessionId, workspaceId: workspaceId)
            )
            let subscribedCursor = EngineStreamCursor(rawValue: subscription.cursor)
            streamCursorStore.save(subscribedCursor, for: key)
            streamSubscriptions[key] = subscription
            streamSubscriptionKeysById[subscription.subscriptionId] = key
            logger.info(
                "Subscribed to \(key.topic) for session \(sessionId) from live tail \(subscribedCursor.rawValue)",
                category: .events
            )
            return subscription
        } catch {
            logger.warning("Failed to subscribe to session events: \(error.localizedDescription)", category: .events)
            throw error
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
        scheduleStreamAck(subscriptionId: subscriptionId, cursor: cursor)
    }

    private func scheduleStreamAck(subscriptionId: String, cursor: EngineStreamCursor) {
        guard streamAckCoalescer.record(subscriptionId: subscriptionId, cursor: cursor) else {
            logger.verbose(
                "Coalesced engine stream ack for \(subscriptionId) through cursor \(cursor.rawValue)",
                category: .events
            )
            return
        }
        streamAckTasks[subscriptionId] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            await self?.flushStreamAck(subscriptionId: subscriptionId)
        }
    }

    private func flushStreamAck(subscriptionId: String) async {
        guard let cursor = streamAckCoalescer.takeForFlush(subscriptionId: subscriptionId) else {
            streamAckTasks[subscriptionId] = nil
            return
        }
        do {
            try await engineConnection?.ack(subscriptionId: subscriptionId, cursor: cursor)
            logger.verbose(
                "Acked engine stream \(subscriptionId) through cursor \(cursor.rawValue)",
                category: .events
            )
        } catch {
            logger.debug(
                "Engine stream coalesced ack failed for \(subscriptionId)@\(cursor.rawValue): \(error.localizedDescription)",
                category: .events
            )
        }
        streamAckTasks[subscriptionId] = nil
        if streamAckCoalescer.completeFlush(subscriptionId: subscriptionId) {
            scheduleStreamAck(subscriptionId: subscriptionId, cursor: cursor)
        }
    }

    private func clearActiveStreamSubscriptions(reason: String) {
        let subscriptionCount = streamSubscriptions.count
        let ackTaskCount = streamAckTasks.count
        for task in streamAckTasks.values {
            task.cancel()
        }
        streamAckTasks.removeAll()
        streamAckCoalescer.removeAll()
        streamSubscriptions.removeAll()
        streamSubscriptionKeysById.removeAll()
        if subscriptionCount > 0 || ackTaskCount > 0 {
            logger.info(
                "Cleared active engine stream state: subscriptions=\(subscriptionCount), pendingAckTasks=\(ackTaskCount), reason=\(reason)",
                category: .events
            )
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
