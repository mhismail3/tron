import Foundation
import Combine

// NOTE: Uses global `logger` from TronLogger.swift (TronLogger.shared)
// Do NOT define a local logger property - it would shadow the global one

// MARK: - Tool Call Record (for persistence)

/// Tracks tool calls during a turn for event-sourced persistence
struct ToolCallRecord {
    let toolCallId: String
    let toolName: String
    let arguments: String
    var result: String?
    var isError: Bool = false
}

// MARK: - Event Store Manager

/// Central manager for event-sourced session state
/// Coordinates between EventDatabase (local SQLite) and RPCClient (server sync)
@MainActor
class EventStoreManager: ObservableObject {
    // Uses global `logger` from TronLogger.swift

    let eventDB: EventDatabase
    private(set) var rpcClient: RPCClient

    // MARK: - Published State

    @Published private(set) var sessions: [CachedSession] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncError: String?
    @Published private(set) var activeSessionId: String?

    /// Whether to filter sessions by current server origin
    @Published var filterByOrigin: Bool = true

    /// Current server origin from the RPC client
    var currentServerOrigin: String {
        rpcClient.serverOrigin
    }

    // Session change notification for views that need to react
    let sessionUpdated = PassthroughSubject<String, Never>()

    // MARK: - Turn Content Cache

    var turnContentCache: [String: (messages: [[String: Any]], timestamp: Date)] = [:]
    let maxCachedSessions = 10
    let cacheExpiry: TimeInterval = 120 // 2 minutes

    // MARK: - Processing State

