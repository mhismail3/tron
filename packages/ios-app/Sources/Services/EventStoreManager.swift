import Foundation
import Combine
import os

// MARK: - Tool Call Record (for persistence)

/// Tracks tool calls during a turn for event-sourced persistence
/// Note: Duplicated from ChatViewModel for module independence
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
/// This is the SOLE source of truth for session data in the iOS app
@MainActor
class EventStoreManager: ObservableObject {
    private let logger = Logger(subsystem: "com.tron.mobile", category: "EventStoreManager")

    private let eventDB: EventDatabase
    private let rpcClient: RPCClient

    // MARK: - Published State

    @Published private(set) var sessions: [CachedSession] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncError: String?
    @Published private(set) var activeSessionId: String?

    // Session change notification for views that need to react
    let sessionUpdated = PassthroughSubject<String, Never>()

    // MARK: - Turn Content Cache
    // Caches full message content from agent.turn events for merging with server events
    // Key: sessionId, Value: tuple of (messages array, timestamp)
    // Bounded to prevent memory growth - entries expire after 2 minutes, max 10 sessions cached
    private var turnContentCache: [String: (messages: [[String: Any]], timestamp: Date)] = [:]
    private let maxCachedSessions = 10
    private let cacheExpiry: TimeInterval = 120 // 2 minutes

    // MARK: - Initialization

    init(eventDB: EventDatabase, rpcClient: RPCClient) {
        self.eventDB = eventDB
        self.rpcClient = rpcClient

        // Subscribe to global events for real-time dashboard updates
        setupGlobalEventHandlers()
    }

    /// Set up handlers for global events (events from all sessions)
    private func setupGlobalEventHandlers() {
        // When any session starts processing
        rpcClient.onGlobalProcessingStart = { [weak self] sessionId in
            Task { @MainActor in
                self?.logger.info("Global: Session \(sessionId) started processing")
                self?.setSessionProcessing(sessionId, isProcessing: true)
            }
        }

        // When any session completes processing
        rpcClient.onGlobalComplete = { [weak self] sessionId in
            Task { @MainActor in
                self?.logger.info("Global: Session \(sessionId) completed processing")
                self?.setSessionProcessing(sessionId, isProcessing: false)
                // Sync to get the latest response for the dashboard
                try? await self?.syncSessionEvents(sessionId: sessionId)
                self?.extractDashboardInfoFromEvents(sessionId: sessionId)
            }
        }

        // When any session has an error
        rpcClient.onGlobalError = { [weak self] sessionId, message in
            Task { @MainActor in
                self?.logger.info("Global: Session \(sessionId) error: \(message)")
                self?.setSessionProcessing(sessionId, isProcessing: false)
                // Update dashboard with error message
                self?.updateSessionDashboardInfo(
                    sessionId: sessionId,
                    lastAssistantResponse: "Error: \(String(message.prefix(100)))"
                )
            }
        }
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

            sessions = try eventDB.getAllSessions()
            logger.info("Loaded \(self.sessions.count) sessions from EventDatabase")

            // Restore preserved transient state and extract dashboard info
            for i in sessions.indices {
                let sessionId = sessions[i].id

                // Restore processing state (not stored in DB)
                if let preserved = preservedDashboardInfo[sessionId] {
                    sessions[i].isProcessing = preserved.isProcessing
                }

                // Also check processingSessionIds set
                if processingSessionIds.contains(sessionId) {
                    sessions[i].isProcessing = true
                }

                // Extract dashboard info from events (this will update prompt/response)
                extractDashboardInfoFromEvents(sessionId: sessionId)
            }
        } catch {
            logger.error("Failed to load sessions: \(error.localizedDescription)")
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
        // Persist to UserDefaults (this is a setting, not data)
        UserDefaults.standard.set(sessionId, forKey: "tron.activeSessionId")
    }

    /// Check if a session exists locally
    func sessionExists(_ sessionId: String) -> Bool {
        sessions.contains { $0.id == sessionId }
    }

