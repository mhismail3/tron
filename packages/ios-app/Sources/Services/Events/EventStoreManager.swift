import Foundation

// NOTE: Uses global `logger` from TronLogger.swift (TronLogger.shared)
// Do NOT define a local logger property - it would shadow the global one

// MARK: - Tool Call Record (for persistence)

/// Tracks tool calls during a turn for event-sourced persistence
struct ToolCallRecord {
    let toolCallId: String
    let toolName: String
    var arguments: String
    var result: String?
    var isError: Bool = false
}

// MARK: - Event Store Manager

/// Central manager for event-sourced session state
/// Coordinates between EventDatabase (local SQLite) and RPCClient (server sync)
@Observable
@MainActor
final class EventStoreManager {
    // Uses global `logger` from TronLogger.swift

    let eventDB: EventDatabase
    private(set) var rpcClient: RPCClient

    // MARK: - Observable State

    private(set) var sessions: [CachedSession] = []
    private(set) var isSyncing = false
    private(set) var lastSyncError: String?
    private(set) var activeSessionId: String? {
        didSet {
            if activeSessionId != oldValue {
                logger.info("Active session changed: \(oldValue ?? "nil") → \(activeSessionId ?? "nil")", category: .session)
            }
        }
    }

    /// Whether to filter sessions by current server origin
    var filterByOrigin: Bool = true

    /// Current server origin from the RPC client
    var currentServerOrigin: String {
        rpcClient.serverOrigin
    }

    // MARK: - Turn Content Cache

    /// TTL-based cache for turn content used to enrich server events
    let turnContentCache = TurnContentCache()

    // MARK: - Polling Components

    /// Manages dashboard polling lifecycle with background suspension
    @ObservationIgnored
    private(set) lazy var dashboardPoller: DashboardPoller = {
        let poller = DashboardPoller()
        poller.delegate = self
        return poller
    }()

    /// Checks session processing states from the server
    @ObservationIgnored
    private(set) lazy var sessionStateChecker: SessionStateChecker = {
        SessionStateChecker(rpcClient: rpcClient)
    }()

    /// Handles synchronization of session events with the server
    @ObservationIgnored
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

    /// Task for global event handling
    @ObservationIgnored
    private var globalEventTask: Task<Void, Never>?

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
        // Cancel existing task to prevent duplicates when RPC client is updated
        globalEventTask?.cancel()

        // Subscribe to async event stream for global events
        // We don't filter by session ID here - we want events from ALL sessions
        globalEventTask = Task { [weak self] in
            guard let self else { return }
            for await event in rpcClient.events {
                guard !Task.isCancelled else { break }
                self.handleGlobalEventV2(event)
            }
        }
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

        case SessionUpdatedPlugin.eventType:
            if let result = event.getResult() as? SessionUpdatedPlugin.Result {
                handleSessionUpdated(result)
            }

        case SessionCreatedPlugin.eventType:
            if let result = event.getResult() as? SessionCreatedPlugin.Result {
                handleSessionCreated(result)
            }

