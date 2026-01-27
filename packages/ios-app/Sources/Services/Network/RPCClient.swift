import Foundation
import Combine

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

@MainActor
class RPCClient: ObservableObject, RPCTransport {
    private(set) var webSocket: WebSocketService?
    private var cancellables = Set<AnyCancellable>()

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var currentSessionId: String?
    @Published private(set) var currentModel: String = "claude-opus-4-5-20251101"

    // MARK: - Domain Clients

    /// Session management client
    lazy var session: SessionClient = SessionClient(transport: self)

    /// Agent operations client
    lazy var agent: AgentClient = AgentClient(transport: self)

    /// Model operations client
    lazy var model: ModelClient = ModelClient(transport: self)

    /// Filesystem operations client
    lazy var filesystem: FilesystemClient = FilesystemClient(transport: self)

    /// Event sync operations client
    lazy var eventSync: EventSyncClient = EventSyncClient(transport: self)

    /// Context management client
    lazy var context: ContextClient = ContextClient(transport: self)

    /// Media operations client (transcription, voice notes, browser)
    lazy var media: MediaClient = MediaClient(transport: self)

    /// Miscellaneous operations client (system, skills, canvas, worktree, todo, device, memory, message)
    lazy var misc: MiscClient = MiscClient(transport: self)

    // MARK: - Unified Event Stream
    //
    // Plugin-based event system replaces 30+ individual callbacks.
    // Consumers subscribe once and handle events via switch on eventType:
    //
    //   rpcClient.eventPublisherV2
    //       .filter { event in event.matchesSession(mySessionId) }
    //       .sink { event in
    //           switch event.eventType { ... }
    //       }
    //
    private let _eventPublisherV2 = PassthroughSubject<ParsedEventV2, Never>()

    /// Publisher for plugin-based parsed WebSocket events.
    /// Events are published without session filtering - consumers filter as needed.
    var eventPublisherV2: AnyPublisher<ParsedEventV2, Never> {
        _eventPublisherV2.eraseToAnyPublisher()
    }

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
        cancellables.removeAll()
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

        // Publish event to unified stream
        _eventPublisherV2.send(eventV2)
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
