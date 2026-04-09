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
    weak var draftStore: DraftStore?

    // MARK: - Observable State

    private(set) var sessions: [CachedSession] = []
    private(set) var activeSessionId: String? {
        didSet {
            if activeSessionId != oldValue {
                logger.info("Active session changed: \(oldValue ?? "nil") → \(activeSessionId ?? "nil")", category: .session)
            }
        }
    }

    /// ID of the persistent chat session (if any)
    private(set) var chatSessionId: String?

    /// Whether to filter sessions by current server origin
    var filterByOrigin: Bool = true

    /// Current server origin from the RPC client
    var currentServerOrigin: String {
        rpcClient.serverOrigin
    }

    /// Handles synchronization of session events with the server
    @ObservationIgnored
    private(set) lazy var sessionSynchronizer: SessionSynchronizer = {
        SessionSynchronizer(rpcClient: rpcClient, eventDB: eventDB)
    }()

    /// Manages live streaming buffers for dashboard session cards
    @ObservationIgnored
    private(set) lazy var dashboardStreamManager = DashboardStreamManager()

    // MARK: - Processing State

    var processingSessionIds: Set<String> = [] {
        didSet {
            if processingSessionIds != oldValue {
                #if DEBUG || BETA
                let added = processingSessionIds.subtracting(oldValue)
                let removed = oldValue.subtracting(processingSessionIds)
                if !added.isEmpty {
                    logger.debug("Processing started for sessions: \(added.map { String($0.prefix(12)) + "..." }.joined(separator: ", "))", category: .session)
                }
                if !removed.isEmpty {
                    logger.debug("Processing completed for sessions: \(removed.map { String($0.prefix(12)) + "..." }.joined(separator: ", "))", category: .session)
                }
                #endif
            }
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
        sessionSynchronizer.updateRPCClient(client)
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
        case SessionProcessingChangedPlugin.eventType:
            if let sessionId = event.sessionId,
               let result = event.getResult() as? SessionProcessingChangedPlugin.Result {
                guard sessions.contains(where: { $0.id == sessionId }) else { break }
                setSessionProcessing(sessionId, isProcessing: result.isProcessing)
                if result.isProcessing {
                    dashboardStreamManager.handleEvent(.turnStart, sessionId: sessionId)
                } else {
                    dashboardStreamManager.handleEvent(.complete, sessionId: sessionId)
                    Task { await self.finalizeSessionCompletion(sessionId: sessionId) }
                }
            }

        case TurnStartPlugin.eventType:
            if let sessionId = event.sessionId {
                dashboardStreamManager.handleEvent(.turnStart, sessionId: sessionId)
            }

        case CompletePlugin.eventType:
            if let sessionId = event.sessionId {
                logger.info("Global: Session \(sessionId) completed processing", category: .session)
                setSessionProcessing(sessionId, isProcessing: false)
                dashboardStreamManager.handleEvent(.complete, sessionId: sessionId)
                Task { await self.finalizeSessionCompletion(sessionId: sessionId) }
            }

        case ErrorPlugin.eventType:
            if let sessionId = event.sessionId,
               let result = event.getResult() as? ErrorPlugin.Result {
                logger.info("Global: Session \(sessionId) error: \(result.message)", category: .session)
                setSessionProcessing(sessionId, isProcessing: false)
                dashboardStreamManager.handleEvent(.error(message: result.message), sessionId: sessionId)
                updateSessionDashboardInfo(
                    sessionId: sessionId,
                    lastAssistantResponse: "Error: \(String(result.message.prefix(100)))"
                )
            }

        // MARK: - Dashboard Streaming Events (routed via DashboardEvent)

        case TextDeltaPlugin.eventType:
            if let sessionId = event.sessionId,
               let result = event.getResult() as? TextDeltaPlugin.Result {
                dashboardStreamManager.handleEvent(.textDelta(delta: result.delta), sessionId: sessionId)
            }

        case ThinkingDeltaPlugin.eventType:
            if let sessionId = event.sessionId {
                dashboardStreamManager.handleEvent(.thinkingDelta, sessionId: sessionId)
            }

        case ToolStartPlugin.eventType:
            if let sessionId = event.sessionId,
               let result = event.getResult() as? ToolStartPlugin.Result {
                // SpawnSubagent tools have dedicated subagent lifecycle events
                // (subagentSpawned/subagentCompleted) — suppress tool chips to avoid duplicates
                guard result.toolName != "SpawnSubagent" else { break }
                dashboardStreamManager.handleEvent(
                    .toolStart(toolName: result.toolName, toolCallId: result.toolCallId, arguments: result.arguments),
                    sessionId: sessionId)
            }

        case ToolEndPlugin.eventType:
            if let sessionId = event.sessionId,
               let result = event.getResult() as? ToolEndPlugin.Result {
                guard result.toolName != "SpawnSubagent" else { break }
                dashboardStreamManager.handleEvent(
                    .toolEnd(toolName: result.toolName, toolCallId: result.toolCallId, success: result.success, durationMs: result.duration),
                    sessionId: sessionId)
            }

        case SubagentSpawnedPlugin.eventType:
            if let sessionId = event.sessionId,
               let result = event.getResult() as? SubagentSpawnedPlugin.Result {
                dashboardStreamManager.handleEvent(
                    .subagentSpawned(task: result.task, toolCallId: result.toolCallId, subagentSessionId: result.subagentSessionId),
                    sessionId: sessionId)
            }

        case SubagentCompletedPlugin.eventType:
            if let sessionId = event.sessionId,
               let result = event.getResult() as? SubagentCompletedPlugin.Result {
                dashboardStreamManager.handleEvent(
                    .subagentCompleted(turns: result.totalTurns, durationMs: result.duration, subagentSessionId: result.subagentSessionId),
                    sessionId: sessionId)
            }

        case SubagentFailedPlugin.eventType:
            if let sessionId = event.sessionId,
               let result = event.getResult() as? SubagentFailedPlugin.Result {
                dashboardStreamManager.handleEvent(
                    .subagentFailed(error: result.error, subagentSessionId: result.subagentSessionId),
                    sessionId: sessionId)
            }

        case TurnFailedPlugin.eventType:
            if let sessionId = event.sessionId,
               let result = event.getResult() as? TurnFailedPlugin.Result {
                dashboardStreamManager.handleEvent(.turnFailed(error: result.error), sessionId: sessionId)
            }

        // MARK: - Session Lifecycle Events

        case SessionUpdatedPlugin.eventType:
            if let result = event.getResult() as? SessionUpdatedPlugin.Result {
                handleSessionUpdated(result)
            }

        case SessionCreatedPlugin.eventType:
            if let result = event.getResult() as? SessionCreatedPlugin.Result {
                handleSessionCreated(result)
            }

        case SessionArchivedPlugin.eventType:
            if let result = event.getResult() as? SessionArchivedPlugin.Result {
                handleSessionArchived(result)
            }

        case SessionUnarchivedPlugin.eventType:
            if let result = event.getResult() as? SessionUnarchivedPlugin.Result {
                handleSessionUnarchived(result)
            }

        case SessionDeletedPlugin.eventType:
            if let result = event.getResult() as? SessionDeletedPlugin.Result {
                handleSessionDeleted(result)
            }

        default:
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
            if let response = result.lastAssistantResponse {
                session.lastAssistantResponse = response
            }
            if let serverLines = result.activityLines {
                session.lastActivityLines = serverLines.map { $0.toActivityLine() }
            }
        }

        // Also persist to local DB so the data survives app restarts
        if let session = sessions.first(where: { $0.id == sessionId }) {
            do {
                try eventDB.sessions.insert(session)
            } catch {
                logger.error("Failed to persist session update for \(sessionId): \(error)", category: .database)
            }
        }
    }

    /// Handle session.created: add new session to dashboard list
    private func handleSessionCreated(_ result: SessionCreatedPlugin.Result) {
        let sessionId = result.sessionId

        // Don't add if already in list (e.g., we created it locally)
        guard !sessions.contains(where: { $0.id == sessionId }) else { return }

        logger.info("Global: session.created for \(sessionId) from another device", category: .session)

        let isChat = result.isChat

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
            serverOrigin: rpcClient.serverOrigin,
            isChat: isChat
        )

        if isChat {
            chatSessionId = sessionId
        }

        // Prepend new session (most recent first)
        sessions.insert(newSession, at: 0)

        // Persist to local DB
        do {
            try eventDB.sessions.insert(newSession)
        } catch {
            logger.error("Failed to persist new session \(sessionId): \(error)", category: .database)
        }
    }

    /// Handle session.archived: remove session from dashboard list
    private func handleSessionArchived(_ result: SessionArchivedPlugin.Result) {
        let sessionId = result.sessionId
        logger.info("Global: session.archived for \(sessionId)", category: .session)

        // Clear chat session tracking if this was the chat
        if chatSessionId == sessionId {
            chatSessionId = nil
        }

        // Remove from in-memory list and clear stream buffer
        sessions.removeAll { $0.id == sessionId }
        dashboardStreamManager.clearBuffer(for: sessionId)

        // Remove from local DB
        do {
            try eventDB.events.deleteBySession(sessionId)
            try eventDB.sessions.delete(sessionId)
        } catch {
            logger.error("Failed to clean up archived session \(sessionId) from DB: \(error)", category: .database)
        }
    }

    /// Handle session.unarchived: re-fetch session from server and add to list
    private func handleSessionUnarchived(_ result: SessionUnarchivedPlugin.Result) {
        let sessionId = result.sessionId
        logger.info("Global: session.unarchived for \(sessionId)", category: .session)

        // Refresh from server to get the restored session
        Task { await refreshSessionList() }
    }

    /// Handle session.deleted: remove session from dashboard and local DB
    private func handleSessionDeleted(_ result: SessionDeletedPlugin.Result) {
        let sessionId = result.sessionId
        logger.info("Global: session.deleted for \(sessionId)", category: .session)

        sessions.removeAll { $0.id == sessionId }
        dashboardStreamManager.clearBuffer(for: sessionId)
        do {
            try eventDB.events.deleteBySession(sessionId)
            try eventDB.sessions.delete(sessionId)
        } catch {
            logger.error("Failed to clean up deleted session \(sessionId) from DB: \(error)", category: .database)
        }
    }

    // MARK: - State Setters (for extensions)

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

    /// Mark a session as deleting/not-deleting in the local array.
    func markSessionDeleting(_ sessionId: String, isDeleting: Bool) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[index].isDeleting = isDeleting
    }

    // MARK: - Session List (from EventDatabase)

    /// Debounce task for loadSessions — coalesces rapid calls
    @ObservationIgnored
    private var loadSessionsDebounceTask: Task<Void, Never>?
    /// Whether this is the first loadSessions call (skip debounce for initialize)
    @ObservationIgnored
    private var hasLoadedSessionsOnce = false

    /// Load sessions from local EventDatabase.
    /// Debounced: rapid calls within 100ms are coalesced into a single execution.
    /// First call (during initialize) executes immediately.
    func loadSessions() {
        if !hasLoadedSessionsOnce {
            hasLoadedSessionsOnce = true
            _loadSessionsImmediate()
            return
        }

        loadSessionsDebounceTask?.cancel()
        loadSessionsDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?._loadSessionsImmediate()
        }
    }

    /// Actual loadSessions implementation (called directly or after debounce).
    private func _loadSessionsImmediate() {
        do {
            // Preserve transient state that isn't persisted to DB
            var preservedState: [String: (activityLines: [ActivityLine]?, isProcessing: Bool?)] = [:]
            for session in sessions {
                preservedState[session.id] = (session.lastActivityLines, session.isProcessing)
            }

            // Filter by current server origin if enabled
            let origin = filterByOrigin ? currentServerOrigin : nil
            sessions = try eventDB.sessions.getByOrigin(origin)
            chatSessionId = sessions.first(where: { $0.isChat })?.id
            logger.info("Loaded \(self.sessions.count) sessions from EventDatabase (origin filter: \(origin ?? "none"), chat: \(chatSessionId ?? "none"))", category: .session)

            // Restore preserved transient state
            for i in sessions.indices {
                let sessionId = sessions[i].id

                if let preserved = preservedState[sessionId] {
                    sessions[i].isProcessing = preserved.isProcessing
                    if let activityLines = preserved.activityLines {
                        sessions[i].lastActivityLines = activityLines
                    }
                }

                if processingSessionIds.contains(sessionId) {
                    sessions[i].isProcessing = true
                }
            }
        } catch {
            logger.error("Failed to load sessions: \(error.localizedDescription)", category: .session)
            sessions = []
        }
    }

    /// Get sorted non-chat sessions (most recent first)
    var sortedSessions: [CachedSession] {
        sessions
            .filter { !$0.isChat }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// The persistent chat session (if any)
    var chatSession: CachedSession? {
        sessions.first { $0.isChat }
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