    // MARK: - Sync with Server

    /// Full sync: fetch all sessions and their events from server
    func fullSync() async {
        guard !isSyncing else { return }

        isSyncing = true
        lastSyncError = nil
        logger.info("Starting full sync...")

        do {
            // First, fetch session list from server
            let serverSessions = try await rpcClient.listSessions(includeEnded: true)
            logger.info("Fetched \(serverSessions.count) sessions from server")

            // Convert and cache each session
            for serverSession in serverSessions {
                let cachedSession = serverSessionToCached(serverSession)
                try eventDB.insertSession(cachedSession)

                // Sync events for this session
                try await syncSessionEvents(sessionId: serverSession.sessionId)
            }

            // Reload local sessions
            loadSessions()
            logger.info("Full sync completed: \(self.sessions.count) sessions")

        } catch {
            lastSyncError = error.localizedDescription
            logger.error("Full sync failed: \(error.localizedDescription)")
        }

        isSyncing = false
    }

    /// Sync events for a specific session
    /// This is the primary way to get session data - server is source of truth
    /// Events are enriched with cached tool content from agent.turn events
    func syncSessionEvents(sessionId: String) async throws {
        logger.info("Syncing events for session \(sessionId)")

        // Get sync state to find cursor
        let syncState = try eventDB.getSyncState(sessionId)
        let afterEventId = syncState?.lastSyncedEventId

        // Fetch events since cursor from server (authoritative source)
        let result = try await rpcClient.getEventsSince(
            sessionId: sessionId,
            afterEventId: afterEventId,
            limit: 500
        )

        if !result.events.isEmpty {
            // Convert server events
            var events = result.events.map { rawEventToSessionEvent($0) }

            // Enrich events with cached tool content from agent.turn
            // This ensures tool_use and tool_result blocks are preserved
            events = try enrichEventsWithCachedContent(events: events, sessionId: sessionId)

            // Insert enriched events
            try eventDB.insertEvents(events)

            // Update sync state
            if let lastEvent = result.events.last {
                let newSyncState = SyncState(
                    key: sessionId,
                    lastSyncedEventId: lastEvent.id,
                    lastSyncTimestamp: ISO8601DateFormatter().string(from: Date()),
                    pendingEventIds: []
                )
                try eventDB.updateSyncState(newSyncState)
            }

            // Update session metadata (head event, counts)
            try await updateSessionMetadata(sessionId: sessionId)

            logger.info("Synced \(result.events.count) events for session \(sessionId)")
        }

        // If more events available, continue fetching
        if result.hasMore {
            try await syncSessionEvents(sessionId: sessionId)
        }
    }

    /// Full sync for a single session (fetch all events from scratch)
    func fullSyncSession(_ sessionId: String) async throws {
        logger.info("Full sync for session \(sessionId)")

        // Clear existing events
        try eventDB.deleteEventsBySession(sessionId)

        // Clear sync state
        let emptySyncState = SyncState(
            key: sessionId,
            lastSyncedEventId: nil,
            lastSyncTimestamp: nil,
            pendingEventIds: []
        )
        try eventDB.updateSyncState(emptySyncState)

        // Fetch all events
        let events = try await rpcClient.getAllEvents(sessionId: sessionId)
        let sessionEvents = events.map { rawEventToSessionEvent($0) }
        try eventDB.insertEvents(sessionEvents)

        // Update session metadata
        try await updateSessionMetadata(sessionId: sessionId)

        // Notify views
        sessionUpdated.send(sessionId)

        logger.info("Full synced \(events.count) events for session \(sessionId)")
    }

    // MARK: - Session Operations

