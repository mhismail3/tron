import Foundation
import SQLite3
import os

// MARK: - Event Database

/// SQLite-based local event store for iOS
/// Provides offline support and fast state reconstruction
@MainActor
class EventDatabase: ObservableObject {
    private let logger = Logger(subsystem: "com.tron.mobile", category: "EventDatabase")

    private var db: OpaquePointer?
    private let dbPath: String

    @Published private(set) var isInitialized = false

    // MARK: - Initialization

    init() {
        // Store in app's documents directory
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let tronDir = documentsURL.appendingPathComponent(".tron", isDirectory: true)

        // Create directory if needed
        try? fileManager.createDirectory(at: tronDir, withIntermediateDirectories: true)

        self.dbPath = tronDir.appendingPathComponent("events.db").path
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
        logger.info("Event database initialized at \(self.dbPath)")
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

    private func createTables() throws {
        // Events table
        try execute("""
            CREATE TABLE IF NOT EXISTS events (
                id TEXT PRIMARY KEY,
                parent_id TEXT,
                session_id TEXT NOT NULL,
                workspace_id TEXT NOT NULL,
                type TEXT NOT NULL,
                timestamp TEXT NOT NULL,
                sequence INTEGER NOT NULL,
                payload TEXT NOT NULL
            )
        """)

        // Events indexes
        try execute("CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_id)")
        try execute("CREATE INDEX IF NOT EXISTS idx_events_parent ON events(parent_id)")
        try execute("CREATE INDEX IF NOT EXISTS idx_events_timestamp ON events(timestamp)")

        // Sessions table
        try execute("""
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                workspace_id TEXT NOT NULL,
                root_event_id TEXT,
                head_event_id TEXT,
                status TEXT DEFAULT 'active',
                title TEXT,
                model TEXT NOT NULL,
                provider TEXT NOT NULL,
                working_directory TEXT NOT NULL,
                created_at TEXT NOT NULL,
                last_activity_at TEXT NOT NULL,
                event_count INTEGER DEFAULT 0,
                message_count INTEGER DEFAULT 0,
                input_tokens INTEGER DEFAULT 0,
                output_tokens INTEGER DEFAULT 0
            )
        """)

        // Sessions indexes
        try execute("CREATE INDEX IF NOT EXISTS idx_sessions_workspace ON sessions(workspace_id)")
        try execute("CREATE INDEX IF NOT EXISTS idx_sessions_activity ON sessions(last_activity_at)")

        // Sync state table
        try execute("""
            CREATE TABLE IF NOT EXISTS sync_state (
                key TEXT PRIMARY KEY,
                last_synced_event_id TEXT,
                last_sync_timestamp TEXT,
                pending_event_ids TEXT
            )
        """)
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
            if let event = try? parseEventRow(stmt) {
                events.append(event)
            }
        }

        return events
    }

