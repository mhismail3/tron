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
}

private struct EngineStreamSubscriptionKey: Hashable {
    let topic: String
    let sessionId: String?
    let workspaceId: String?
}

/// Coalesces connection-local stream acknowledgements per subscription.
struct EngineStreamAckCoalescer {
    private var latestBySubscription: [String: EngineStreamCursor] = [:]
    private var scheduledSubscriptions: Set<String> = []

    mutating func record(subscriptionId: String, cursor: EngineStreamCursor) -> Bool {
        if let existing = latestBySubscription[subscriptionId] {
            latestBySubscription[subscriptionId] = max(existing, cursor)
        } else {
            latestBySubscription[subscriptionId] = cursor
        }
        return scheduledSubscriptions.insert(subscriptionId).inserted
    }

    mutating func takeForFlush(subscriptionId: String) -> EngineStreamCursor? {
        latestBySubscription.removeValue(forKey: subscriptionId)
    }

    mutating func completeFlush(subscriptionId: String) -> Bool {
        scheduledSubscriptions.remove(subscriptionId)
        return latestBySubscription[subscriptionId] != nil
    }

    mutating func removeAll() {
        latestBySubscription.removeAll()
        scheduledSubscriptions.removeAll()
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
    private var streamSubscriptions: [EngineStreamSubscriptionKey: EngineSubscription] = [:]
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

    /// Event sync operations client
    @ObservationIgnored
    lazy var eventSync: EventSyncClient = EventSyncClient(transport: self)

    /// Settings operations client (server-authoritative settings)
    @ObservationIgnored
    lazy var settings: SettingsClient = SettingsClient(transport: self)

    /// System operations client
    @ObservationIgnored
    lazy var system: SystemClient = SystemClient(transport: self)

    /// Message mutation operations client
    @ObservationIgnored
    lazy var message: MessageClient = MessageClient(transport: self)

    /// Log evidence operations client
    @ObservationIgnored
    lazy var logs: LogsClient = LogsClient(transport: self)

    /// Auth/provider operations client (API keys, OAuth tokens)
    @ObservationIgnored
    lazy var auth: AuthClient = AuthClient(transport: self)

    /// Blob storage client (for Display tool image loading).
    @ObservationIgnored
    lazy var blob: BlobClient = BlobClient(transport: self)

    /// Engine-global worker-kernel operations.
    @ObservationIgnored
    lazy var workerKernel: WorkerKernelClient = WorkerKernelClient(transport: self)

    /// Session context visibility and context-boundary client.
    @ObservationIgnored

    /// Server-backed workspace browser for human workspace selection.
    @ObservationIgnored
    lazy var workspaceBrowser: WorkspaceBrowserClient = WorkspaceBrowserClient(transport: self)

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

    /// Bearer-token resolver re-evaluated for every WebSocket upgrade.
    @ObservationIgnored
    private let bearerTokenProvider: BearerTokenProvider?

    @ObservationIgnored
    private let sessionAttemptDirective: (URLRequest) -> EngineSessionAttemptDirective
    /// Server origin string (host:port) for tagging sessions
    var serverOrigin: String {
        let host = serverURL.host ?? "localhost"
        let port = serverURL.port ?? 8080
        return "\(host):\(port)"
    }

    init(
        serverURL: URL,
        bearerTokenProvider: BearerTokenProvider? = nil,
        sessionAttemptDirective: @escaping (URLRequest) -> EngineSessionAttemptDirective = { _ in
            .openLiveSession
        }
    ) {
        self.serverURL = serverURL
        self.bearerTokenProvider = bearerTokenProvider
        self.sessionAttemptDirective = sessionAttemptDirective
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

        // Set connecting before creating the transport so concurrent attempts bail out.
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

    func disconnect() {
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

    /// Continuation-based observation loop that mirrors the connection state.
    private func startConnectionStateObservation() {
        observationTask?.cancel()
        guard let observedConnection = engineConnection else { return }
        observationTask = Task { [weak self, observedConnection] in
            while !Task.isCancelled {
                // Sync current state FIRST, then register for next change.
                // This prevents missing the initial .connecting → .connected transition
                // when ws.connect() completes before this Task starts executing.
                var sessionToResubscribe: String?
                do {
                    guard !Task.isCancelled, let self else { return }
                    let previousState = connectionState
                    let nextState = observedConnection.connectionState
                    connectionState = nextState
                    if EngineClientStreamSubscriptionPolicy.shouldClearSubscriptions(
                        previous: previousState,
                        next: nextState
                    ) {
                        clearActiveStreamSubscriptions(reason: "engine transport left connected state")
                    }
                    if EngineClientStreamSubscriptionPolicy.shouldResubscribe(
                        previous: previousState,
                        next: nextState,
                        hasCurrentSession: currentSessionId != nil
                    ) {
                        sessionToResubscribe = currentSessionId
                    }
                }

                if let sessionToResubscribe {
                    guard !Task.isCancelled else { return }
                    _ = try? await self?.ensureSessionEventSubscription(
                        sessionId: sessionToResubscribe,
                        workspaceId: nil
                    )
                    // Re-read before installing the next observation so the
                    // final source state after subscription is reconciled.
                    continue
                }

                await waitForObservationChange {
                    observedConnection.connectionState
                }
            }
        }
    }

    private func installEngineConnection() -> EngineConnection {
        clearActiveStreamSubscriptions(reason: "installing a new engine transport")
        let ws = EngineConnection(
            serverURL: serverURL,
            bearerTokenProvider: bearerTokenProvider,
            sessionAttemptDirective: sessionAttemptDirective
        )
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
        disconnect()
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

        // Publish before acknowledging the upstream cursor. A full subscriber
        // buffer retains this newest event but evicts older live state, so queue
        // an explicit global recovery marker that drives source reconstruction.
        let droppedSubscriberDeliveries = _eventStream.send(eventV2)
        if droppedSubscriberDeliveries > 0 {
            logger.error(
                "Local live event buffer overflowed for \(droppedSubscriberDeliveries) subscriber(s); requiring reconstruction",
                category: .events
            )
            let result = StreamRecoveryRequiredPlugin.Result(
                reason: "client_buffer_overflow",
                droppedEventCount: UInt64(droppedSubscriberDeliveries)
            )
            let recoveryEvent = ParsedEventV2.plugin(
                type: StreamRecoveryRequiredPlugin.eventType,
                event: ParsedEventData(value: result),
                sessionId: nil,
                sequence: nil,
                transform: { result }
            )
            _eventStream.send(recoveryEvent)
        }

        recordAndAck(delivery)
    }

    // MARK: - State Accessors

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
        let key = EngineStreamSubscriptionKey(
            topic: "events.session",
            sessionId: sessionId,
            workspaceId: workspaceId
        )
        if let existing = streamSubscriptions[key] {
            logger.debug(
                "Session event stream already subscribed for session \(sessionId): \(existing.subscriptionId)",
                category: .events
            )
            return existing
        }
        do {
            // Session history is reconstructed through `session::reconstruct`.
            // `events.session` is a connection-local live lane, so reconnects
            // subscribe at the current topic tail instead of replaying a cursor.
            let subscription = try await ws.subscribe(
                topic: key.topic,
                cursor: nil,
                filters: filters,
                context: EngineInvocationContext(sessionId: sessionId, workspaceId: workspaceId)
            )
            streamSubscriptions[key] = subscription
            logger.info(
                "Subscribed to \(key.topic) for session \(sessionId) from live tail \(subscription.cursor)",
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

    private func recordAndAck(_ delivery: EngineEventDelivery) {
        guard let subscriptionId = delivery.subscriptionId,
              let cursor = delivery.cursor else { return }
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
        if subscriptionCount > 0 || ackTaskCount > 0 {
            logger.info(
                "Cleared active engine stream state: subscriptions=\(subscriptionCount), pendingAckTasks=\(ackTaskCount), reason=\(reason)",
                category: .events
            )
        }
    }

}