        default:
            // Other events are handled by session-specific subscribers
            break
        }
    }

    /// Handle session.updated: update existing session metadata in the dashboard list
    private func handleSessionUpdated(_ result: SessionUpdatedPlugin.Result) {
        let sessionId = result.sessionId
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else {
            // Session not in our list — might be a new session on another device.
            // Trigger a full list refresh to pick it up.
            logger.info("Global: session.updated for unknown session \(sessionId), refreshing list", category: .session)
            Task { await refreshSessionList() }
            return
        }

        logger.info("Global: session.updated for \(sessionId)", category: .session)
        updateSession(at: index) { session in
            if let title = result.title { session.title = title }
            if let model = result.model { session.latestModel = model }
            if let count = result.messageCount { session.messageCount = count }
            if let tokens = result.inputTokens { session.inputTokens = tokens }
            if let tokens = result.outputTokens { session.outputTokens = tokens }
            if let tokens = result.lastTurnInputTokens { session.lastTurnInputTokens = tokens }
            if let tokens = result.cacheReadTokens { session.cacheReadTokens = tokens }
            if let tokens = result.cacheCreationTokens { session.cacheCreationTokens = tokens }
            if let c = result.cost { session.cost = c }
            if let activity = result.lastActivity { session.lastActivityAt = activity }
            if let prompt = result.lastUserPrompt { session.lastUserPrompt = prompt }
            if let response = result.lastAssistantResponse { session.lastAssistantResponse = response }
        }

        // Also persist to local DB so the data survives app restarts
        if let session = sessions.first(where: { $0.id == sessionId }) {
            try? eventDB.sessions.insert(session)
        }
    }

    /// Handle session.created: add new session to dashboard list
    private func handleSessionCreated(_ result: SessionCreatedPlugin.Result) {
        let sessionId = result.sessionId

        // Don't add if already in list (e.g., we created it locally)
        guard !sessions.contains(where: { $0.id == sessionId }) else { return }

        logger.info("Global: session.created for \(sessionId) from another device", category: .session)

        let newSession = CachedSession(
            id: sessionId,
            workspaceId: result.workingDirectory ?? "",
            rootEventId: nil,
            headEventId: nil,
            title: result.title,
            latestModel: result.model ?? "unknown",
            workingDirectory: result.workingDirectory ?? "",
            createdAt: result.lastActivity,
            lastActivityAt: result.lastActivity,
            archivedAt: nil,
            eventCount: 0,
            messageCount: result.messageCount,
            inputTokens: result.inputTokens,
            outputTokens: result.outputTokens,
            lastTurnInputTokens: result.lastTurnInputTokens,
            cacheReadTokens: result.cacheReadTokens,
            cacheCreationTokens: result.cacheCreationTokens,
            cost: result.cost,
            isFork: result.parentSessionId != nil,
            serverOrigin: rpcClient.serverOrigin
        )

        // Prepend new session (most recent first)
        sessions.insert(newSession, at: 0)

        // Persist to local DB
        try? eventDB.sessions.insert(newSession)
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

    /// Load all events needed to reconstruct a session.
    /// Uses getBySession (single SQL query) instead of getAncestors (N+1 parent-chain walk)
    /// so that broken parent chains from sync gaps don't silently truncate history.
    /// For forked sessions, also fetches ancestor events from the parent session.
    func getSessionEvents(sessionId: String) throws -> (events: [SessionEvent], presorted: Bool) {
        guard let session = try eventDB.sessions.get(sessionId) else {
            return ([], false)
        }

        // Filter out locally-persisted stream.thinking_complete events.
        // ThinkingState persists these (seq 0, parentId nil) for the thinking history sheet.
        // They must not participate in reconstruction — thinking content is already embedded
        // in message.assistant content blocks via InterleavedContentProcessor.
        let sessionEvents = try eventDB.events.getBySession(sessionId)
            .filter { $0.type != "stream.thinking_complete" }
        guard !sessionEvents.isEmpty else { return ([], false) }

        // For forked sessions, fetch parent chain events and prepend them
        guard session.isFork == true,
              let firstEvent = sessionEvents.first,
              let parentId = firstEvent.parentId,
              !sessionEvents.contains(where: { $0.id == parentId }) else {
            return (sessionEvents, false)
        }

        let parentEvents = try eventDB.events.getAncestors(parentId)
        let combined = parentEvents + sessionEvents
        return (combined, true)
    }

    /// Get ChatMessages for a session using the unified transformer.
    func getChatMessages(sessionId: String) throws -> [ChatMessage] {
        let (events, _) = try getSessionEvents(sessionId: sessionId)
        return UnifiedEventTransformer.transformPersistedEvents(events)
    }

    /// Get full reconstructed session state using the unified transformer.
    func getReconstructedState(sessionId: String) throws -> ReconstructedState {
        let (events, presorted) = try getSessionEvents(sessionId: sessionId)
        guard !events.isEmpty else {
            logger.warning("[RECONSTRUCT] No events for session: \(sessionId)", category: .session)
            return ReconstructedState()
        }

        logger.info("[RECONSTRUCT] Loading state for session \(sessionId), \(events.count) events, presorted=\(presorted)", category: .session)
        let state = UnifiedEventTransformer.reconstructSessionState(from: events, presorted: presorted)
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