    /// Create a new session (already created on server, just cache locally)
    func cacheNewSession(
        sessionId: String,
        workspaceId: String,
        model: String,
        workingDirectory: String
    ) throws {
        let now = ISO8601DateFormatter().string(from: Date())

        let session = CachedSession(
            id: sessionId,
            workspaceId: workspaceId,
            rootEventId: nil,
            headEventId: nil,
            status: .active,
            title: URL(fileURLWithPath: workingDirectory).lastPathComponent,
            model: model,
            provider: "anthropic",
            workingDirectory: workingDirectory,
            createdAt: now,
            lastActivityAt: now,
            eventCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0
        )

        try eventDB.insertSession(session)
        loadSessions()
        logger.info("Cached new session: \(sessionId)")
    }

    /// Delete a session (local + server)
    func deleteSession(_ sessionId: String) async throws {
        // Delete locally first
        try eventDB.deleteSession(sessionId)
        try eventDB.deleteEventsBySession(sessionId)

        // Try to delete from server (optional, may fail)
        do {
            _ = try await rpcClient.deleteSession(sessionId)
        } catch {
            logger.warning("Server delete failed (continuing): \(error.localizedDescription)")
        }

        // If this was the active session, clear it
        if activeSessionId == sessionId {
            setActiveSession(sessions.first?.id)
        }

        loadSessions()
        logger.info("Deleted session: \(sessionId)")
    }

    /// Update session metadata from event database
    private func updateSessionMetadata(sessionId: String) async throws {
        guard var session = try eventDB.getSession(sessionId) else { return }

        let events = try eventDB.getEventsBySession(sessionId)

        // Update counts
        session.eventCount = events.count
        session.messageCount = events.filter {
            $0.type == "message.user" || $0.type == "message.assistant"
        }.count

        // Update head event - use latest event from server (authoritative source)
        // All events should be from server (evt_* IDs) since we don't create local events
        if let lastEvent = events.last {
            session.headEventId = lastEvent.id
        }
        if let firstEvent = events.first {
            session.rootEventId = firstEvent.id
        }

        // Sum up token usage
        var inputTokens = 0
        var outputTokens = 0
        for event in events {
            if let usage = event.payload["tokenUsage"]?.value as? [String: Any] {
                inputTokens += (usage["inputTokens"] as? Int) ?? 0
                outputTokens += (usage["outputTokens"] as? Int) ?? 0
            }
        }
        session.inputTokens = inputTokens
        session.outputTokens = outputTokens

        // Update last activity
        if let lastEvent = events.last {
            session.lastActivityAt = lastEvent.timestamp
        }

        try eventDB.insertSession(session)
        loadSessions()
    }

    // MARK: - State Reconstruction

    /// Get messages at the current head of a session
    func getMessagesAtHead(_ sessionId: String) throws -> [DisplayMessage] {
        let state = try eventDB.getStateAtHead(sessionId)
        return state.messages.map { msg in
            DisplayMessage(
                id: UUID().uuidString,
                role: msg.role,
                content: msg.content,
                timestamp: Date()
            )
        }
    }

    /// Get full reconstructed state at head
    func getStateAtHead(_ sessionId: String) throws -> ReconstructedSessionState {
        try eventDB.getStateAtHead(sessionId)
    }

    /// Get messages at a specific event
    func getMessagesAtEvent(_ eventId: String) throws -> [DisplayMessage] {
        let messages = try eventDB.getMessagesAt(eventId)
        return messages.map { msg in
            DisplayMessage(
                id: UUID().uuidString,
                role: msg.role,
                content: msg.content,
                timestamp: Date()
            )
        }
    }

    // MARK: - Session Processing State

    /// Track which sessions are currently processing
    private var processingSessionIds: Set<String> = [] {
        didSet {
            // Persist to UserDefaults
            UserDefaults.standard.set(Array(processingSessionIds), forKey: "tron.processingSessionIds")
        }
    }

    /// Polling task for dashboard processing state
    private var pollingTask: Task<Void, Never>?

    /// Whether polling is currently active
    private var isPollingActive = false

