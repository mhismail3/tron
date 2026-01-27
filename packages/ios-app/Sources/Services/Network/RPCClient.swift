import Foundation

// MARK: - RPC Client Errors

enum RPCClientError: Error, LocalizedError {
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

// MARK: - RPC Client

@Observable
@MainActor
final class RPCClient: RPCTransport {
    private(set) var webSocket: WebSocketService?

    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var currentSessionId: String?
    private(set) var currentModel: String = "claude-opus-4-5-20251101"

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

    /// Miscellaneous operations client (system, skills, canvas, worktree, todo, device, memory, message)
    @ObservationIgnored
    lazy var misc: MiscClient = MiscClient(transport: self)

    // MARK: - Unified Event Stream
    //
    // Plugin-based event system replaces 30+ individual callbacks.
    // Consumers subscribe via async stream:
    //
    //   for await event in rpcClient.events(for: mySessionId) {
    //       switch event.eventType { ... }
    //   }
    //
    @ObservationIgnored
    private let _eventStream = AsyncEventStream<ParsedEventV2>()

    private let serverURL: URL

    /// Server origin string (host:port) for tagging sessions
    var serverOrigin: String {
        let host = serverURL.host ?? "localhost"
        let port = serverURL.port ?? 8080
        return "\(host):\(port)"
    }

    init(serverURL: URL) {
        self.serverURL = serverURL
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
        // Prevent duplicate connections - check if WebSocket already exists.
        // This prevents race conditions where multiple connect() calls happen
        // before the first one completes (common during app startup when
        // multiple views call connect() simultaneously).
        if webSocket != nil {
            logger.debug("Already connected, skipping connect", category: .rpc)
            return
        }

        // Also check connection state to prevent races during state transitions.
        // If we're already connecting or reconnecting, don't start another connection.
        switch connectionState {
        case .connected, .connecting, .reconnecting:
            logger.debug("Connection already in progress (\(connectionState)), skipping", category: .rpc)
            return
        case .disconnected, .failed:
            break
        }

        // Set connecting state BEFORE creating WebSocket to prevent concurrent attempts.
        // This is critical: if another connect() call comes in during the await below,
        // it will see .connecting state and bail out.
        connectionState = .connecting

        logger.info("Initializing connection to \(self.serverURL.absoluteString)", category: .rpc)

        let ws = WebSocketService(serverURL: serverURL)
        self.webSocket = ws

        // Observe connection state via @Observable property
        startConnectionStateObservation()

        // Set event handler callback
        ws.onEvent = { [weak self] data in
            self?.handleEventData(data)
        }

        await ws.connect()
    }

    func disconnect() async {
        logger.info("Disconnecting from server", category: .rpc)
        currentSessionId = nil
        webSocket?.disconnect()
        webSocket = nil
        // Explicitly reset state to allow future connections.
        connectionState = .disconnected
    }

    /// Observe WebSocketService.connectionState using Swift Observation
    private func startConnectionStateObservation() {
        withObservationTracking {
            // Access the property to register for tracking
            _ = webSocket?.connectionState
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let ws = self.webSocket else { return }
                self.connectionState = ws.connectionState
                // Re-register for the next change
                self.startConnectionStateObservation()
            }
        }
    }

    func reconnect() async {
        await disconnect()
        try? await Task.sleep(for: .milliseconds(500))
        await connect()
    }

    /// Forward background state to WebSocketService to pause heartbeats and save battery
    func setBackgroundState(_ inBackground: Bool) {
        webSocket?.setBackgroundState(inBackground)
    }

    /// Verify connection is alive (proxy to WebSocketService).
    /// Returns true if connection responds to ping, false if dead.
    func verifyConnection() async -> Bool {
        guard let ws = webSocket else { return false }
        return await ws.verifyConnection()
    }

    /// Force reconnect - cleans up existing connection and creates fresh one.
    /// Use this when returning to foreground and connection is dead.
    func forceReconnect() async {
        logger.info("Force reconnecting...", category: .rpc)

        // Clean up existing connection
        webSocket?.disconnect()
        webSocket = nil
        connectionState = .disconnected

        // Small delay for cleanup
        try? await Task.sleep(for: .milliseconds(100))

        // Connect fresh
        await connect()
    }

    /// Manual retry triggered from UI - resets backoff and attempts connection immediately.
    /// Use this when user taps the reconnection pill.
    func manualRetry() async {
        logger.info("Manual retry triggered from UI", category: .rpc)

        // If webSocket exists, delegate to its manualRetry (handles cancellation of in-progress reconnection)
        if let ws = webSocket {
            await ws.manualRetry()
        } else {
            // WebSocket was cleaned up (nil) - create fresh connection
            // This can happen if disconnect() or forceReconnect() was called
            await connect()
        }
    }

    // MARK: - Event Handling

    private func handleEventData(_ data: Data) {
        // Extract event type for plugin dispatch
        guard let eventType = Self.extractEventType(from: data) else {
            logger.warning("Failed to extract event type from data", category: .events)
            return
        }

        // Parse event using plugin system
        guard let eventV2 = EventRegistry.shared.parse(type: eventType, data: data) else {
            logger.warning("Failed to parse event: \(eventType)", category: .events)
            return
        }

        // Log connection events
        if eventType == ConnectedPlugin.eventType,
           let result = eventV2.getResult() as? ConnectedPlugin.Result {
            logger.info("Server version: \(result.version ?? "unknown")", category: .rpc)
        }

        // Publish event to async stream
        _eventStream.send(eventV2)
    }

    /// Extract event type string from raw JSON data without full parsing.
    /// Used for efficient plugin dispatch.
    private static func extractEventType(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }
        return type
    }

    // MARK: - State Accessors

    var isConnected: Bool {
        connectionState.isConnected
    }

    var hasActiveSession: Bool {
        currentSessionId != nil
    }

    // MARK: - RPCTransport Setters

    func setCurrentSessionId(_ id: String?) {
        currentSessionId = id
    }

    func setCurrentModel(_ model: String) {
        currentModel = model
    }
}
