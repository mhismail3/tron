import Foundation
import SQLite3

/// Repository for session CRUD operations.
/// Extracted from EventDatabase for single responsibility.
final class SessionRepository: @unchecked Sendable {

    private static let upsertSQL = """
        INSERT INTO sessions
        (id, workspace_id, root_event_id, head_event_id, title, latest_model,
         working_directory, created_at, last_activity_at, archived_at, event_count,
         turn_count, message_count, input_tokens, output_tokens, last_turn_input_tokens,
         cache_read_tokens, cache_creation_tokens, cost, is_fork, is_processing, server_origin,
         activity_lines_json, source, profile)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            workspace_id = excluded.workspace_id,
            root_event_id = excluded.root_event_id,
            head_event_id = excluded.head_event_id,
            title = excluded.title,
            latest_model = excluded.latest_model,
            working_directory = excluded.working_directory,
            created_at = excluded.created_at,
            last_activity_at = excluded.last_activity_at,
            archived_at = excluded.archived_at,
            event_count = excluded.event_count,
            turn_count = excluded.turn_count,
            message_count = excluded.message_count,
            input_tokens = excluded.input_tokens,
            output_tokens = excluded.output_tokens,
            last_turn_input_tokens = excluded.last_turn_input_tokens,
            cache_read_tokens = excluded.cache_read_tokens,
            cache_creation_tokens = excluded.cache_creation_tokens,
            cost = excluded.cost,
            is_fork = excluded.is_fork,
            is_processing = excluded.is_processing,
            server_origin = excluded.server_origin,
            activity_lines_json = excluded.activity_lines_json,
            source = excluded.source,
            profile = excluded.profile
    """

    private weak var transport: (any DatabaseTransport)?

    init(transport: any DatabaseTransport) {
        self.transport = transport
    }

    // MARK: - Insert Operations

