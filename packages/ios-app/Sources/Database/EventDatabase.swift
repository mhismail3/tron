import Foundation
import SQLite3

// MARK: - Event Database

// NOTE: Uses global `logger` from TronLogger.swift (TronLogger.shared)
// Do NOT define a local logger property - it would shadow the global one

/// SQLite-based local event store for iOS
/// Provides offline support and fast state reconstruction
@MainActor
class EventDatabase: ObservableObject {

    private var db: OpaquePointer?
    private let dbPath: String

    @Published private(set) var isInitialized = false

    // MARK: - Initialization

    init() {
        // Store in app's documents directory
        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            // This should never happen on iOS, but provide clear diagnostics if it does
            fatalError("EventDatabase: Unable to access Documents directory - app cannot function")
        }
        let tronDir = documentsURL.appendingPathComponent(".tron", isDirectory: true)
        let dbDir = tronDir.appendingPathComponent("db", isDirectory: true)

        // Create directories if needed
        try? fileManager.createDirectory(at: dbDir, withIntermediateDirectories: true)

        self.dbPath = dbDir.appendingPathComponent("prod.db").path
    }

    func initialize() async throws {
        guard !isInitialized else { return }

        // Open database
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            throw EventDatabaseError.openFailed(errorMessage)
        }

        // Enable WAL mode for better concurrent access
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA busy_timeout = 5000")

        // Create tables
        try createTables()

        isInitialized = true
        logger.info("Event database initialized at \(self.dbPath)", category: .session)
    }

    func close() {
        if let db = db {
            sqlite3_close(db)
            self.db = nil
            isInitialized = false
        }
    }

    // Note: deinit cleanup is handled by close() method which should be called explicitly
    // We can't access actor-isolated properties from deinit in Swift 6

    // MARK: - Schema

    /// Create all database tables and run migrations.
    /// - Note: Delegates to DatabaseSchema for schema management.
    private func createTables() throws {
        try DatabaseSchema.createTables(db: db)
    }

    // MARK: - Event Operations

    func insertEvent(_ event: SessionEvent) throws {
        let sql = """
            INSERT OR REPLACE INTO events
            (id, parent_id, session_id, workspace_id, type, timestamp, sequence, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, event.id, -1, SQLITE_TRANSIENT)
        if let parentId = event.parentId {
            sqlite3_bind_text(stmt, 2, parentId, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        sqlite3_bind_text(stmt, 3, event.sessionId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, event.workspaceId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, event.type, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 6, event.timestamp, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 7, Int32(event.sequence))

        // Encode payload as JSON
        let payloadData = try JSONEncoder().encode(event.payload)
        let payloadString = String(data: payloadData, encoding: .utf8) ?? "{}"
        sqlite3_bind_text(stmt, 8, payloadString, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw EventDatabaseError.insertFailed(errorMessage)
        }
    }

    func insertEvents(_ events: [SessionEvent]) throws {
        guard !events.isEmpty else { return }

        try execute("BEGIN TRANSACTION")
        do {
            for event in events {
                try insertEvent(event)
            }
            try execute("COMMIT")
        } catch {
            try execute("ROLLBACK")
            throw error
        }
    }

    /// Insert events, ignoring any that already exist (by ID).
    /// Returns the number of events actually inserted.
    func insertEventsIgnoringDuplicates(_ events: [SessionEvent]) throws -> Int {
        guard !events.isEmpty else { return 0 }

        let sql = """
            INSERT OR IGNORE INTO events
            (id, parent_id, session_id, workspace_id, type, timestamp, sequence, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """

        var insertedCount = 0

        try execute("BEGIN TRANSACTION")
        do {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw EventDatabaseError.prepareFailed(errorMessage)
            }
            defer { sqlite3_finalize(stmt) }

            for event in events {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)

                sqlite3_bind_text(stmt, 1, event.id, -1, SQLITE_TRANSIENT)
                if let parentId = event.parentId {
                    sqlite3_bind_text(stmt, 2, parentId, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 2)
                }
                sqlite3_bind_text(stmt, 3, event.sessionId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, event.workspaceId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 5, event.type, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 6, event.timestamp, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 7, Int32(event.sequence))

                let payloadData = try JSONEncoder().encode(event.payload)
                let payloadString = String(data: payloadData, encoding: .utf8) ?? "{}"
                sqlite3_bind_text(stmt, 8, payloadString, -1, SQLITE_TRANSIENT)

                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw EventDatabaseError.insertFailed(errorMessage)
                }

                // Check if a row was actually inserted (changes > 0)
                if sqlite3_changes(db) > 0 {
                    insertedCount += 1
                }
            }
            try execute("COMMIT")
        } catch {
            try execute("ROLLBACK")
            throw error
        }

        return insertedCount
    }

    func getEvent(_ id: String) throws -> SessionEvent? {
        let sql = """
            SELECT id, parent_id, session_id, workspace_id, type, timestamp, sequence, payload
            FROM events WHERE id = ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }

        return try parseEventRow(stmt)
    }

    func getEventsBySession(_ sessionId: String) throws -> [SessionEvent] {
        let sql = """
            SELECT id, parent_id, session_id, workspace_id, type, timestamp, sequence, payload
            FROM events WHERE session_id = ? ORDER BY sequence ASC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)

        var events: [SessionEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            do {
                let event = try parseEventRow(stmt)
                events.append(event)
            } catch {
                logger.warning("Failed to parse event row in getEventsBySession: \(error.localizedDescription)", category: .session)
            }
        }

        return events
    }

    func getAncestors(_ eventId: String) throws -> [SessionEvent] {
        var ancestors: [SessionEvent] = []
        var currentId: String? = eventId

        while let id = currentId {
            guard let event = try getEvent(id) else {
                logger.warning("Ancestor chain broken at event: \(id)", category: .session)
                break
            }
            ancestors.insert(event, at: 0)
            currentId = event.parentId
        }

        return ancestors
    }

    func getChildren(_ eventId: String) throws -> [SessionEvent] {
        let sql = """
            SELECT id, parent_id, session_id, workspace_id, type, timestamp, sequence, payload
            FROM events WHERE parent_id = ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, eventId, -1, SQLITE_TRANSIENT)

        var children: [SessionEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            do {
                let event = try parseEventRow(stmt)
                children.append(event)
            } catch {
                logger.warning("Failed to parse event row in getChildren: \(error.localizedDescription)", category: .session)
            }
        }

        return children
    }

    /// Get all sessions that were forked from a specific event.
    /// Finds session.fork events whose sourceEventId matches the given event.
    func getForkedSessions(fromEventId eventId: String) throws -> [CachedSession] {
        // Find all session.fork events
        let sql = """
            SELECT id, parent_id, session_id, workspace_id, type, timestamp, sequence, payload
            FROM events WHERE type = 'session.fork'
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        var forkedSessionIds: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            do {
                let event = try parseEventRow(stmt)
                // Parse the fork payload to check sourceEventId
                let payload = SessionForkPayload(from: event.payload)
                if payload?.sourceEventId == eventId {
                    forkedSessionIds.append(event.sessionId)
                }
            } catch {
                logger.warning("Failed to parse event row in getForkedSessions: \(error.localizedDescription)", category: .session)
            }
        }

        // Fetch the corresponding sessions
        var sessions: [CachedSession] = []
        for sessionId in forkedSessionIds {
            if let session = try getSession(sessionId) {
                sessions.append(session)
            }
        }

        return sessions
    }

    /// Get sibling branches at a fork point - returns sessions forked from the same event
    /// as the current session, excluding the current session itself.
    func getSiblingBranches(forEventId eventId: String, excludingSessionId currentSessionId: String) throws -> [CachedSession] {
        let allForked = try getForkedSessions(fromEventId: eventId)
        return allForked.filter { $0.id != currentSessionId }
    }

    func deleteEventsBySession(_ sessionId: String) throws {
        let sql = "DELETE FROM events WHERE session_id = ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw EventDatabaseError.deleteFailed(errorMessage)
        }
    }

    /// Delete events by their IDs
    func deleteEvents(ids: [String]) throws {
        guard !ids.isEmpty else { return }

        try execute("BEGIN TRANSACTION")
        do {
            let sql = "DELETE FROM events WHERE id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw EventDatabaseError.prepareFailed(errorMessage)
            }
            defer { sqlite3_finalize(stmt) }

            for id in ids {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)

                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw EventDatabaseError.deleteFailed(errorMessage)
                }
            }
            try execute("COMMIT")
        } catch {
            try execute("ROLLBACK")
            throw error
        }
    }

    /// Check if an event with the given ID already exists
    func eventExists(_ id: String) throws -> Bool {
        let sql = "SELECT 1 FROM events WHERE id = ? LIMIT 1"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)

        return sqlite3_step(stmt) == SQLITE_ROW
    }

    // MARK: - Session Operations

    func insertSession(_ session: CachedSession) throws {
        let sql = """
            INSERT OR REPLACE INTO sessions
            (id, workspace_id, root_event_id, head_event_id, title, latest_model,
             working_directory, created_at, last_activity_at, ended_at, event_count,
             message_count, input_tokens, output_tokens, last_turn_input_tokens,
             cache_read_tokens, cache_creation_tokens, cost, is_fork, server_origin)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, session.id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, session.workspaceId, -1, SQLITE_TRANSIENT)
        bindOptionalText(stmt, 3, session.rootEventId)
        bindOptionalText(stmt, 4, session.headEventId)
        bindOptionalText(stmt, 5, session.title)
        sqlite3_bind_text(stmt, 6, session.latestModel, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 7, session.workingDirectory, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 8, session.createdAt, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 9, session.lastActivityAt, -1, SQLITE_TRANSIENT)
        bindOptionalText(stmt, 10, session.endedAt)
        sqlite3_bind_int(stmt, 11, Int32(session.eventCount))
        sqlite3_bind_int(stmt, 12, Int32(session.messageCount))
        sqlite3_bind_int(stmt, 13, Int32(session.inputTokens))
        sqlite3_bind_int(stmt, 14, Int32(session.outputTokens))
        sqlite3_bind_int(stmt, 15, Int32(session.lastTurnInputTokens))
        sqlite3_bind_int(stmt, 16, Int32(session.cacheReadTokens))
        sqlite3_bind_int(stmt, 17, Int32(session.cacheCreationTokens))
        sqlite3_bind_double(stmt, 18, session.cost)
        sqlite3_bind_int(stmt, 19, Int32(session.isFork == true ? 1 : 0))
        bindOptionalText(stmt, 20, session.serverOrigin)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw EventDatabaseError.insertFailed(errorMessage)
        }
    }

    func getSession(_ id: String) throws -> CachedSession? {
        let sql = """
            SELECT id, workspace_id, root_event_id, head_event_id, title, latest_model,
                   working_directory, created_at, last_activity_at, ended_at, event_count,
                   message_count, input_tokens, output_tokens, last_turn_input_tokens,
                   cache_read_tokens, cache_creation_tokens, cost, is_fork, server_origin
            FROM sessions WHERE id = ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }

        return parseSessionRow(stmt)
    }

    func getAllSessions() throws -> [CachedSession] {
        let sql = """
            SELECT id, workspace_id, root_event_id, head_event_id, title, latest_model,
                   working_directory, created_at, last_activity_at, ended_at, event_count,
                   message_count, input_tokens, output_tokens, last_turn_input_tokens,
                   cache_read_tokens, cache_creation_tokens, cost, is_fork, server_origin
            FROM sessions ORDER BY last_activity_at DESC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        var sessions: [CachedSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let session = parseSessionRow(stmt) {
                sessions.append(session)
            }
        }

        return sessions
    }

    func deleteSession(_ id: String) throws {
        let sql = "DELETE FROM sessions WHERE id = ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw EventDatabaseError.deleteFailed(errorMessage)
        }
    }

    // MARK: - Sync State Operations

    func getSyncState(_ sessionId: String) throws -> SyncState? {
        let sql = "SELECT key, last_synced_event_id, last_sync_timestamp, pending_event_ids FROM sync_state WHERE key = ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }

        let key = String(cString: sqlite3_column_text(stmt, 0))
        let lastSyncedEventId = getOptionalText(stmt, 1)
        let lastSyncTimestamp = getOptionalText(stmt, 2)
        let pendingIdsJson = getOptionalText(stmt, 3) ?? "[]"

        var pendingEventIds: [String] = []
        if let jsonData = pendingIdsJson.data(using: .utf8) {
            do {
                pendingEventIds = try JSONDecoder().decode([String].self, from: jsonData)
            } catch {
                logger.warning("Failed to decode sync state pendingEventIds: \(error.localizedDescription)", category: .session)
            }
        }

        return SyncState(
            key: key,
            lastSyncedEventId: lastSyncedEventId,
            lastSyncTimestamp: lastSyncTimestamp,
            pendingEventIds: pendingEventIds
        )
    }

    func updateSyncState(_ state: SyncState) throws {
        let sql = """
            INSERT OR REPLACE INTO sync_state
            (key, last_synced_event_id, last_sync_timestamp, pending_event_ids)
            VALUES (?, ?, ?, ?)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, state.key, -1, SQLITE_TRANSIENT)
        bindOptionalText(stmt, 2, state.lastSyncedEventId)
        bindOptionalText(stmt, 3, state.lastSyncTimestamp)

        var pendingIdsJson = Data()
        do {
            pendingIdsJson = try JSONEncoder().encode(state.pendingEventIds)
        } catch {
            logger.warning("Failed to encode sync state pendingEventIds: \(error.localizedDescription)", category: .session)
        }
        sqlite3_bind_text(stmt, 4, String(data: pendingIdsJson, encoding: .utf8), -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw EventDatabaseError.insertFailed(errorMessage)
        }
    }

    // MARK: - Thinking Events

    /// Get thinking complete events for a session
    /// - Parameters:
    ///   - sessionId: The session to query
    ///   - previewOnly: If true, only returns preview data (for listing). If false, loads full content.
    /// - Returns: Array of ThinkingBlock objects for UI display
    func getThinkingEvents(sessionId: String, previewOnly: Bool = true) throws -> [ThinkingBlock] {
        // Query message.assistant events which contain thinking in content blocks
        let sql = """
            SELECT id, parent_id, session_id, workspace_id, type, timestamp, sequence, payload
            FROM events
            WHERE session_id = ? AND type = 'message.assistant'
            ORDER BY sequence ASC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)

        var blocks: [ThinkingBlock] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            do {
                let event = try parseEventRow(stmt)

                // Extract thinking from content blocks
                guard let contentArray = event.payload["content"]?.value as? [[String: Any]] else {
                    continue
                }

                // Find thinking block in content array
                for (blockIndex, block) in contentArray.enumerated() {
                    guard let blockType = block["type"] as? String,
                          blockType == "thinking",
                          let thinkingText = block["thinking"] as? String,
                          !thinkingText.isEmpty else {
                        continue
                    }

                    // Extract turn number from payload
                    let turnNumber = event.payload["turn"]?.value as? Int ?? 1

                    // Create preview (first 3 lines, max 120 chars)
                    let preview = extractThinkingPreview(from: thinkingText)

                    // Create block with composite ID (eventId:blockIndex) for lazy loading
                    let thinkingBlock = ThinkingBlock(
                        eventId: "\(event.id):\(blockIndex)",
                        turnNumber: turnNumber,
                        preview: preview,
                        characterCount: thinkingText.count,
                        model: event.payload["model"]?.value as? String,
                        timestamp: ISO8601DateFormatter().date(from: event.timestamp) ?? Date()
                    )
                    blocks.append(thinkingBlock)
                }
            } catch {
                logger.warning("Failed to parse assistant message for thinking: \(error.localizedDescription)", category: .session)
            }
        }

        return blocks
    }

    /// Extract preview (first 3 lines) from thinking content
    private func extractThinkingPreview(from content: String, maxLines: Int = 3) -> String {
        let lines = content.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(maxLines)
        let preview = lines.joined(separator: " ")
        if preview.count > 120 {
            return String(preview.prefix(117)) + "..."
        }
        return preview
    }

    /// Get full thinking content for a specific event ID (for lazy loading in sheet)
    /// - Parameter eventId: Composite ID in format "eventId:blockIndex" or plain event ID
    /// - Returns: The full thinking content string, or nil if not found
    func getThinkingContent(eventId: String) throws -> String? {
        // Parse composite ID format: "eventId:blockIndex"
        let components = eventId.split(separator: ":")
        let actualEventId: String
        let blockIndex: Int

        if components.count >= 2,
           let lastComponent = components.last,
           let index = Int(lastComponent) {
            // Composite ID: everything except last component is the event ID
            actualEventId = components.dropLast().joined(separator: ":")
            blockIndex = index
        } else {
            // Plain event ID (legacy format)
            actualEventId = eventId
            blockIndex = 0
        }

        guard let event = try getEvent(actualEventId) else {
            return nil
        }

        // Handle message.assistant events with thinking in content blocks
        if event.type == "message.assistant" {
            guard let contentArray = event.payload["content"]?.value as? [[String: Any]] else {
                return nil
            }

            // Find thinking block at the specified index
            var thinkingIndex = 0
            for block in contentArray {
                guard let blockType = block["type"] as? String,
                      blockType == "thinking",
                      let thinkingText = block["thinking"] as? String else {
                    continue
                }

                if thinkingIndex == blockIndex {
                    return thinkingText
                }
                thinkingIndex += 1
            }
            return nil
        }

        // Legacy: stream.thinking_complete events
        if event.type == "stream.thinking_complete" {
            return event.payload.string("content")
        }

        logger.warning("Event \(eventId) does not contain thinking content (type: \(event.type))", category: .session)
        return nil
    }

    // MARK: - Tree Visualization

    /// Build tree visualization for a session.
    /// - Note: Delegates to EventTreeBuilder for presentation logic.
    func buildTreeVisualization(_ sessionId: String) throws -> [EventTreeNode] {
        let events = try getEventsBySession(sessionId)
        let session = try getSession(sessionId)
        return EventTreeBuilder.buildTree(from: events, headEventId: session?.headEventId)
    }

    // MARK: - Utilities

    func clearAll() throws {
        try execute("DELETE FROM events")
        try execute("DELETE FROM sessions")
        try execute("DELETE FROM sync_state")
    }

    /// Remove duplicate events for a session, preferring events with richer content (tool blocks).
    /// When content richness is equal, prefers server events (evt_*) over local events (UUIDs).
    /// Call this to repair databases that have accumulated duplicates.
    /// - Note: Delegates to EventDeduplicator for business logic.
    func deduplicateSession(_ sessionId: String) throws -> Int {
        let deduplicator = EventDeduplicator(eventDB: self)
        return try deduplicator.deduplicateSession(sessionId)
    }

    /// Deduplicate all sessions in the database
    /// - Note: Delegates to EventDeduplicator for business logic.
    func deduplicateAllSessions() throws -> Int {
        let deduplicator = EventDeduplicator(eventDB: self)
        return try deduplicator.deduplicateAllSessions()
    }

    // MARK: - Private Helpers

    private var errorMessage: String {
        String(cString: sqlite3_errmsg(db))
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw EventDatabaseError.executeFailed(errorMessage)
        }
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value = value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func getOptionalText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: ptr)
    }

    private func parseEventRow(_ stmt: OpaquePointer?) throws -> SessionEvent {
        let id = String(cString: sqlite3_column_text(stmt, 0))
        let parentId = getOptionalText(stmt, 1)
        let sessionId = String(cString: sqlite3_column_text(stmt, 2))
        let workspaceId = String(cString: sqlite3_column_text(stmt, 3))
        let type = String(cString: sqlite3_column_text(stmt, 4))
        let timestamp = String(cString: sqlite3_column_text(stmt, 5))
        let sequence = Int(sqlite3_column_int(stmt, 6))
        let payloadJson = String(cString: sqlite3_column_text(stmt, 7))

        let payload: [String: AnyCodable]
        if let data = payloadJson.data(using: .utf8) {
            do {
                payload = try JSONDecoder().decode([String: AnyCodable].self, from: data)
            } catch {
                logger.warning("Failed to decode event payload for id=\(id): \(error.localizedDescription)", category: .session)
                payload = [:]
            }
        } else {
            payload = [:]
        }

        return SessionEvent(
            id: id,
            parentId: parentId,
            sessionId: sessionId,
            workspaceId: workspaceId,
            type: type,
            timestamp: timestamp,
            sequence: sequence,
            payload: payload
        )
    }

    private func parseSessionRow(_ stmt: OpaquePointer?) -> CachedSession? {
        let id = String(cString: sqlite3_column_text(stmt, 0))
        let workspaceId = String(cString: sqlite3_column_text(stmt, 1))
        let rootEventId = getOptionalText(stmt, 2)
        let headEventId = getOptionalText(stmt, 3)
        let title = getOptionalText(stmt, 4)
        let latestModel = String(cString: sqlite3_column_text(stmt, 5))
        let workingDirectory = String(cString: sqlite3_column_text(stmt, 6))
        let createdAt = String(cString: sqlite3_column_text(stmt, 7))
        let lastActivityAt = String(cString: sqlite3_column_text(stmt, 8))
        let endedAt = getOptionalText(stmt, 9)
        let eventCount = Int(sqlite3_column_int(stmt, 10))
        let messageCount = Int(sqlite3_column_int(stmt, 11))
        let inputTokens = Int(sqlite3_column_int(stmt, 12))
        let outputTokens = Int(sqlite3_column_int(stmt, 13))
        let lastTurnInputTokens = Int(sqlite3_column_int(stmt, 14))
        let cacheReadTokens = Int(sqlite3_column_int(stmt, 15))
        let cacheCreationTokens = Int(sqlite3_column_int(stmt, 16))
        let cost = sqlite3_column_double(stmt, 17)
        let isFork = sqlite3_column_int(stmt, 18) != 0
        let serverOrigin = getOptionalText(stmt, 19)

        return CachedSession(
            id: id,
            workspaceId: workspaceId,
            rootEventId: rootEventId,
            headEventId: headEventId,
            title: title,
            latestModel: latestModel,
            workingDirectory: workingDirectory,
            createdAt: createdAt,
            lastActivityAt: lastActivityAt,
            endedAt: endedAt,
            eventCount: eventCount,
            messageCount: messageCount,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            lastTurnInputTokens: lastTurnInputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens,
            cost: cost,
            isFork: isFork,
            serverOrigin: serverOrigin
        )
    }

    /// Get sessions filtered by server origin (STRICT match)
    /// - Parameter origin: The server origin (host:port) to filter by. If nil, returns all sessions.
    /// - Returns: Sessions matching the origin exactly. Sessions with NULL or different origin are EXCLUDED.
    func getSessionsByOrigin(_ origin: String?) throws -> [CachedSession] {
        let sql: String
        if origin != nil {
            // STRICT match: Only sessions from this specific server
            // Sessions with NULL origin (legacy) or different origin are EXCLUDED
            // This prevents cross-server session leakage
            sql = """
                SELECT id, workspace_id, root_event_id, head_event_id, title, latest_model,
                       working_directory, created_at, last_activity_at, ended_at, event_count,
                       message_count, input_tokens, output_tokens, last_turn_input_tokens,
                       cache_read_tokens, cache_creation_tokens, cost, is_fork, server_origin
                FROM sessions
                WHERE server_origin = ?
                ORDER BY last_activity_at DESC
            """
        } else {
            // No filter - return all sessions (for debugging/admin views)
            sql = """
                SELECT id, workspace_id, root_event_id, head_event_id, title, latest_model,
                       working_directory, created_at, last_activity_at, ended_at, event_count,
                       message_count, input_tokens, output_tokens, last_turn_input_tokens,
                       cache_read_tokens, cache_creation_tokens, cost, is_fork, server_origin
                FROM sessions ORDER BY last_activity_at DESC
            """
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        if let origin = origin {
            sqlite3_bind_text(stmt, 1, origin, -1, SQLITE_TRANSIENT)
        }

        var sessions: [CachedSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let session = parseSessionRow(stmt) {
                sessions.append(session)
            }
        }

        return sessions
    }

    /// Get the server origin for an existing session
    /// - Parameter sessionId: The session ID to check
    /// - Returns: The server origin string, or nil if session has NULL origin (legacy) or doesn't exist
    /// - Note: Use `sessionExists()` first if you need to distinguish between "doesn't exist" and "exists with NULL origin"
    func getSessionOrigin(_ sessionId: String) throws -> String? {
        let sql = "SELECT server_origin FROM sessions WHERE id = ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)

        if sqlite3_step(stmt) == SQLITE_ROW {
            // Session exists - return origin (may be nil for legacy sessions)
            return getOptionalText(stmt, 0)
        }
        // Session doesn't exist
        return nil
    }

    /// Check if a session exists locally
    func sessionExists(_ sessionId: String) throws -> Bool {
        let sql = "SELECT 1 FROM sessions WHERE id = ? LIMIT 1"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)

        return sqlite3_step(stmt) == SQLITE_ROW
    }
}

// MARK: - SQLite Constants

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Errors

enum EventDatabaseError: LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case executeFailed(String)
    case insertFailed(String)
    case deleteFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "Failed to open database: \(msg)"
        case .prepareFailed(let msg): return "Failed to prepare statement: \(msg)"
        case .executeFailed(let msg): return "Failed to execute SQL: \(msg)"
        case .insertFailed(let msg): return "Failed to insert: \(msg)"
        case .deleteFailed(let msg): return "Failed to delete: \(msg)"
        }
    }
}