    /// Mark a session as processing (agent is thinking)
    func setSessionProcessing(_ sessionId: String, isProcessing: Bool) {
        if isProcessing {
            processingSessionIds.insert(sessionId)
        } else {
            processingSessionIds.remove(sessionId)
        }

        // Update the session's processing flag
        if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[index].isProcessing = isProcessing
        }
    }

    /// Restore processing session IDs from persistence
    private func restoreProcessingSessionIds() {
        if let ids = UserDefaults.standard.array(forKey: "tron.processingSessionIds") as? [String] {
            processingSessionIds = Set(ids)
            // Update session flags
            for sessionId in processingSessionIds {
                if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
                    sessions[index].isProcessing = true
                }
            }
            let count = processingSessionIds.count
            logger.info("Restored \(count) processing session IDs")
        }
    }

    // MARK: - Dashboard Polling

    /// Start polling for session processing states (call when dashboard is visible)
    func startDashboardPolling() {
        guard !isPollingActive else { return }
        isPollingActive = true
        logger.info("Starting dashboard polling for session states")

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollAllSessionStates()
                try? await Task.sleep(for: .seconds(2)) // Poll every 2 seconds
            }
        }
    }

    /// Stop polling (call when leaving dashboard)
    func stopDashboardPolling() {
        guard isPollingActive else { return }
        isPollingActive = false
        pollingTask?.cancel()
        pollingTask = nil
        logger.info("Stopped dashboard polling")
    }

    /// Poll all sessions to check their processing state
    private func pollAllSessionStates() async {
        // Only check sessions that we think might be processing OR all sessions periodically
        // For efficiency, prioritize sessions marked as processing
        let sessionsToCheck = sessions.filter { session in
            // Check sessions marked as processing, or recently active sessions
            session.isProcessing == true || processingSessionIds.contains(session.id)
        }

        // Also do a periodic full check every 10 polls
        let shouldCheckAll = Int.random(in: 0..<10) == 0
        let checkList = shouldCheckAll ? sessions : (sessionsToCheck.isEmpty ? Array(sessions.prefix(3)) : sessionsToCheck)

        for session in checkList {
            await checkSessionProcessingState(sessionId: session.id)
        }
    }

    /// Check a single session's processing state from the server
    private func checkSessionProcessingState(sessionId: String) async {
        do {
            // Ensure we're connected
            if !rpcClient.isConnected {
                await rpcClient.connect()
                if !rpcClient.isConnected {
                    return
                }
            }

            // Need to temporarily resume the session to get its state
            // First save current session if any
            let previousSessionId = rpcClient.currentSessionId

            // Get agent state for this session
            let state = try await rpcClient.getAgentStateForSession(sessionId: sessionId)

            // Check if processing state changed
            let wasProcessing = processingSessionIds.contains(sessionId) || (sessions.first(where: { $0.id == sessionId })?.isProcessing == true)
            let isNowProcessing = state.isRunning

            if wasProcessing != isNowProcessing {
                logger.info("Session \(sessionId) processing state changed: \(wasProcessing) -> \(isNowProcessing)")
                setSessionProcessing(sessionId, isProcessing: isNowProcessing)

                // If processing just ended, sync to get latest content
                if wasProcessing && !isNowProcessing {
                    try? await syncSessionEvents(sessionId: sessionId)
                    extractDashboardInfoFromEvents(sessionId: sessionId)
                }
            }

            // Restore previous session if needed
            if let prevId = previousSessionId, prevId != sessionId {
                // Note: We don't need to re-resume since getAgentStateForSession
                // should work without changing the active session
            }
        } catch {
            // Silently fail - this is background polling
            logger.debug("Failed to check session \(sessionId) state: \(error.localizedDescription)")
        }
    }

    /// Update dashboard display fields for a session (last prompt, response, tool count)
    func updateSessionDashboardInfo(
        sessionId: String,
        lastUserPrompt: String? = nil,
        lastAssistantResponse: String? = nil,
        lastToolCount: Int? = nil
    ) {
        if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            if let prompt = lastUserPrompt {
                sessions[index].lastUserPrompt = prompt
            }
            if let response = lastAssistantResponse {
                sessions[index].lastAssistantResponse = response
            }
            if let toolCount = lastToolCount {
                sessions[index].lastToolCount = toolCount
            }
        }
    }

    /// Extract dashboard info from events after sync
    func extractDashboardInfoFromEvents(sessionId: String) {
        do {
            let events = try eventDB.getEventsBySession(sessionId)

            // Find the last user message
            if let lastUserEvent = events.last(where: { $0.type == "message.user" }) {
                let userPrompt = extractTextFromContent(lastUserEvent.payload["content"]?.value)
                if !userPrompt.isEmpty {
                    updateSessionDashboardInfo(sessionId: sessionId, lastUserPrompt: userPrompt)
                }
            }

            // Find the last assistant message and count tools
            if let lastAssistantEvent = events.last(where: { $0.type == "message.assistant" }) {
                var responseText = ""
                var toolCount = 0

                if let content = lastAssistantEvent.payload["content"]?.value {
                    if let text = content as? String {
                        responseText = text
                    } else if let blocks = content as? [[String: Any]] {
                        // Count tool blocks and extract text
                        for block in blocks {
                            if let type = block["type"] as? String {
                                if type == "tool_use" {
                                    toolCount += 1
                                } else if type == "text", let text = block["text"] as? String {
                                    if responseText.isEmpty {
                                        responseText = text
                                    }
                                }
                            }
                        }
                    } else if let blocks = content as? [Any] {
                        // Handle [Any] from AnyCodable decoding
                        for element in blocks {
                            if let block = element as? [String: Any],
                               let type = block["type"] as? String {
                                if type == "tool_use" {
                                    toolCount += 1
                                } else if type == "text", let text = block["text"] as? String {
                                    if responseText.isEmpty {
                                        responseText = text
                                    }
                                }
                            }
                        }
                    }
                }

                updateSessionDashboardInfo(
                    sessionId: sessionId,
                    lastAssistantResponse: responseText,
                    lastToolCount: toolCount > 0 ? toolCount : nil
                )
            }
        } catch {
            logger.error("Failed to extract dashboard info for session \(sessionId): \(error.localizedDescription)")
        }
    }

    /// Helper to extract text from content which can be String or array of content blocks
    private func extractTextFromContent(_ content: Any?) -> String {
        guard let content = content else { return "" }

        // Direct string
        if let text = content as? String {
            return text
        }

        // Array of content blocks [[String: Any]]
        if let blocks = content as? [[String: Any]] {
            var texts: [String] = []
            for block in blocks {
                if let type = block["type"] as? String, type == "text",
                   let text = block["text"] as? String {
                    texts.append(text)
                }
            }
            return texts.joined()
        }

        // Array of [Any] (from AnyCodable decoding)
        if let blocks = content as? [Any] {
            var texts: [String] = []
            for element in blocks {
                if let block = element as? [String: Any],
                   let type = block["type"] as? String, type == "text",
                   let text = block["text"] as? String {
                    texts.append(text)
                }
            }
            return texts.joined()
        }

        return ""
    }

    // MARK: - Turn Content Caching

    /// Cache full turn content from agent.turn event
    /// This captures tool_use and tool_result blocks that may not be in server events
    func cacheTurnContent(sessionId: String, turnNumber: Int, messages: [[String: Any]]) {
        let now = Date()

        // Clean expired entries first
        let expiredCount = turnContentCache.filter { now.timeIntervalSince($0.value.timestamp) > cacheExpiry }.count
        if expiredCount > 0 {
            turnContentCache = turnContentCache.filter { now.timeIntervalSince($0.value.timestamp) <= cacheExpiry }
            logger.debug("Cleaned \(expiredCount) expired cache entries")
        }

        // Enforce size limit (remove oldest if at limit and not updating existing session)
        if turnContentCache[sessionId] == nil && turnContentCache.count >= maxCachedSessions {
            if let oldest = turnContentCache.min(by: { $0.value.timestamp < $1.value.timestamp })?.key {
                turnContentCache.removeValue(forKey: oldest)
                logger.debug("Removed oldest cache entry for session \(oldest) to stay within limit")
            }
        }

        // Store messages with timestamp
        turnContentCache[sessionId] = (messages, now)
        logger.info("Cached turn \(turnNumber) content for session \(sessionId): \(messages.count) messages")

        // Log content block types for debugging
        for (idx, msg) in messages.enumerated() {
            let role = msg["role"] as? String ?? "unknown"
            if let content = msg["content"] as? [[String: Any]] {
                let types = content.compactMap { $0["type"] as? String }
                logger.debug("  Message \(idx) (\(role)): \(types.joined(separator: ", "))")
            } else if let text = msg["content"] as? String {
                logger.debug("  Message \(idx) (\(role)): text (\(text.count) chars)")
            }
        }
    }

    /// Get cached turn content for enriching server events
    private func getCachedTurnContent(sessionId: String) -> [[String: Any]]? {
        guard let cached = turnContentCache[sessionId] else { return nil }
        // Check if expired
        if Date().timeIntervalSince(cached.timestamp) > cacheExpiry {
            turnContentCache.removeValue(forKey: sessionId)
            logger.debug("Cache entry for session \(sessionId) expired, removed")
            return nil
        }
        return cached.messages
    }

    /// Clear cached turn content after successful enrichment
    private func clearCachedTurnContent(sessionId: String) {
        turnContentCache.removeValue(forKey: sessionId)
        logger.debug("Cleared turn content cache for session \(sessionId)")
    }

    /// Enrich server events with cached turn content
    /// Server events may lack full tool content; this merges in the rich content from agent.turn
    private func enrichEventsWithCachedContent(events: [SessionEvent], sessionId: String) throws -> [SessionEvent] {
        guard let cachedMessages = getCachedTurnContent(sessionId: sessionId) else {
            return events // No cached content to merge
        }

        var enrichedEvents = events
        var enrichedCount = 0

        // Build a lookup of cached content by role
        // We'll match assistant messages with their rich content
        let cachedAssistantMessages = cachedMessages.filter { ($0["role"] as? String) == "assistant" }

        // Find message.assistant events that might need enrichment
        for (idx, event) in enrichedEvents.enumerated() {
            guard event.type == "message.assistant" else { continue }

            // Check if event has simplified content (just text, no tool blocks)
            let hasToolBlocks = checkForToolBlocks(in: event.payload)

            if !hasToolBlocks {
                // Try to find matching cached content with tool blocks
                // Use the last cached assistant message that has tool blocks
                if let richContent = cachedAssistantMessages.last,
                   let contentBlocks = richContent["content"] as? [[String: Any]],
                   contentBlocks.contains(where: { ($0["type"] as? String) == "tool_use" }) {

                    // Create enriched payload
                    var enrichedPayload = event.payload
                    enrichedPayload["content"] = AnyCodable(contentBlocks)

                    // Create new event with enriched payload
                    let enrichedEvent = SessionEvent(
                        id: event.id,
                        parentId: event.parentId,
                        sessionId: event.sessionId,
                        workspaceId: event.workspaceId,
                        type: event.type,
                        timestamp: event.timestamp,
                        sequence: event.sequence,
                        payload: enrichedPayload
                    )

                    enrichedEvents[idx] = enrichedEvent
                    enrichedCount += 1
                    logger.info("Enriched event \(event.id) with \(contentBlocks.count) content blocks")
                }
            }
        }

        if enrichedCount > 0 {
            logger.info("Enriched \(enrichedCount) events with cached tool content for session \(sessionId)")
            // Clear cache after successful enrichment
            clearCachedTurnContent(sessionId: sessionId)
        }

        return enrichedEvents
    }

    /// Check if event payload has tool_use or tool_result blocks
    private func checkForToolBlocks(in payload: [String: AnyCodable]) -> Bool {
        guard let content = payload["content"]?.value else { return false }

        // Content could be a string (no tool blocks) or array of blocks
        if content is String { return false }

        if let blocks = content as? [[String: Any]] {
            return blocks.contains { block in
                let type = block["type"] as? String
                return type == "tool_use" || type == "tool_result"
            }
        }

        if let blocks = content as? [Any] {
            return blocks.contains { element in
                if let block = element as? [String: Any] {
                    let type = block["type"] as? String
                    return type == "tool_use" || type == "tool_result"
                }
                return false
            }
        }

        return false
    }

    // MARK: - Tree Operations (Fork/Rewind)

    /// Fork a session at a specific event (or HEAD if nil)
    /// Creates a new independent session branching from the specified point
    func forkSession(_ sessionId: String, fromEventId: String? = nil) async throws -> String {
        logger.info("[FORK] Starting fork: sessionId=\(sessionId), fromEventId=\(fromEventId ?? "HEAD")")

        // Get current session state for logging
        if let session = try? eventDB.getSession(sessionId) {
            logger.info("[FORK] Source session state: headEventId=\(session.headEventId ?? "nil"), eventCount=\(session.eventCount)")
        }

        // Call server with the specific event ID
        let result = try await rpcClient.forkSession(sessionId, fromEventId: fromEventId)

        logger.info("[FORK] Server returned: newSessionId=\(result.newSessionId)")

        // Sync the new forked session to get all its events
        logger.info("[FORK] Syncing new session events...")
        try await fullSyncSession(result.newSessionId)

        // Verify the sync worked
        if let newSession = try? eventDB.getSession(result.newSessionId) {
            let events = try? eventDB.getEventsBySession(result.newSessionId)
            logger.info("[FORK] New session synced: headEventId=\(newSession.headEventId ?? "nil"), eventCount=\(events?.count ?? 0)")
        }

        logger.info("[FORK] Fork complete: \(sessionId) → \(result.newSessionId) from event \(fromEventId ?? "HEAD")")
        return result.newSessionId
    }

    /// Rewind a session to a specific event
    /// Moves the HEAD pointer back, making events after this point "orphaned"
    /// Events are NOT deleted - they remain accessible in history
    func rewindSession(_ sessionId: String, toEventId: String) async throws {
        logger.info("[REWIND] Starting rewind: sessionId=\(sessionId), toEventId=\(toEventId)")

        // Get current session state for comparison
        guard var session = try eventDB.getSession(sessionId) else {
            logger.error("[REWIND] Session not found: \(sessionId)")
            throw EventStoreError.sessionNotFound
        }

        let previousHeadEventId = session.headEventId
        logger.info("[REWIND] Current HEAD: \(previousHeadEventId ?? "nil")")

        // Validate the target event exists and is an ancestor
        guard let targetEvent = try eventDB.getEvent(toEventId) else {
            logger.error("[REWIND] Target event not found: \(toEventId)")
            throw EventStoreError.eventNotFound(toEventId)
        }

        // Verify target belongs to this session
        guard targetEvent.sessionId == sessionId else {
            logger.error("[REWIND] Target event \(toEventId) belongs to different session: \(targetEvent.sessionId)")
            throw EventStoreError.invalidEventId(toEventId)
        }

        logger.info("[REWIND] Target event valid: type=\(targetEvent.type), sequence=\(targetEvent.sequence)")

        // Call server FIRST to ensure server state is updated
        logger.info("[REWIND] Calling server to update HEAD...")
        let result = try await rpcClient.rewindSession(sessionId, toEventId: toEventId)
        logger.info("[REWIND] Server confirmed: newHeadEventId=\(result.newHeadEventId), previousHead=\(result.previousHeadEventId ?? "unknown")")

        // Now update local state to match server
        session.headEventId = toEventId
        try eventDB.insertSession(session)
        logger.info("[REWIND] Local HEAD updated: \(previousHeadEventId ?? "nil") → \(toEventId)")

        // Log the ancestor chain for verification
        let ancestors = try eventDB.getAncestors(toEventId)
        logger.info("[REWIND] New ancestor chain has \(ancestors.count) events")

        // Notify views to refresh
        sessionUpdated.send(sessionId)
        loadSessions()

        logger.info("[REWIND] Rewind complete: session \(sessionId) HEAD moved from \(previousHeadEventId ?? "nil") to \(toEventId)")
    }

    /// Get events for a session
    func getSessionEvents(_ sessionId: String) throws -> [SessionEvent] {
        try eventDB.getEventsBySession(sessionId)
    }

    /// Get tree visualization for a session
    func getTreeVisualization(_ sessionId: String) throws -> [EventTreeNode] {
        try eventDB.buildTreeVisualization(sessionId)
    }

    // MARK: - Utilities

    /// Convert server SessionInfo to CachedSession
    private func serverSessionToCached(_ info: SessionInfo) -> CachedSession {
        CachedSession(
            id: info.sessionId,
            workspaceId: info.workingDirectory ?? "",
            rootEventId: nil,
            headEventId: nil,
            status: info.isActive ? .active : .ended,
            title: info.displayName,
            model: info.model,
            provider: "anthropic",
            workingDirectory: info.workingDirectory ?? "",
            createdAt: info.createdAt,
            lastActivityAt: info.createdAt,
            eventCount: 0,
            messageCount: info.messageCount,
            inputTokens: 0,
            outputTokens: 0
        )
    }

    /// Convert RawEvent to SessionEvent
    private func rawEventToSessionEvent(_ raw: RawEvent) -> SessionEvent {
        SessionEvent(
            id: raw.id,
            parentId: raw.parentId,
            sessionId: raw.sessionId,
            workspaceId: raw.workspaceId,
            type: raw.type,
            timestamp: raw.timestamp,
            sequence: raw.sequence,
            payload: raw.payload
        )
    }

    // MARK: - Lifecycle

    /// Initialize on app launch
    func initialize() {
        // NOTE: We intentionally do NOT restore activeSessionId on cold launch.
        // When the app is opened from a closed state, we always show the dashboard.
        // When resuming from background, SwiftUI state is preserved in memory.
        // The UserDefaults value is only used for potential future features.
        activeSessionId = nil

        // Load sessions from local DB
        loadSessions()

        // Restore which sessions were processing when app was closed
        // This allows us to resume checking their state
        restoreProcessingSessionIds()

        logger.info("EventStoreManager initialized with \(self.sessions.count) sessions")
    }

    /// Clear all local data
    func clearAll() throws {
        try eventDB.clearAll()
        sessions = []
        activeSessionId = nil
        UserDefaults.standard.removeObject(forKey: "tron.activeSessionId")
        logger.info("Cleared all local data")
    }

    /// Repair the database by removing duplicate events.
    /// Call this on app launch to fix any accumulated duplicates.
    func repairDuplicates() {
        do {
            let removed = try eventDB.deduplicateAllSessions()
            if removed > 0 {
                logger.info("Database repair: removed \(removed) duplicate events")
                loadSessions()
            }
        } catch {
            logger.error("Failed to repair duplicates: \(error.localizedDescription)")
        }
    }

    /// Repair a specific session by removing duplicate events
    func repairSession(_ sessionId: String) {
        do {
            let removed = try eventDB.deduplicateSession(sessionId)
            if removed > 0 {
                logger.info("Repaired session \(sessionId): removed \(removed) duplicate events")
                // Update session metadata
                Task {
                    try? await updateSessionMetadata(sessionId: sessionId)
                    sessionUpdated.send(sessionId)
                }
            }
        } catch {
            logger.error("Failed to repair session \(sessionId): \(error.localizedDescription)")
        }
    }
}

// MARK: - Display Message

/// Message for display in UI (simplified from events)
struct DisplayMessage: Identifiable, Equatable {
    let id: String
    let role: String
    let content: Any
    let timestamp: Date

    static func == (lhs: DisplayMessage, rhs: DisplayMessage) -> Bool {
        lhs.id == rhs.id && lhs.role == rhs.role
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