    /// Insert or replace a session
    func insert(_ session: CachedSession) async throws {
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        try await transport.withDB { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, Self.upsertSQL, -1, &stmt, nil) == SQLITE_OK else {
                throw EventDatabaseError.prepareFailed(sqliteErrorMessage(db))
            }
            defer { sqlite3_finalize(stmt) }

            Self.bind(session, to: stmt)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw EventDatabaseError.insertFailed(sqliteErrorMessage(db))
            }
        }
    }

    /// Apply one server session snapshot in a single SQLite transaction.
    ///
    /// `authoritativeSessionIds` is supplied only for a complete, unfiltered
    /// server snapshot. Deletion is additionally bounded by `snapshotAsOf`, so
    /// sessions created after the snapshot began cannot be mistaken for stale
    /// rows. Event rows are deleted only for sessions proven absent.
    @discardableResult
    func reconcileServerSnapshot(
        upserting sessions: [CachedSession],
        serverOrigin: String,
        authoritativeSessionIds: Set<String>?,
        snapshotAsOf: String?
    ) async throws -> Int {
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        return try await transport.withDB { db in
            guard sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION", nil, nil, nil) == SQLITE_OK else {
                throw EventDatabaseError.executeFailed(sqliteErrorMessage(db))
            }
            do {
                var upsertStatement: OpaquePointer?
                guard sqlite3_prepare_v2(db, Self.upsertSQL, -1, &upsertStatement, nil) == SQLITE_OK else {
                    throw EventDatabaseError.prepareFailed(sqliteErrorMessage(db))
                }
                defer { sqlite3_finalize(upsertStatement) }

                for session in sessions {
                    sqlite3_reset(upsertStatement)
                    sqlite3_clear_bindings(upsertStatement)
                    Self.bind(session, to: upsertStatement)
                    guard sqlite3_step(upsertStatement) == SQLITE_DONE else {
                        throw EventDatabaseError.insertFailed(sqliteErrorMessage(db))
                    }
                }

                var staleSessionIds: [String] = []
                if let authoritativeSessionIds, let snapshotAsOf {
                    var selectStatement: OpaquePointer?
                    let selectSQL = """
                        SELECT id FROM sessions
                        WHERE server_origin = ? AND julianday(created_at) <= julianday(?)
                    """
                    guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStatement, nil) == SQLITE_OK else {
                        throw EventDatabaseError.prepareFailed(sqliteErrorMessage(db))
                    }
                    sqlite3_bind_text(selectStatement, 1, serverOrigin, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                    sqlite3_bind_text(selectStatement, 2, snapshotAsOf, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                    var selectStep = sqlite3_step(selectStatement)
                    while selectStep == SQLITE_ROW {
                        let id = String(cString: sqlite3_column_text(selectStatement, 0))
                        if !authoritativeSessionIds.contains(id) {
                            staleSessionIds.append(id)
                        }
                        selectStep = sqlite3_step(selectStatement)
                    }
                    guard selectStep == SQLITE_DONE else {
                        sqlite3_finalize(selectStatement)
                        throw EventDatabaseError.executeFailed(sqliteErrorMessage(db))
                    }
                    sqlite3_finalize(selectStatement)

                    var deleteEventsStatement: OpaquePointer?
                    var deleteSessionStatement: OpaquePointer?
                    guard sqlite3_prepare_v2(
                        db,
                        "DELETE FROM events WHERE session_id = ?",
                        -1,
                        &deleteEventsStatement,
                        nil
                    ) == SQLITE_OK,
                    sqlite3_prepare_v2(
                        db,
                        "DELETE FROM sessions WHERE id = ?",
                        -1,
                        &deleteSessionStatement,
                        nil
                    ) == SQLITE_OK else {
                        sqlite3_finalize(deleteEventsStatement)
                        sqlite3_finalize(deleteSessionStatement)
                        throw EventDatabaseError.prepareFailed(sqliteErrorMessage(db))
                    }
                    defer {
                        sqlite3_finalize(deleteEventsStatement)
                        sqlite3_finalize(deleteSessionStatement)
                    }

                    for id in staleSessionIds {
                        for statement in [deleteEventsStatement, deleteSessionStatement] {
                            sqlite3_reset(statement)
                            sqlite3_clear_bindings(statement)
                            sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                            guard sqlite3_step(statement) == SQLITE_DONE else {
                                throw EventDatabaseError.deleteFailed(sqliteErrorMessage(db))
                            }
                        }
                    }
                }

                guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                    throw EventDatabaseError.executeFailed(sqliteErrorMessage(db))
                }
                return staleSessionIds.count
            } catch {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }
    }

    // MARK: - Query Operations

    /// Get a single session by ID
    func get(_ id: String) async throws -> CachedSession? {
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        return try await transport.withDB { db in
            let sql = """
                SELECT id, workspace_id, root_event_id, head_event_id, title, latest_model,
                       working_directory, created_at, last_activity_at, archived_at, event_count,
                       turn_count, message_count, input_tokens, output_tokens, last_turn_input_tokens,
                       cache_read_tokens, cache_creation_tokens, cost, is_fork, is_processing, server_origin,
                       activity_lines_json, source, profile
                FROM sessions WHERE id = ?
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw EventDatabaseError.prepareFailed(sqliteErrorMessage(db))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT_DESTRUCTOR)

            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return nil
            }

            return Self.parseSessionRow(stmt)
        }
    }

    /// Get all sessions ordered by last activity
    func getAll() async throws -> [CachedSession] {
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        return try await transport.withDB { db in
            let sql = """
                SELECT id, workspace_id, root_event_id, head_event_id, title, latest_model,
                       working_directory, created_at, last_activity_at, archived_at, event_count,
                       turn_count, message_count, input_tokens, output_tokens, last_turn_input_tokens,
                       cache_read_tokens, cache_creation_tokens, cost, is_fork, is_processing, server_origin,
                       activity_lines_json, source, profile
                FROM sessions ORDER BY last_activity_at DESC, id DESC
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw EventDatabaseError.prepareFailed(sqliteErrorMessage(db))
            }
            defer { sqlite3_finalize(stmt) }

            var sessions: [CachedSession] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let session = Self.parseSessionRow(stmt) {
                    sessions.append(session)
                }
            }

            return sessions
        }
    }

    /// Get sessions filtered by server origin (STRICT match)
    /// - Parameter origin: The server origin (host:port) to filter by. If nil, returns all sessions.
    /// - Returns: Sessions matching the origin exactly. Sessions with NULL or different origin are EXCLUDED.
    func getByOrigin(_ origin: String?) async throws -> [CachedSession] {
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        return try await transport.withDB { db in
            let sql: String
            if origin != nil {
                sql = """
                    SELECT id, workspace_id, root_event_id, head_event_id, title, latest_model,
                           working_directory, created_at, last_activity_at, archived_at, event_count,
                           turn_count, message_count, input_tokens, output_tokens, last_turn_input_tokens,
                           cache_read_tokens, cache_creation_tokens, cost, is_fork, is_processing, server_origin,
                           activity_lines_json, source, profile
                    FROM sessions
                    WHERE server_origin = ?
                    ORDER BY last_activity_at DESC, id DESC
                """
            } else {
                sql = """
                    SELECT id, workspace_id, root_event_id, head_event_id, title, latest_model,
                           working_directory, created_at, last_activity_at, archived_at, event_count,
                           turn_count, message_count, input_tokens, output_tokens, last_turn_input_tokens,
                           cache_read_tokens, cache_creation_tokens, cost, is_fork, is_processing, server_origin,
                           activity_lines_json, source, profile
                    FROM sessions ORDER BY last_activity_at DESC, id DESC
                """
            }

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw EventDatabaseError.prepareFailed(sqliteErrorMessage(db))
            }
            defer { sqlite3_finalize(stmt) }

            if let origin = origin {
                sqlite3_bind_text(stmt, 1, origin, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            }

            var sessions: [CachedSession] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let session = Self.parseSessionRow(stmt) {
                    sessions.append(session)
                }
            }

            return sessions
        }
    }

    /// Get the server origin for an existing session
    func getOrigin(_ sessionId: String) async throws -> String? {
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        return try await transport.withDB { db in
            let sql = "SELECT server_origin FROM sessions WHERE id = ?"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw EventDatabaseError.prepareFailed(sqliteErrorMessage(db))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT_DESTRUCTOR)

            if sqlite3_step(stmt) == SQLITE_ROW {
                return sqliteGetOptionalText(stmt, 0)
            }
            return nil
        }
    }

    /// Check if a session exists
    func exists(_ sessionId: String) async throws -> Bool {
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        return try await transport.withDB { db in
            let sql = "SELECT 1 FROM sessions WHERE id = ? LIMIT 1"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw EventDatabaseError.prepareFailed(sqliteErrorMessage(db))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT_DESTRUCTOR)

            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }

    // MARK: - Delete Operations

    /// Delete a session by ID
    func delete(_ id: String) async throws {
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        try await transport.withDB { db in
            let sql = "DELETE FROM sessions WHERE id = ?"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw EventDatabaseError.prepareFailed(sqliteErrorMessage(db))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT_DESTRUCTOR)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw EventDatabaseError.deleteFailed(sqliteErrorMessage(db))
            }
        }
    }

    // MARK: - Fork Operations

    /// Get all sessions that were forked from a specific event.
    /// Finds session.fork events whose sourceEventId matches the given event.
    func getForked(fromEventId eventId: String) async throws -> [CachedSession] {
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        let forkedSessionIds: [String] = try await transport.withDB { db in
            let sql = """
                SELECT id, parent_id, session_id, workspace_id, type, timestamp, sequence, payload
                FROM events WHERE type = 'session.fork'
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw EventDatabaseError.prepareFailed(sqliteErrorMessage(db))
            }
            defer { sqlite3_finalize(stmt) }

            var ids: [String] = []
            var rowIndex = 0
            while sqlite3_step(stmt) == SQLITE_ROW {
                do {
                    let event = try Self.parseEventRow(stmt)
                    let payload = SessionForkPayload(from: event.payload)
                    if payload?.sourceEventId == eventId {
                        ids.append(event.sessionId)
                    }
                } catch {
                    logger.warning("Failed to parse event row: getForked eventId=\(eventId.prefix(12))..., rowIndex=\(rowIndex), error=\(error.localizedDescription)", category: .database)
                }
                rowIndex += 1
            }
            return ids
        }

        var sessions: [CachedSession] = []
        for sessionId in forkedSessionIds {
            if let session = try await get(sessionId) {
                sessions.append(session)
            }
        }

        return sessions
    }

    /// Get sibling branches at a fork point - returns sessions forked from the same event
    /// as the current session, excluding the current session itself.
    func getSiblings(forEventId eventId: String, excluding currentSessionId: String) async throws -> [CachedSession] {
        let allForked = try await getForked(fromEventId: eventId)
        return allForked.filter { $0.id != currentSessionId }
    }

    // MARK: - Private Helpers

    private static func bind(_ session: CachedSession, to stmt: OpaquePointer?) {
        sqlite3_bind_text(stmt, 1, session.id, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 2, session.workspaceId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqliteBindOptionalText(stmt, 3, session.rootEventId)
        sqliteBindOptionalText(stmt, 4, session.headEventId)
        sqliteBindOptionalText(stmt, 5, session.title)
        sqlite3_bind_text(stmt, 6, session.latestModel, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 7, session.workingDirectory, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 8, session.createdAt, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 9, session.lastActivityAt, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqliteBindOptionalText(stmt, 10, session.archivedAt)
        sqlite3_bind_int(stmt, 11, Int32(session.eventCount))
        sqlite3_bind_int(stmt, 12, Int32(session.turnCount))
        sqlite3_bind_int(stmt, 13, Int32(session.messageCount))
        sqlite3_bind_int(stmt, 14, Int32(session.inputTokens))
        sqlite3_bind_int(stmt, 15, Int32(session.outputTokens))
        sqlite3_bind_int(stmt, 16, Int32(session.lastTurnInputTokens))
        sqlite3_bind_int(stmt, 17, Int32(session.cacheReadTokens))
        sqlite3_bind_int(stmt, 18, Int32(session.cacheCreationTokens))
        sqlite3_bind_double(stmt, 19, session.cost)
        sqlite3_bind_int(stmt, 20, Int32(session.isFork == true ? 1 : 0))
        sqlite3_bind_int(stmt, 21, Int32(session.isProcessing == true ? 1 : 0))
        sqliteBindOptionalText(stmt, 22, session.serverOrigin)

        if let lines = session.lastActivityLines,
           let data = try? JSONEncoder().encode(lines),
           let json = String(data: data, encoding: .utf8) {
            sqlite3_bind_text(stmt, 23, json, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        } else {
            sqlite3_bind_null(stmt, 23)
        }
        sqliteBindOptionalText(stmt, 24, session.source)
        sqliteBindOptionalText(stmt, 25, session.profile)
    }

    private static func parseSessionRow(_ stmt: OpaquePointer?) -> CachedSession? {
        let id = String(cString: sqlite3_column_text(stmt, 0))
        let workspaceId = String(cString: sqlite3_column_text(stmt, 1))
        let rootEventId = sqliteGetOptionalText(stmt, 2)
        let headEventId = sqliteGetOptionalText(stmt, 3)
        let title = sqliteGetOptionalText(stmt, 4)
        let latestModel = String(cString: sqlite3_column_text(stmt, 5))
        let workingDirectory = String(cString: sqlite3_column_text(stmt, 6))
        let createdAt = String(cString: sqlite3_column_text(stmt, 7))
        let lastActivityAt = String(cString: sqlite3_column_text(stmt, 8))
        let archivedAt = sqliteGetOptionalText(stmt, 9)
        let eventCount = Int(sqlite3_column_int(stmt, 10))
        let turnCount = Int(sqlite3_column_int(stmt, 11))
        let messageCount = Int(sqlite3_column_int(stmt, 12))
        let inputTokens = Int(sqlite3_column_int(stmt, 13))
        let outputTokens = Int(sqlite3_column_int(stmt, 14))
        let lastTurnInputTokens = Int(sqlite3_column_int(stmt, 15))
        let cacheReadTokens = Int(sqlite3_column_int(stmt, 16))
        let cacheCreationTokens = Int(sqlite3_column_int(stmt, 17))
        let cost = sqlite3_column_double(stmt, 18)
        let isFork = sqlite3_column_int(stmt, 19) != 0
        let isProcessing = sqlite3_column_int(stmt, 20) != 0
        let serverOrigin = sqliteGetOptionalText(stmt, 21)

        // Decode persisted activity lines from JSON
        var activityLines: [ActivityLine]?
        if let jsonStr = sqliteGetOptionalText(stmt, 22),
           let data = jsonStr.data(using: .utf8) {
            activityLines = try? JSONDecoder().decode([ActivityLine].self, from: data)
        }

        let source = sqliteGetOptionalText(stmt, 23)
        let profile = sqliteGetOptionalText(stmt, 24)

        var session = CachedSession(
            id: id,
            workspaceId: workspaceId,
            rootEventId: rootEventId,
            headEventId: headEventId,
            title: title,
            latestModel: latestModel,
            workingDirectory: workingDirectory,
            createdAt: createdAt,
            lastActivityAt: lastActivityAt,
            archivedAt: archivedAt,
            eventCount: eventCount,
            turnCount: turnCount,
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
        session.lastActivityLines = activityLines
        session.isProcessing = isProcessing
        session.source = source
        session.profile = profile
        return session
    }

    /// Parse an event row from SQL result (for fork queries)
    private static func parseEventRow(_ stmt: OpaquePointer?) throws -> SessionEvent {
        let id = String(cString: sqlite3_column_text(stmt, 0))
        let parentId = sqliteGetOptionalText(stmt, 1)
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
                logger.warning("Failed to decode event payload: eventId=\(id.prefix(12))..., type=\(type), error=\(error.localizedDescription)", category: .database)
                payload = [:]
            }
        } else {
            logger.warning("Failed to convert payload to UTF-8 data: eventId=\(id.prefix(12))..., type=\(type)", category: .database)
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
}