    var processingSessionIds: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(processingSessionIds), forKey: "tron.processingSessionIds")
        }
    }

    var pollingTask: Task<Void, Never>?
    private(set) var isPollingActive = false

    /// Tracks whether the app is in the background to pause polling and save battery
    private(set) var isInBackground = false

    /// Cancellable for server settings subscription
    private var serverSettingsSubscription: AnyCancellable?

    // MARK: - Initialization

    init(eventDB: EventDatabase, rpcClient: RPCClient) {
        self.eventDB = eventDB
        self.rpcClient = rpcClient
        setupGlobalEventHandlers()
    }

    /// Update the RPC client (e.g., when server settings change)
    func updateRPCClient(_ client: RPCClient) {
        rpcClient = client
        setupGlobalEventHandlers()
        logger.info("RPC client updated to \(client.serverOrigin)", category: .session)
    }

    /// Subscribe to server settings changes to reload sessions with new filter
    func subscribeToServerChanges(_ publisher: PassthroughSubject<ServerSettingsChanged, Never>, appState: AppState) {
        serverSettingsSubscription = publisher.sink { [weak self, weak appState] change in
            Task { @MainActor in
                guard let self = self, let appState = appState else { return }
                logger.info("Server settings changed to \(change.serverOrigin), reloading sessions", category: .session)

                // Update the RPC client reference with the new one from AppState
                self.updateRPCClient(appState.rpcClient)

                // Reload sessions with new origin filter
                self.loadSessions()

                // Connect to the new server and sync
                Task {
                    await appState.rpcClient.connect()
                    await self.fullSync()
                }
            }
        }
    }

    /// Set up handlers for global events (events from all sessions)
    private func setupGlobalEventHandlers() {
        rpcClient.onGlobalProcessingStart = { [weak self] sessionId in
            Task { @MainActor in
                logger.info("Global: Session \(sessionId) started processing", category: .session)
                self?.setSessionProcessing(sessionId, isProcessing: true)
            }
        }

        rpcClient.onGlobalComplete = { [weak self] sessionId in
            Task { @MainActor in
                logger.info("Global: Session \(sessionId) completed processing", category: .session)
                self?.setSessionProcessing(sessionId, isProcessing: false)
                try? await self?.syncSessionEvents(sessionId: sessionId)
                self?.extractDashboardInfoFromEvents(sessionId: sessionId)
            }
        }

        rpcClient.onGlobalError = { [weak self] sessionId, message in
            Task { @MainActor in
                logger.info("Global: Session \(sessionId) error: \(message)", category: .session)
                self?.setSessionProcessing(sessionId, isProcessing: false)
                self?.updateSessionDashboardInfo(
                    sessionId: sessionId,
                    lastAssistantResponse: "Error: \(String(message.prefix(100)))"
                )
            }
        }
    }

    // MARK: - State Setters (for extensions)

    func setIsSyncing(_ value: Bool) {
        isSyncing = value
    }

    func setLastSyncError(_ value: String?) {
        lastSyncError = value
    }

    func clearLastSyncError() {
        lastSyncError = nil
    }

    func setIsPollingActive(_ value: Bool) {
        isPollingActive = value
    }

    func setIsInBackground(_ value: Bool) {
        isInBackground = value
    }

    func clearSessions() {
        sessions = []
    }

    func setSessions(_ newSessions: [CachedSession]) {
        sessions = newSessions
    }

    func updateSession(at index: Int, _ update: (inout CachedSession) -> Void) {
        guard sessions.indices.contains(index) else { return }
        update(&sessions[index])
    }

    func setActiveSessionId(_ sessionId: String?) {
        activeSessionId = sessionId
    }

    // MARK: - Session List (from EventDatabase)

    /// Load sessions from local EventDatabase
    func loadSessions() {
        do {
            // Preserve existing transient state before reloading
            var preservedDashboardInfo: [String: (prompt: String?, response: String?, toolCount: Int?, isProcessing: Bool?)] = [:]
            for session in sessions {
                preservedDashboardInfo[session.id] = (
                    session.lastUserPrompt,
                    session.lastAssistantResponse,
                    session.lastToolCount,
                    session.isProcessing
                )
            }

            // Filter by current server origin if enabled
            let origin = filterByOrigin ? currentServerOrigin : nil
            sessions = try eventDB.getSessionsByOrigin(origin)
            logger.info("Loaded \(self.sessions.count) sessions from EventDatabase (origin filter: \(origin ?? "none"))", category: .session)

            // Restore preserved transient state and extract dashboard info
            for i in sessions.indices {
                let sessionId = sessions[i].id

                if let preserved = preservedDashboardInfo[sessionId] {
                    sessions[i].isProcessing = preserved.isProcessing
                }

                if processingSessionIds.contains(sessionId) {
                    sessions[i].isProcessing = true
                }

                extractDashboardInfoFromEvents(sessionId: sessionId)
            }
        } catch {
            logger.error("Failed to load sessions: \(error.localizedDescription)", category: .session)
            sessions = []
        }
    }

    /// Get sorted sessions (most recent first)
    var sortedSessions: [CachedSession] {
        sessions.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// Get active session
    var activeSession: CachedSession? {
        guard let id = activeSessionId else { return nil }
        return sessions.first { $0.id == id }
    }

    /// Set the active session
    func setActiveSession(_ sessionId: String?) {
        activeSessionId = sessionId
        UserDefaults.standard.set(sessionId, forKey: "tron.activeSessionId")
    }

    /// Check if a session exists locally
    func sessionExists(_ sessionId: String) -> Bool {
        sessions.contains { $0.id == sessionId }
    }

    // MARK: - State Reconstruction (Unified Transformer)

    /// Get ChatMessages for a session using the unified transformer.
    func getChatMessages(sessionId: String) throws -> [ChatMessage] {
        guard let session = try eventDB.getSession(sessionId),
              let headEventId = session.headEventId else {
            return []
        }

        let events = try eventDB.getAncestors(headEventId)
        return UnifiedEventTransformer.transformPersistedEvents(events)
    }

    /// Get full reconstructed session state using the unified transformer.
    func getReconstructedState(sessionId: String) throws -> UnifiedEventTransformer.ReconstructedState {
        guard let session = try eventDB.getSession(sessionId) else {
            logger.warning("[RECONSTRUCT] Session not found: \(sessionId)", category: .session)
            return UnifiedEventTransformer.ReconstructedState()
        }

        guard let headEventId = session.headEventId else {
            logger.warning("[RECONSTRUCT] Session \(sessionId) has no headEventId", category: .session)
            return UnifiedEventTransformer.ReconstructedState()
        }

        logger.info("[RECONSTRUCT] Loading state for session \(sessionId), headEventId=\(headEventId)", category: .session)
        let events = try eventDB.getAncestors(headEventId)
        logger.info("[RECONSTRUCT] Got \(events.count) ancestor events", category: .session)

        let state = UnifiedEventTransformer.reconstructSessionState(from: events)
        logger.info("[RECONSTRUCT] Transformed to \(state.messages.count) messages", category: .session)
        return state
    }
}

// MARK: - Event Store Error

enum EventStoreError: LocalizedError {
    case sessionNotFound
    case eventNotFound(String)
    case invalidEventId(String)
    case operationFailed(String)
    case serverSyncFailed(String)

    var errorDescription: String? {
        switch self {
        case .sessionNotFound:
            return "Session not found"
        case .eventNotFound(let eventId):
            return "Event not found: \(eventId)"
        case .invalidEventId(let eventId):
            return "Invalid event ID: \(eventId)"
        case .operationFailed(let message):
            return "Operation failed: \(message)"
        case .serverSyncFailed(let message):
            return "Server sync failed: \(message)"
        }
    }
}