    func getAncestors(_ eventId: String) throws -> [SessionEvent] {
        var ancestors: [SessionEvent] = []
        var currentId: String? = eventId

        while let id = currentId {
            guard let event = try getEvent(id) else { break }
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
            if let event = try? parseEventRow(stmt) {
                children.append(event)
            }
        }

        return children
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

    /// Delete locally-cached events that would be duplicates of incoming server events.
    /// Local events have UUID-style IDs, server events have "evt_" prefixed IDs.
    /// This should be called BEFORE inserting server events to prevent duplicates.
    func deleteLocalDuplicates(sessionId: String, serverEvents: [SessionEvent]) throws {
        // Get all local events for this session (those with UUID-style IDs, not "evt_" prefix)
        let localEvents = try getEventsBySession(sessionId).filter { !$0.id.hasPrefix("evt_") }

        guard !localEvents.isEmpty else {
            logger.debug("No local events to deduplicate for session \(sessionId)")
            return
        }

        logger.debug("Checking \(localEvents.count) local events against \(serverEvents.count) server events")

        // Build a set of (type, content) pairs from server events for quick lookup
        // Note: We don't use 'turn' for matching because server events may not include it
        var serverEventKeys = Set<String>()
        for event in serverEvents {
            if event.type == "message.user" || event.type == "message.assistant" {
                // Extract content - handle both String and Array content
                var contentStr = ""
                if let content = event.payload["content"]?.value as? String {
                    contentStr = content
                } else if let contentArray = event.payload["content"]?.value as? [[String: Any]] {
                    // Handle content blocks (array of {type: "text", text: "..."})
                    contentStr = contentArray.compactMap { $0["text"] as? String }.joined()
                }

                // Key by type + content prefix only (no turn - server may not include it)
                let key = "\(event.type):\(String(contentStr.prefix(100)))"
                serverEventKeys.insert(key)
                logger.debug("Server event key: \(key)")
            }
        }

        // Find local events that match server events and delete them
        var idsToDelete: [String] = []
        for localEvent in localEvents {
            if localEvent.type == "message.user" || localEvent.type == "message.assistant" {
                var contentStr = ""
                if let content = localEvent.payload["content"]?.value as? String {
                    contentStr = content
                } else if let contentArray = localEvent.payload["content"]?.value as? [[String: Any]] {
                    contentStr = contentArray.compactMap { $0["text"] as? String }.joined()
                }

                let key = "\(localEvent.type):\(String(contentStr.prefix(100)))"
                logger.debug("Local event key: \(key), matches: \(serverEventKeys.contains(key))")

                if serverEventKeys.contains(key) {
                    idsToDelete.append(localEvent.id)
                }
            }
        }

        // Delete matching local events
        if !idsToDelete.isEmpty {
            logger.info("Deleting \(idsToDelete.count) local duplicate events for session \(sessionId)")

            for id in idsToDelete {
                let sql = "DELETE FROM events WHERE id = ?"
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

            logger.info("Deleted \(idsToDelete.count) local duplicate events for session \(sessionId)")
        } else {
            logger.debug("No duplicates found to delete")
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
            (id, workspace_id, root_event_id, head_event_id, status, title, model, provider,
             working_directory, created_at, last_activity_at, event_count, message_count,
             input_tokens, output_tokens)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        sqlite3_bind_text(stmt, 5, session.status.rawValue, -1, SQLITE_TRANSIENT)
        bindOptionalText(stmt, 6, session.title)
        sqlite3_bind_text(stmt, 7, session.model, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 8, session.provider, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 9, session.workingDirectory, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 10, session.createdAt, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 11, session.lastActivityAt, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 12, Int32(session.eventCount))
        sqlite3_bind_int(stmt, 13, Int32(session.messageCount))
        sqlite3_bind_int(stmt, 14, Int32(session.inputTokens))
        sqlite3_bind_int(stmt, 15, Int32(session.outputTokens))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw EventDatabaseError.insertFailed(errorMessage)
        }
    }

    func getSession(_ id: String) throws -> CachedSession? {
        let sql = """
            SELECT id, workspace_id, root_event_id, head_event_id, status, title, model, provider,
                   working_directory, created_at, last_activity_at, event_count, message_count,
                   input_tokens, output_tokens
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
            SELECT id, workspace_id, root_event_id, head_event_id, status, title, model, provider,
                   working_directory, created_at, last_activity_at, event_count, message_count,
                   input_tokens, output_tokens
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

        let pendingEventIds = (try? JSONDecoder().decode([String].self, from: pendingIdsJson.data(using: .utf8)!)) ?? []

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

        let pendingIdsJson = (try? JSONEncoder().encode(state.pendingEventIds)) ?? Data()
        sqlite3_bind_text(stmt, 4, String(data: pendingIdsJson, encoding: .utf8), -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw EventDatabaseError.insertFailed(errorMessage)
        }
    }

    // MARK: - State Reconstruction

    func getMessagesAt(_ eventId: String) throws -> [ReconstructedMessage] {
        let ancestors = try getAncestors(eventId)
        var messages: [ReconstructedMessage] = []

        for event in ancestors {
            if event.type == "message.user" {
                let content = event.payload["content"]?.value ?? ""
                messages.append(ReconstructedMessage(role: "user", content: content))
            } else if event.type == "message.assistant" {
                let content = event.payload["content"]?.value ?? ""
                messages.append(ReconstructedMessage(role: "assistant", content: content))
            }
        }

        return messages
    }

    func getStateAtHead(_ sessionId: String) throws -> ReconstructedSessionState {
        guard let session = try getSession(sessionId),
              let headEventId = session.headEventId else {
            return ReconstructedSessionState(
                messages: [],
                tokenUsage: TokenUsage(inputTokens: 0, outputTokens: 0, cacheReadTokens: nil, cacheCreationTokens: nil),
                turnCount: 0,
                ledger: nil
            )
        }

        let ancestors = try getAncestors(headEventId)
        var messages: [ReconstructedMessage] = []
        var inputTokens = 0
        var outputTokens = 0
        var turnCount = 0
        var ledger: ReconstructedLedger?

        for event in ancestors {
            switch event.type {
            case "message.user":
                let content = event.payload["content"]?.value ?? ""
                messages.append(ReconstructedMessage(role: "user", content: content))

                if let usage = event.payload["tokenUsage"]?.value as? [String: Any] {
                    inputTokens += (usage["inputTokens"] as? Int) ?? 0
                    outputTokens += (usage["outputTokens"] as? Int) ?? 0
                }

            case "message.assistant":
                let content = event.payload["content"]?.value ?? ""
                messages.append(ReconstructedMessage(role: "assistant", content: content))

                if let usage = event.payload["tokenUsage"]?.value as? [String: Any] {
                    inputTokens += (usage["inputTokens"] as? Int) ?? 0
                    outputTokens += (usage["outputTokens"] as? Int) ?? 0
                }

                if let turn = event.payload["turn"]?.value as? Int, turn > turnCount {
                    turnCount = turn
                }

            case "ledger.update":
                if let updates = event.payload["updates"]?.value as? [String: Any] {
                    if ledger == nil {
                        ledger = ReconstructedLedger(
                            goal: "",
                            now: "",
                            next: [],
                            done: [],
                            constraints: [],
                            workingFiles: [],
                            decisions: []
                        )
                    }
                    if let goal = updates["goal"] as? String { ledger?.goal = goal }
                    if let now = updates["now"] as? String { ledger?.now = now }
                    if let next = updates["next"] as? [String] { ledger?.next = next }
                    if let done = updates["done"] as? [String] { ledger?.done = done }
                    if let constraints = updates["constraints"] as? [String] { ledger?.constraints = constraints }
                    if let files = updates["workingFiles"] as? [String] { ledger?.workingFiles = files }
                }

            default:
                break
            }
        }

        return ReconstructedSessionState(
            messages: messages,
            tokenUsage: TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens, cacheReadTokens: nil, cacheCreationTokens: nil),
            turnCount: turnCount,
            ledger: ledger
        )
    }

    // MARK: - Tree Visualization

    func buildTreeVisualization(_ sessionId: String) throws -> [EventTreeNode] {
        let events = try getEventsBySession(sessionId)
        let session = try getSession(sessionId)

        guard !events.isEmpty else { return [] }

        // Build parent-child map
        var childrenMap: [String?: [SessionEvent]] = [:]
        for event in events {
            var siblings = childrenMap[event.parentId] ?? []
            siblings.append(event)
            childrenMap[event.parentId] = siblings
        }

        var nodes: [EventTreeNode] = []
        let headEventId = session?.headEventId

        func buildNode(_ event: SessionEvent, depth: Int) {
            let children = childrenMap[event.id] ?? []
            let isBranchPoint = children.count > 1

            nodes.append(EventTreeNode(
                id: event.id,
                parentId: event.parentId,
                type: event.type,
                timestamp: event.timestamp,
                summary: event.summary,
                hasChildren: !children.isEmpty,
                childCount: children.count,
                depth: depth,
                isBranchPoint: isBranchPoint,
                isHead: event.id == headEventId
            ))

            for child in children {
                buildNode(child, depth: depth + 1)
            }
        }

        // Start from root events
        let roots = childrenMap[nil] ?? []
        for root in roots {
            buildNode(root, depth: 0)
        }

        return nodes
    }

    // MARK: - Utilities

    func clearAll() throws {
        try execute("DELETE FROM events")
        try execute("DELETE FROM sessions")
        try execute("DELETE FROM sync_state")
    }

    /// Remove duplicate events for a session, keeping server events (evt_*) over local events (UUIDs).
    /// Call this to repair databases that have accumulated duplicates.
    func deduplicateSession(_ sessionId: String) throws -> Int {
        let events = try getEventsBySession(sessionId)

        // Group events by (type, content prefix) to find duplicates
        // Note: We don't use 'turn' for matching because server events may not include it
        var keyToEvents: [String: [SessionEvent]] = [:]
        for event in events {
            if event.type == "message.user" || event.type == "message.assistant" {
                var contentStr = ""
                if let content = event.payload["content"]?.value as? String {
                    contentStr = content
                } else if let contentArray = event.payload["content"]?.value as? [[String: Any]] {
                    contentStr = contentArray.compactMap { $0["text"] as? String }.joined()
                }

                let key = "\(event.type):\(String(contentStr.prefix(100)))"

                var group = keyToEvents[key] ?? []
                group.append(event)
                keyToEvents[key] = group
            }
        }

        // Find duplicate groups and determine which to delete
        var idsToDelete: [String] = []
        for (key, group) in keyToEvents {
            if group.count > 1 {
                logger.debug("Found \(group.count) events for key: \(key)")

                // Prefer server events (evt_*) over local events
                let serverEvents = group.filter { $0.id.hasPrefix("evt_") }
                let localEvents = group.filter { !$0.id.hasPrefix("evt_") }

                if !serverEvents.isEmpty {
                    // Keep server events, delete local ones
                    logger.debug("Keeping \(serverEvents.count) server events, deleting \(localEvents.count) local events")
                    idsToDelete.append(contentsOf: localEvents.map { $0.id })
                } else {
                    // No server events, keep the first local one
                    logger.debug("No server events, keeping first local, deleting \(localEvents.count - 1) others")
                    idsToDelete.append(contentsOf: localEvents.dropFirst().map { $0.id })
                }
            }
        }

        // Delete duplicates
        if !idsToDelete.isEmpty {
            for id in idsToDelete {
                let sql = "DELETE FROM events WHERE id = ?"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    throw EventDatabaseError.prepareFailed(errorMessage)
                }
                defer { sqlite3_finalize(stmt) }

                sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
                _ = sqlite3_step(stmt)
            }

            logger.info("Deduplicated session \(sessionId): removed \(idsToDelete.count) duplicate events")
        }

        return idsToDelete.count
    }

    /// Deduplicate all sessions in the database
    func deduplicateAllSessions() throws -> Int {
        var totalRemoved = 0
        let sessions = try getAllSessions()

        for session in sessions {
            totalRemoved += try deduplicateSession(session.id)
        }

        return totalRemoved
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
            payload = (try? JSONDecoder().decode([String: AnyCodable].self, from: data)) ?? [:]
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
        let statusStr = String(cString: sqlite3_column_text(stmt, 4))
        let title = getOptionalText(stmt, 5)
        let model = String(cString: sqlite3_column_text(stmt, 6))
        let provider = String(cString: sqlite3_column_text(stmt, 7))
        let workingDirectory = String(cString: sqlite3_column_text(stmt, 8))
        let createdAt = String(cString: sqlite3_column_text(stmt, 9))
        let lastActivityAt = String(cString: sqlite3_column_text(stmt, 10))
        let eventCount = Int(sqlite3_column_int(stmt, 11))
        let messageCount = Int(sqlite3_column_int(stmt, 12))
        let inputTokens = Int(sqlite3_column_int(stmt, 13))
        let outputTokens = Int(sqlite3_column_int(stmt, 14))

        return CachedSession(
            id: id,
            workspaceId: workspaceId,
            rootEventId: rootEventId,
            headEventId: headEventId,
            status: SessionStatus(rawValue: statusStr) ?? .active,
            title: title,
            model: model,
            provider: provider,
            workingDirectory: workingDirectory,
            createdAt: createdAt,
            lastActivityAt: lastActivityAt,
            eventCount: eventCount,
            messageCount: messageCount,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
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
