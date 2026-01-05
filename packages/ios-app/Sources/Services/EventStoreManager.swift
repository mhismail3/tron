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

    // MARK: - Initialization

    init(eventDB: EventDatabase, rpcClient: RPCClient) {
        self.eventDB = eventDB
        self.rpcClient = rpcClient
    }

    // MARK: - Session List (from EventDatabase)

    /// Load sessions from local EventDatabase
    func loadSessions() {
        do {
            sessions = try eventDB.getAllSessions()
            logger.info("Loaded \(self.sessions.count) sessions from EventDatabase")
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
    func syncSessionEvents(sessionId: String) async throws {
        logger.info("Syncing events for session \(sessionId)")

        // Get sync state to find cursor
        let syncState = try eventDB.getSyncState(sessionId)
        let afterEventId = syncState?.lastSyncedEventId

        // Fetch events since cursor
        let result = try await rpcClient.getEventsSince(
            sessionId: sessionId,
            afterEventId: afterEventId,
            limit: 500
        )

        if !result.events.isEmpty {
            // Convert server events
            let events = result.events.map { rawEventToSessionEvent($0) }

            // IMPORTANT: Delete any locally-cached events that duplicate these server events
            // This prevents duplicates when local caching races with server sync
            try eventDB.deleteLocalDuplicates(sessionId: sessionId, serverEvents: events)

            // Now insert the authoritative server events
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

        // Update head event
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

    // MARK: - Real-time Event Caching

    /// Cache a new event received during streaming
    func cacheStreamingEvent(_ event: SessionEvent) throws {
        try eventDB.insertEvent(event)

        // Update session head
        if var session = try eventDB.getSession(event.sessionId) {
            session.headEventId = event.id
            session.eventCount += 1
            session.lastActivityAt = event.timestamp

            if event.type == "message.user" || event.type == "message.assistant" {
                session.messageCount += 1
            }

            try eventDB.insertSession(session)
        }
    }

    /// Cache a user message event
    func cacheUserMessage(
        sessionId: String,
        workspaceId: String,
        content: String,
        turn: Int
    ) throws -> SessionEvent {
        let session = try eventDB.getSession(sessionId)
        let parentId = session?.headEventId

        let event = SessionEvent(
            id: UUID().uuidString,
            parentId: parentId,
            sessionId: sessionId,
            workspaceId: workspaceId,
            type: "message.user",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            sequence: (session?.eventCount ?? 0) + 1,
            payload: [
                "content": AnyCodable(content),
                "turn": AnyCodable(turn)
            ]
        )

        try cacheStreamingEvent(event)
        return event
    }

    /// Cache an assistant message event with optional tool calls
    /// Content is stored as an array of content blocks to match server format
    func cacheAssistantMessage(
        sessionId: String,
        workspaceId: String,
        content: String,
        toolCalls: [ToolCallRecord] = [],
        turn: Int,
        tokenUsage: TokenUsage?,
        model: String
    ) throws -> SessionEvent {
        let session = try eventDB.getSession(sessionId)
        let parentId = session?.headEventId

        // Build content blocks array matching server format
        var contentBlocks: [[String: Any]] = []

        // Add tool_use and tool_result blocks for each tool call
        for toolCall in toolCalls {
            // Parse arguments from JSON string to dictionary
            var inputDict: [String: Any] = [:]
            if let data = toolCall.arguments.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                inputDict = parsed
            }

            // Add tool_use block
            contentBlocks.append([
                "type": "tool_use",
                "id": toolCall.toolCallId,
                "name": toolCall.toolName,
                "input": inputDict
            ])

            // Add tool_result block if we have a result
            if let result = toolCall.result {
                contentBlocks.append([
                    "type": "tool_result",
                    "tool_use_id": toolCall.toolCallId,
                    "content": result,
                    "is_error": toolCall.isError
                ])
            }
        }

        // Add final text block if there's content
        if !content.isEmpty {
            contentBlocks.append([
                "type": "text",
                "text": content
            ])
        }

        var payload: [String: AnyCodable] = [
            "content": AnyCodable(contentBlocks),
            "turn": AnyCodable(turn),
            "model": AnyCodable(model)
        ]

        if let usage = tokenUsage {
            payload["tokenUsage"] = AnyCodable([
                "inputTokens": usage.inputTokens,
                "outputTokens": usage.outputTokens
            ])
        }

        let event = SessionEvent(
            id: UUID().uuidString,
            parentId: parentId,
            sessionId: sessionId,
            workspaceId: workspaceId,
            type: "message.assistant",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            sequence: (session?.eventCount ?? 0) + 1,
            payload: payload
        )

        try cacheStreamingEvent(event)

        // Update session token usage
        if var updatedSession = try eventDB.getSession(sessionId),
           let usage = tokenUsage {
            updatedSession.inputTokens += usage.inputTokens
            updatedSession.outputTokens += usage.outputTokens
            try eventDB.insertSession(updatedSession)
            loadSessions()
        }

        return event
    }

    // MARK: - Tree Operations (Fork/Rewind)

    /// Fork a session at a specific event (or head)
    func forkSession(_ sessionId: String, fromEventId: String? = nil) async throws -> String {
        // For now, delegate to server and sync back
        let result = try await rpcClient.forkSession(sessionId)

        // Sync the new session
        try await fullSyncSession(result.newSessionId)

        return result.newSessionId
    }

    /// Rewind a session to a specific event
    func rewindSession(_ sessionId: String, toEventId: String) async throws {
        // Update the local session HEAD
        guard var session = try eventDB.getSession(sessionId) else {
            throw EventStoreError.sessionNotFound
        }

        session.headEventId = toEventId
        try eventDB.insertSession(session)

        // Notify views
        sessionUpdated.send(sessionId)
        loadSessions()

        logger.info("Rewound session \(sessionId) to event \(toEventId)")
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
    case eventNotFound
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .sessionNotFound:
            return "Session not found"
        case .eventNotFound:
            return "Event not found"
        case .operationFailed(let message):
            return "Operation failed: \(message)"
        }
    }
}
