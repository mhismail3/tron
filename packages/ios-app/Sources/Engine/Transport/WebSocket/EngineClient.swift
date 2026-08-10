import Foundation

private struct EngineReadinessObservation: Equatable {
    let state: ConnectionState
    let continuityGeneration: UInt64
    let isInBackground: Bool
    let connectionIdentifier: ObjectIdentifier?
    let transportGeneration: UInt64?
    let isExplicitlyDisconnected: Bool
}

@Observable
@MainActor
final class EngineClient: EngineTransport {
    private enum ConnectionAttemptKind: Equatable {
        case connect
        case manualRetry
    }

    private(set) var engineConnection: EngineConnection?

    private(set) var connectionState: ConnectionState = .disconnected
    /// Monotonic ready-transport epoch observed by session projections. Unlike
    /// `connectionState`, this changes for a rapid connected-to-connected
    /// socket replacement and therefore cannot lose a catch-up request.
    private(set) var continuityGeneration: UInt64 = 0
    /// Distinguishes this server-bound client from a replacement whose local
    /// generation counter may happen to have the same value.
    let continuityOwnerId = UUID()
    private(set) var currentSessionId: String?
    private(set) var currentModel: String = ""
    private var streamSubscriptions: [EngineStreamSubscriptionKey: EngineSubscription] = [:]
    private var streamSubscriptionGeneration: UInt64 = 0
    private var sessionSubscriptionTasks: [
        EngineStreamSubscriptionKey: Task<EngineSubscription, any Error>
    ] = [:]
    private(set) var sessionSubscriptionInterests: [
        EngineStreamSubscriptionKey: Set<EngineSessionSubscriptionInterest>
    ] = [:]
    private var streamAckCoalescer = EngineStreamAckCoalescer()
    private var streamAckTasks: [String: Task<Void, Never>] = [:]
    private var workerEventSubscriptionTask: Task<Void, any Error>?
    /// Engine-global worker monitoring has no per-view release contract. Once
    /// requested, keep that intent across connection epochs just like session
    /// presentation/processing interests; explicit disconnect resets it.
    private(set) var workerEventSubscriptionsRequested = false
    private var workerProjectionInvalidationTask: Task<Void, Never>?
    private var workerProjectionInvalidations = WorkerProjectionInvalidationAccumulator()
    private var connectionAttemptTask: Task<Void, Never>?
    private var connectionAttemptKind: ConnectionAttemptKind?
    private var connectionAttemptGeneration: UInt64 = 0
    private var isInBackground = false
    /// Explicit retirement (server switch, shutdown, or a bounded borrowed
    /// client) is terminal until a caller intentionally invokes `connect` or
    /// `manualRetry`. Deferred reads must never resurrect a retired server.
    private var isExplicitlyDisconnected = false
    private var currentSessionInterestGeneration: UInt64 = 0
    /// Last socket generation whose connection-local subscription registry was
    /// reconciled. This catches rapid reconnects whose intermediate state is
    /// coalesced before observation samples it.
    private var readyTransportGeneration: UInt64?
    private var terminalFrameHandler: ((TerminalInboundFrame) -> Void)?

    var supportsNativeTerminal: Bool {
        engineConnection?.negotiatedCapabilities.contains("terminal.v1") == true
    }

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

    /// Authenticated fixed native-notification operations.
    @ObservationIgnored
    lazy var notifications: NotificationClient = NotificationClient(transport: self)

    /// Authenticated native PTY controls. Output remains socket-attached.
    @ObservationIgnored
    lazy var terminal: TerminalClient = TerminalClient(transport: self)

    func setTerminalFrameHandler(_ handler: ((TerminalInboundFrame) -> Void)?) {
        terminalFrameHandler = handler
        engineConnection?.onTerminalFrame = handler
    }

    func attachTerminal(_ terminalId: String, attachmentId: String, afterSequence: UInt64) async throws -> TerminalAttachResult {
        guard let engineConnection else { throw EngineClientError.connectionNotEstablished }
        return try await engineConnection.attachTerminal(terminalId: terminalId, attachmentId: attachmentId, afterSequence: afterSequence)
    }

