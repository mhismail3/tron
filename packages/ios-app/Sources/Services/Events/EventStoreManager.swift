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
    @Published private(set) var activeSessionId: String? {
        didSet {
            if activeSessionId != oldValue {
                logger.info("Active session changed: \(oldValue ?? "nil") → \(activeSessionId ?? "nil")", category: .session)
            }
        }
    }

    /// Whether to filter sessions by current server origin
    @Published var filterByOrigin: Bool = true

    /// Current server origin from the RPC client
    var currentServerOrigin: String {
        rpcClient.serverOrigin
    }

    // Session change notification for views that need to react
    let sessionUpdated = PassthroughSubject<String, Never>()

    // MARK: - Turn Content Cache

    /// TTL-based cache for turn content used to enrich server events
    let turnContentCache = TurnContentCache()

    // MARK: - Polling Components

    /// Manages dashboard polling lifecycle with background suspension
    private(set) lazy var dashboardPoller: DashboardPoller = {
        let poller = DashboardPoller()
        poller.delegate = self
        return poller
    }()

    /// Checks session processing states from the server
    private(set) lazy var sessionStateChecker: SessionStateChecker = {
        SessionStateChecker(rpcClient: rpcClient)
    }()

    /// Handles synchronization of session events with the server
    private(set) lazy var sessionSynchronizer: SessionSynchronizer = {
        SessionSynchronizer(rpcClient: rpcClient, eventDB: eventDB, cache: turnContentCache)
    }()

    // MARK: - Processing State

    var processingSessionIds: Set<String> = [] {
        didSet {
            if processingSessionIds != oldValue {
                let added = processingSessionIds.subtracting(oldValue)
                let removed = oldValue.subtracting(processingSessionIds)
                if !added.isEmpty {
                    logger.debug("Processing started for sessions: \(added.map { String($0.prefix(12)) + "..." }.joined(separator: ", "))", category: .session)
                }
                if !removed.isEmpty {
                    logger.debug("Processing completed for sessions: \(removed.map { String($0.prefix(12)) + "..." }.joined(separator: ", "))", category: .session)
                }
            }
            UserDefaults.standard.set(Array(processingSessionIds), forKey: "tron.processingSessionIds")
        }
    }

    /// Cancellables for event stream subscription
    private var eventCancellables = Set<AnyCancellable>()

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

    /// Set up handlers for global events (events from all sessions)
    /// These events update dashboard state for ALL sessions, not just the active one.
    private func setupGlobalEventHandlers() {
        // Clear existing subscriptions to prevent duplicates when RPC client is updated
        eventCancellables.removeAll()

        // Subscribe to plugin-based event stream for global events
        // We don't filter by session ID here - we want events from ALL sessions
        rpcClient.eventPublisherV2
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleGlobalEventV2(event)
            }
            .store(in: &eventCancellables)
    }

    /// Handle global events for dashboard updates (plugin-based)
    private func handleGlobalEventV2(_ event: ParsedEventV2) {
        switch event.eventType {
        case TurnStartPlugin.eventType:
            // Processing started for a session
            if let sessionId = event.sessionId {
                logger.info("Global: Session \(sessionId) started processing", category: .session)
                setSessionProcessing(sessionId, isProcessing: true)
            }

        case CompletePlugin.eventType:
            // Processing completed for a session
            if let sessionId = event.sessionId {
                logger.info("Global: Session \(sessionId) completed processing", category: .session)
                setSessionProcessing(sessionId, isProcessing: false)
                Task {
                    try? await self.syncSessionEvents(sessionId: sessionId)
                    self.extractDashboardInfoFromEvents(sessionId: sessionId)
                }
            }

        case ErrorPlugin.eventType:
            // Error occurred in a session
            if let sessionId = event.sessionId,
               let result = event.getResult() as? ErrorPlugin.Result {
                logger.info("Global: Session \(sessionId) error: \(result.message)", category: .session)
                setSessionProcessing(sessionId, isProcessing: false)
                updateSessionDashboardInfo(
                    sessionId: sessionId,
                    lastAssistantResponse: "Error: \(String(result.message.prefix(100)))"
                )
            }

        default:
            // Other events are handled by session-specific subscribers
            break
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

    /// Remove a session from the local array by ID (for optimistic UI updates)
    /// Returns the removed session and its index for potential rollback
    func removeSessionLocally(_ sessionId: String) -> (session: CachedSession, index: Int)? {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else {
            return nil
        }
        let session = sessions[index]
        sessions.remove(at: index)
        return (session, index)
    }

    /// Insert a session back into the local array at a specific index (for rollback)
    func insertSessionLocally(_ session: CachedSession, at index: Int) {
        let clampedIndex = min(index, sessions.count)
        sessions.insert(session, at: clampedIndex)
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
            sessions = try eventDB.sessions.getByOrigin(origin)
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
        guard let session = try eventDB.sessions.get(sessionId),
              let headEventId = session.headEventId else {
            return []
        }

        let events = try eventDB.events.getAncestors(headEventId)
        return UnifiedEventTransformer.transformPersistedEvents(events)
    }

    /// Get full reconstructed session state using the unified transformer.
    func getReconstructedState(sessionId: String) throws -> ReconstructedState {
        guard let session = try eventDB.sessions.get(sessionId) else {
            logger.warning("[RECONSTRUCT] Session not found: \(sessionId)", category: .session)
            return ReconstructedState()
        }

        guard let headEventId = session.headEventId else {
            logger.warning("[RECONSTRUCT] Session \(sessionId) has no headEventId", category: .session)
            return ReconstructedState()
        }

        logger.info("[RECONSTRUCT] Loading state for session \(sessionId), headEventId=\(headEventId)", category: .session)
        let events = try eventDB.events.getAncestors(headEventId)
        logger.info("[RECONSTRUCT] Got \(events.count) ancestor events", category: .session)

        // Pass presorted: true because getAncestors returns events in correct chain order.
        // This is critical for forked sessions where sequence numbers reset per-session.
        let state = UnifiedEventTransformer.reconstructSessionState(from: events, presorted: true)
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