    func detachTerminal(_ attachmentId: String) async {
        try? await engineConnection?.detachTerminal(attachmentId: attachmentId)
    }

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
            connectionAttemptTask?.cancel()
            workerEventSubscriptionTask?.cancel()
            workerProjectionInvalidationTask?.cancel()
            for task in sessionSubscriptionTasks.values {
                task.cancel()
            }
            for task in streamAckTasks.values {
                task.cancel()
            }
            _eventStream.finish()
            engineConnection?.disconnect()
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
        guard !isInBackground else {
            logger.debug("Connection request deferred while app is backgrounded", category: .engine)
            return
        }
        isExplicitlyDisconnected = false
        if let connectionAttemptTask {
            await connectionAttemptTask.value
            return
        }
        guard !connectionState.isConnected else { return }

        connectionAttemptGeneration &+= 1
        let generation = connectionAttemptGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performConnect()
        }
        connectionAttemptTask = task
        connectionAttemptKind = .connect
        await task.value
        if connectionAttemptGeneration == generation {
            connectionAttemptTask = nil
            connectionAttemptKind = nil
        }
    }

    private func performConnect() async {
        guard !isInBackground else { return }
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
        let liveAttemptGeneration = ws.liveSessionAttemptGeneration
        await ws.connect()
        guard !Task.isCancelled,
              !isInBackground,
              engineConnection === ws else { return }

        // Sync state immediately — the observation task may not have run yet,
        // so it can miss the .connecting → .connected transition.
        connectionState = ws.connectionState
        if connectionState.isConnected {
            recordReadyTransport(ws)
            await restoreInterestedStreamSubscriptions()
        } else if EngineClientConnectionPolicy.shouldOwnAutomaticRecovery(
            attemptedLiveSession: ws.liveSessionAttemptGeneration != liveAttemptGeneration,
            isInBackground: isInBackground,
            state: connectionState
        ) {
            // A cold launch can begin while cellular or the paired-server VPN
            // route is still waking. Keep the same foreground recovery
            // contract as an established socket loss instead of parking until
            // the user kills the app or taps Retry.
            ws.connectionState = .reconnecting(attempt: 0, nextRetrySeconds: 0)
            connectionState = ws.connectionState
            ws.startReconnectOwnership(deployRestart: false)
        }
    }

    func disconnect() {
        logger.info("Disconnecting from server", category: .engine)
        isExplicitlyDisconnected = true
        connectionAttemptGeneration &+= 1
        connectionAttemptTask?.cancel()
        connectionAttemptTask = nil
        connectionAttemptKind = nil
        observationTask?.cancel()
        observationTask = nil
        currentSessionId = nil
        sessionSubscriptionInterests.removeAll()
        workerEventSubscriptionsRequested = false
        clearActiveStreamSubscriptions(reason: "explicit disconnect")
        engineConnection?.disconnect()
        engineConnection = nil
        readyTransportGeneration = nil
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
                var shouldRestoreSessionSubscriptions = false
                do {
                    guard !Task.isCancelled, let self else { return }
                    let previousState = connectionState
                    let nextState = observedConnection.connectionState
                    let transportChanged = nextState.isConnected
                        && readyTransportGeneration
                            != observedConnection.transportGeneration
                    connectionState = nextState
                    if EngineClientStreamSubscriptionPolicy.shouldClearSubscriptions(
                        previous: previousState,
                        next: nextState,
                        transportChanged: transportChanged
                    ) {
                        clearActiveStreamSubscriptions(
                            reason: transportChanged
                                ? "engine transport generation changed"
                                : "engine transport left connected state"
                        )
                    }
                    if EngineClientStreamSubscriptionPolicy.shouldResubscribe(
                        previous: previousState,
                        next: nextState,
                        hasCurrentSession: !sessionSubscriptionInterests.isEmpty,
                        transportChanged: transportChanged
                    ) {
                        shouldRestoreSessionSubscriptions = true
                    }
                    if nextState.isConnected {
                        recordReadyTransport(observedConnection)
                    }
                }

                if shouldRestoreSessionSubscriptions {
                    guard !Task.isCancelled else { return }
                    await self?.restoreInterestedStreamSubscriptions()
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
        readyTransportGeneration = nil
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
        ws.onTerminalFrame = terminalFrameHandler

        return ws
    }

    func reconnect() async {
        disconnect()
        try? await Task.sleep(for: .milliseconds(500))
        await connect()
    }

    /// Treat a real process-background transition as a transport epoch boundary.
    ///
    /// The session subscription *interests* and selected session survive. Socket-
    /// local subscriptions, acknowledgements, pending RPCs, and observation work
    /// do not. A brand-new `EngineConnection` is installed on foreground so an
    /// opening task from the retired socket can never tear down its replacement.
    func setBackgroundState(_ inBackground: Bool) {
        isInBackground = inBackground
        guard inBackground else {
            engineConnection?.setBackgroundState(false)
            return
        }

        connectionAttemptGeneration &+= 1
        connectionAttemptTask?.cancel()
        connectionAttemptTask = nil
        connectionAttemptKind = nil
        observationTask?.cancel()
        observationTask = nil
        clearActiveStreamSubscriptions(reason: "app entered background")

        guard let ws = engineConnection else {
            readyTransportGeneration = nil
            connectionState = .disconnected
            return
        }

        if case .unauthorized = ws.connectionState {
            ws.setBackgroundState(true)
            readyTransportGeneration = nil
            connectionState = ws.connectionState
            return
        }

        ws.setBackgroundState(true)
        engineConnection = nil
        readyTransportGeneration = nil
        connectionState = .disconnected
    }

    /// Release background suspension and establish one authoritative
    /// foreground transport owner. This keeps lifecycle recovery inside the
    /// connection layer instead of requiring every app surface to kick it.
    func resumeFromBackground() async {
        guard !Task.isCancelled else { return }
        setBackgroundState(false)
        guard !Task.isCancelled, !isInBackground else { return }

        switch connectionState {
        case .connected:
            if !(await verifyConnection()) {
                logger.info(
                    "Foreground verification retired a stale connection; retrying",
                    category: .engine
                )
                await manualRetry()
            }
        case .disconnected, .failed:
            logger.info(
                "Starting foreground connection recovery from \(connectionState)",
                category: .engine
            )
            await manualRetry()
        case .connecting, .reconnecting, .deployRestarting:
            // The existing foreground owner is already making progress.
            break
        case .unauthorized:
            // Authorization is deliberately parked until re-pair.
            break
        }
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
        guard !isInBackground else {
            logger.debug("Manual retry deferred while app is backgrounded", category: .engine)
            return
        }
        isExplicitlyDisconnected = false

        if let connectionAttemptTask {
            let inFlightKind = connectionAttemptKind
            await connectionAttemptTask.value
            guard !Task.isCancelled else { return }
            if inFlightKind == .connect {
                switch connectionState {
                case .disconnected, .failed:
                    await manualRetry()
                case .connected, .connecting, .reconnecting, .deployRestarting, .unauthorized:
                    break
                }
            }
            return
        }

        connectionAttemptGeneration &+= 1
        let generation = connectionAttemptGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performManualRetry()
        }
        connectionAttemptTask = task
        connectionAttemptKind = .manualRetry
        await task.value
        if connectionAttemptGeneration == generation {
            connectionAttemptTask = nil
            connectionAttemptKind = nil
        }
    }

    private func performManualRetry() async {
        guard !isInBackground else { return }
        let ws = engineConnection ?? installEngineConnection()
        if observationTask == nil {
            startConnectionStateObservation()
        }
        await ws.manualRetry()
        guard !Task.isCancelled,
              !isInBackground,
              engineConnection === ws else { return }
        connectionState = ws.connectionState
        if connectionState.isConnected {
            recordReadyTransport(ws)
            await restoreInterestedStreamSubscriptions()
        }
    }

    private func recordReadyTransport(_ connection: EngineConnection) {
        let generation = connection.transportGeneration
        guard readyTransportGeneration != generation else { return }
        readyTransportGeneration = generation
        continuityGeneration &+= 1
        logger.info(
            "Engine continuity generation advanced to \(continuityGeneration)",
            category: .engine
        )
    }

    // MARK: - Event Handling

    private func handleEventDelivery(_ delivery: EngineEventDelivery) {
        let eventType = delivery.event.type
        logger.debug(
            "Engine stream event delivered: type=\(eventType) topic=\(delivery.topic ?? "nil") subscription=\(delivery.subscriptionId ?? "nil") cursor=\(delivery.cursor?.rawValue.description ?? "nil") session=\(delivery.event.sessionId ?? "nil")",
            category: .events
        )
        defer { recordAndAck(delivery) }

        if EngineClientStreamSubscriptionPolicy.isWorkerProjectionTopic(delivery.topic) {
            scheduleWorkerProjectionInvalidation(
                topic: delivery.topic,
                sessionId: delivery.event.sessionId
            )
            return
        }

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

    }

    /// One worker run emits several adjacent lifecycle facts. Collapse them
    /// into one authoritative projection read so UI observation never creates
    /// a request storm.
    private func scheduleWorkerProjectionInvalidation(
        topic: String?,
        sessionId: String?
    ) {
        workerProjectionInvalidations.record(topic: topic, sessionId: sessionId)
        guard workerProjectionInvalidationTask == nil else { return }
        workerProjectionInvalidationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            workerProjectionInvalidationTask = nil
            let invalidation = workerProjectionInvalidations.take()
            NotificationCenter.default.post(
                name: .workerRunProjectionInvalidated,
                object: invalidation
            )
            if invalidation.lifecycleChanged {
                NotificationCenter.default.post(
                    name: .workerLifecycleProjectionInvalidated,
                    object: invalidation
                )
            }
        }
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
        if options.readRecoveryPolicy == .currentTransport {
            if isExplicitlyDisconnected {
                throw EngineConnectionError.notConnected
            }
            let ws = try requireConnection()
            return try await ws.invokeRead(
                functionId: functionId,
                payload: payload,
                options: options
            )
        }

        var failedConnection: EngineConnection?
        var failedTransportGeneration: UInt64?

        while true {
            try Task.checkCancellation()

            if isExplicitlyDisconnected {
                throw EngineConnectionError.notConnected
            }
            let ws = try await readableConnection(
                excluding: failedConnection,
                transportGeneration: failedTransportGeneration
            )
            do {
                return try await ws.invokeRead(
                    functionId: functionId,
                    payload: payload,
                    options: options
                )
            } catch {
                guard !(error is CancellationError),
                      ConnectionErrorClassifier.requiresConnectionRecovery(error) else {
                    throw error
                }
                // Reads are side-effect free. If their socket epoch disappears,
                // wait for a different ready owner and replay the read. Writes
                // retain their explicit fail-fast/idempotency behavior below.
                failedConnection = ws
                failedTransportGeneration = ws.transportGeneration
                await ensureReadRecoveryOwner(for: ws)
                logger.debug(
                    "Deferring engine read until a replacement transport is ready",
                    category: .engine
                )
            }
        }
    }

    private func readableConnection(
        excluding failedConnection: EngineConnection?,
        transportGeneration failedTransportGeneration: UInt64?
    ) async throws -> EngineConnection {
        var requestedConnection = false
        while true {
            try Task.checkCancellation()

            if isExplicitlyDisconnected {
                throw EngineConnectionError.notConnected
            }

            if case .unauthorized(let reason) = connectionState {
                throw EngineConnectionError.unauthorized(reason)
            }

            if !isInBackground,
               connectionState.isConnected,
               let ws = engineConnection {
                let isFailedOwner = ws === failedConnection
                    && ws.transportGeneration == failedTransportGeneration
                if !isFailedOwner {
                    return ws
                }
            }

            if !isInBackground {
                switch connectionState {
                case .disconnected, .failed:
                    if !requestedConnection {
                        requestedConnection = true
                        await connect()
                        continue
                    }
                case .connecting, .connected, .reconnecting,
                     .deployRestarting, .unauthorized:
                    break
                }
            }

            await waitForObservationChange { [weak self] in
                self?.readinessObservation
            }
        }
    }

    /// A request can discover a broken socket before state observation or the
    /// heartbeat does. Ensure that case still has one reconnect owner before
    /// the read waits for a replacement epoch.
    private func ensureReadRecoveryOwner(for failedConnection: EngineConnection) async {
        guard !Task.isCancelled,
              !isInBackground,
              !isExplicitlyDisconnected,
              engineConnection === failedConnection else { return }

        switch failedConnection.connectionState {
        case .connected:
            if !(await failedConnection.verifyConnection()),
               !Task.isCancelled,
               !isInBackground,
               engineConnection === failedConnection {
                await manualRetry()
            }
        case .disconnected, .failed:
            await manualRetry()
        case .connecting, .reconnecting, .deployRestarting, .unauthorized:
            break
        }
    }

    private var readinessObservation: EngineReadinessObservation {
        EngineReadinessObservation(
            state: connectionState,
            continuityGeneration: continuityGeneration,
            isInBackground: isInBackground,
            connectionIdentifier: engineConnection.map(ObjectIdentifier.init),
            transportGeneration: engineConnection?.transportGeneration,
            isExplicitlyDisconnected: isExplicitlyDisconnected
        )
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
        let previousSessionId = currentSessionId
        guard previousSessionId != id else { return }
        currentSessionId = id
        currentSessionInterestGeneration &+= 1
        let generation = currentSessionInterestGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let previousSessionId {
                await releaseSessionEventInterest(
                    sessionId: previousSessionId,
                    workspaceId: nil,
                    interest: .presentation
                )
            }
            guard currentSessionInterestGeneration == generation,
                  currentSessionId == id,
                  let id else { return }
            do {
                _ = try await retainSessionEventSubscription(
                    sessionId: id,
                    workspaceId: nil,
                    interest: .presentation
                )
            } catch {
                if connectionState.isConnected {
                    logger.warning(
                        "Failed to ensure session event subscription for \(id): \(error.localizedDescription)",
                        category: .events
                    )
                }
            }
        }
    }

    func setCurrentModel(_ model: String) {
        currentModel = model
    }

    @discardableResult
    func ensureSessionEventSubscription(sessionId: String, workspaceId: String?) async throws -> EngineSubscription {
        try await retainSessionEventSubscription(
            sessionId: sessionId,
            workspaceId: workspaceId,
            interest: .presentation
        )
    }

    func releaseSessionEventSubscription(
        sessionId: String,
        workspaceId: String?
    ) async {
        await releaseSessionEventInterest(
            sessionId: sessionId,
            workspaceId: workspaceId,
            interest: .presentation
        )
    }

    func setProcessingSessionEventSubscription(
        sessionId: String,
        workspaceId: String?,
        isActive: Bool
    ) async throws {
        if isActive {
            _ = try await retainSessionEventSubscription(
                sessionId: sessionId,
                workspaceId: workspaceId,
                interest: .processing
            )
        } else {
            await releaseSessionEventInterest(
                sessionId: sessionId,
                workspaceId: workspaceId,
                interest: .processing
            )
        }
    }

    func ensureWorkerEventSubscriptions() async throws {
        workerEventSubscriptionsRequested = true
        if let workerEventSubscriptionTask {
            try await workerEventSubscriptionTask.value
            return
        }

        let generation = streamSubscriptionGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { throw EngineClientError.connectionNotEstablished }
            try await installWorkerEventSubscriptions(generation: generation)
        }
        workerEventSubscriptionTask = task
        do {
            try await task.value
            if streamSubscriptionGeneration == generation {
                workerEventSubscriptionTask = nil
            }
        } catch {
            if streamSubscriptionGeneration == generation {
                workerEventSubscriptionTask = nil
            }
            throw error
        }
    }

    private func installWorkerEventSubscriptions(generation: UInt64) async throws {
        guard let ws = engineConnection else { throw EngineClientError.connectionNotEstablished }
        guard connectionState.isConnected else { throw EngineConnectionError.notConnected }

        for topic in EngineClientStreamSubscriptionPolicy.workerProjectionTopics {
            let key = EngineStreamSubscriptionKey(
                topic: topic,
                sessionId: nil,
                workspaceId: nil
            )
            if streamSubscriptions[key] != nil {
                continue
            }
            // Worker history is available through bounded kernel reads. The
            // projection monitor only needs changes after this connection's
            // current durable tail.
            let subscription = try await ws.subscribe(
                topic: topic,
                cursor: nil
            )
            guard streamSubscriptionGeneration == generation,
                  engineConnection === ws,
                  connectionState.isConnected else {
                throw CancellationError()
            }
            streamSubscriptions[key] = subscription
        }
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
        if let pending = sessionSubscriptionTasks[key] {
            return try await pending.value
        }
        let generation = streamSubscriptionGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { throw EngineClientError.connectionNotEstablished }
            return try await createSessionEventSubscription(
                connection: ws,
                generation: generation,
                key: key,
                filters: filters,
                sessionId: sessionId,
                workspaceId: workspaceId
            )
        }
        sessionSubscriptionTasks[key] = task
        defer {
            if streamSubscriptionGeneration == generation {
                sessionSubscriptionTasks[key] = nil
            }
        }
        return try await task.value
    }

    private func retainSessionEventSubscription(
        sessionId: String,
        workspaceId: String?,
        interest: EngineSessionSubscriptionInterest
    ) async throws -> EngineSubscription {
        let key = EngineStreamSubscriptionKey(
            topic: "events.session",
            sessionId: sessionId,
            workspaceId: workspaceId
        )
        sessionSubscriptionInterests[key, default: []].insert(interest)
        do {
            return try await subscribeToSessionEvents(
                sessionId: sessionId,
                workspaceId: workspaceId
            )
        } catch {
            if !connectionState.isConnected
                || ConnectionErrorClassifier.isTransientTransport(error) {
                // Retain the domain interest so automatic reconnect can
                // restore exactly the sessions still presented or processing.
                // The observable connection state may still be stale-connected
                // when a request reports the transport failure first.
                throw error
            }
            sessionSubscriptionInterests[key]?.remove(interest)
            if sessionSubscriptionInterests[key]?.isEmpty == true {
                sessionSubscriptionInterests[key] = nil
            }
            throw error
        }
    }

    private func releaseSessionEventInterest(
        sessionId: String,
        workspaceId: String?,
        interest: EngineSessionSubscriptionInterest
    ) async {
        let key = EngineStreamSubscriptionKey(
            topic: "events.session",
            sessionId: sessionId,
            workspaceId: workspaceId
        )
        sessionSubscriptionInterests[key]?.remove(interest)
        guard sessionSubscriptionInterests[key]?.isEmpty != false else { return }
        sessionSubscriptionInterests[key] = nil
        guard let subscription = streamSubscriptions.removeValue(forKey: key) else { return }
        streamAckTasks.removeValue(forKey: subscription.subscriptionId)?.cancel()
        streamAckCoalescer.remove(subscriptionId: subscription.subscriptionId)
        guard connectionState.isConnected, let engineConnection else { return }
        do {
            _ = try await engineConnection.unsubscribe(
                subscriptionId: subscription.subscriptionId
            )
            logger.debug(
                "Released session event subscription for \(sessionId)",
                category: .events
            )
        } catch {
            logger.debug(
                "Session unsubscribe ended without acknowledgement for \(sessionId): \(error.localizedDescription)",
                category: .events
            )
        }
    }

    private func restoreInterestedSessionSubscriptions() async {
        let keys = Array(sessionSubscriptionInterests.keys)
        for key in keys where key.topic == "events.session" {
            guard connectionState.isConnected else { return }
            _ = try? await subscribeToSessionEvents(
                sessionId: key.sessionId ?? "",
                workspaceId: key.workspaceId
            )
        }
    }

    private func restoreInterestedStreamSubscriptions() async {
        await restoreInterestedSessionSubscriptions()
        guard connectionState.isConnected,
              workerEventSubscriptionsRequested else { return }
        do {
            try await ensureWorkerEventSubscriptions()
        } catch {
            logger.warning(
                "Failed to restore worker event subscriptions: \(error.localizedDescription)",
                category: .events
            )
        }
    }

    private func createSessionEventSubscription(
        connection ws: EngineConnection,
        generation: UInt64,
        key: EngineStreamSubscriptionKey,
        filters: [String: AnyCodable],
        sessionId: String,
        workspaceId: String?
    ) async throws -> EngineSubscription {
        guard engineConnection === ws,
              streamSubscriptionGeneration == generation,
              connectionState.isConnected else {
            throw EngineConnectionError.notConnected
        }
        do {
            // Session history is reconstructed through `session::reconstruct`.
            // `events.session` is a connection-local live lane, so reconnects
            // subscribe at the current topic tail instead of replaying a cursor.
            let subscription = try await ws.subscribe(
                topic: key.topic,
                cursor: nil,
                filters: filters,
                context: EngineInvocationContext(sessionId: sessionId, workspaceId: workspaceId),
                timeout: EngineSessionSynchronizationPolicy.requestTimeout
            )
            let shouldInstall = engineConnection === ws
                && streamSubscriptionGeneration == generation
                && sessionSubscriptionInterests[key]?.isEmpty == false
                && connectionState.isConnected
            guard shouldInstall else {
                if engineConnection === ws, connectionState.isConnected {
                    _ = try? await ws.unsubscribe(
                        subscriptionId: subscription.subscriptionId
                    )
                }
                throw CancellationError()
            }
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
            guard let engineConnection else {
                throw EngineConnectionError.notConnected
            }
            try await engineConnection.ack(subscriptionId: subscriptionId, cursor: cursor)
            logger.verbose(
                "Acked engine stream \(subscriptionId) through cursor \(cursor.rawValue)",
                category: .events
            )
        } catch {
            _ = streamAckCoalescer.record(
                subscriptionId: subscriptionId,
                cursor: cursor
            )
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
        streamSubscriptionGeneration &+= 1
        let subscriptionCount = streamSubscriptions.count
        let ackTaskCount = streamAckTasks.count
        workerEventSubscriptionTask?.cancel()
        workerEventSubscriptionTask = nil
        workerProjectionInvalidationTask?.cancel()
        workerProjectionInvalidationTask = nil
        workerProjectionInvalidations = WorkerProjectionInvalidationAccumulator()
        for task in sessionSubscriptionTasks.values {
            task.cancel()
        }
        sessionSubscriptionTasks.removeAll()
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
