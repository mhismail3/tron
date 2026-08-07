import Foundation
import SQLite3

/// Repository for event CRUD operations.
/// Extracted from EventDatabase for single responsibility.
final class EventRepository: @unchecked Sendable {

    private weak var transport: (any DatabaseTransport)?

    init(transport: any DatabaseTransport) {
        self.transport = transport
    }

    // MARK: - Insert Operations

    /// Insert a single event
    func insert(_ event: SessionEvent) async throws {
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        try await transport.withDB { db in
            let sql = """
                INSERT OR REPLACE INTO events
                (id, parent_id, session_id, workspace_id, type, timestamp, sequence, payload)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw EventDatabaseError.prepareFailed(sqliteErrorMessage(db))
            }
            defer { sqlite3_finalize(stmt) }

            try Self.bindEvent(event, to: stmt)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw EventDatabaseError.insertFailed(sqliteErrorMessage(db))
            }
        }
    }

    /// Insert events, ignoring any that already exist (by ID).
    /// Returns the number of events actually inserted.
    func insertIgnoringDuplicates(_ events: [SessionEvent]) async throws -> Int {
        guard !events.isEmpty else { return 0 }
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        logger.debug("Starting insertIgnoringDuplicates for \(events.count) events", category: .database)

        return try await transport.withDB { db in
            let sql = """
                INSERT OR IGNORE INTO events
                (id, parent_id, session_id, workspace_id, type, timestamp, sequence, payload)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """

            var insertedCount = 0

            guard sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil) == SQLITE_OK else {
                throw EventDatabaseError.executeFailed(sqliteErrorMessage(db))
            }
            do {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    throw EventDatabaseError.prepareFailed(sqliteErrorMessage(db))
                }
                defer { sqlite3_finalize(stmt) }

                for event in events {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    try Self.bindEvent(event, to: stmt)

                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        throw EventDatabaseError.insertFailed(sqliteErrorMessage(db))
                    }

                    if sqlite3_changes(db) > 0 {
                        insertedCount += 1
                    }
                }
                guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                    throw EventDatabaseError.executeFailed(sqliteErrorMessage(db))
                }
                logger.info("Inserted \(insertedCount) of \(events.count) events (duplicates ignored)", category: .database)
            } catch {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                logger.error("insertIgnoringDuplicates rolled back: \(error.localizedDescription)", category: .database)
                throw error
            }

            return insertedCount
        }
    }

    /// Bind event fields to a prepared statement shared by both supported insert paths.
    private static func bindEvent(_ event: SessionEvent, to stmt: OpaquePointer?) throws {
        sqlite3_bind_text(stmt, 1, event.id, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        if let parentId = event.parentId {
            sqlite3_bind_text(stmt, 2, parentId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        sqlite3_bind_text(stmt, 3, event.sessionId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 4, event.workspaceId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 5, event.type, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 6, event.timestamp, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_int(stmt, 7, Int32(event.sequence))

        // INVARIANT: Provider request manifests are exact, server-owned audit
        // data. They can be fetched on demand and must never enter the
        // disposable transcript cache, including when paired to an older
        // server that still returns them in reconstruction.
        let cachedPayload: [String: AnyCodable]
        if event.type == SessionEventType.modelProviderRequest.rawValue {
            cachedPayload = ["projection": AnyCodable("deferred")]
        } else {
            cachedPayload = event.payload
        }
        let payloadData = try JSONEncoder().encode(cachedPayload)
        let payloadString = String(data: payloadData, encoding: .utf8) ?? "{}"
        sqlite3_bind_text(stmt, 8, payloadString, -1, SQLITE_TRANSIENT_DESTRUCTOR)
    }

    // MARK: - Query Operations

    /// Get a single event by ID
    func get(_ id: String) async throws -> SessionEvent? {
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        return try await transport.withDB { db in
            let sql = """
                SELECT id, parent_id, session_id, workspace_id, type, timestamp, sequence, payload
                FROM events WHERE id = ?
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

            return try Self.parseEventRow(stmt)
        }
    }

    /// Get all events for a session ordered by sequence
    func getBySession(_ sessionId: String) async throws -> [SessionEvent] {
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        return try await transport.withDB { db in
            let sql = """
                SELECT id, parent_id, session_id, workspace_id, type, timestamp, sequence, payload
                FROM events WHERE session_id = ? ORDER BY sequence ASC
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw EventDatabaseError.prepareFailed(sqliteErrorMessage(db))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT_DESTRUCTOR)

            var events: [SessionEvent] = []
            var rowIndex = 0
            while sqlite3_step(stmt) == SQLITE_ROW {
                do {
                    let event = try Self.parseEventRow(stmt)
                    events.append(event)
                } catch {
                    logger.warning("Failed to parse event row: sessionId=\(sessionId.prefix(12))..., rowIndex=\(rowIndex), error=\(error.localizedDescription)", category: .database)
                }
                rowIndex += 1
            }

            return events
        }
    }

    /// Read only the newest bounded session window, returned in presentation
    /// order. Cold transcript presentation must scale with the requested
    /// window, not with the lifetime size of the session cache.
    func getRecentBySession(_ sessionId: String, limit: Int) async throws -> [SessionEvent] {
        guard limit > 0 else { return [] }
        guard let transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        return try await transport.withDB { db in
            let sql = """
                SELECT id, parent_id, session_id, workspace_id, type, timestamp, sequence, payload
                FROM (
                    SELECT id, parent_id, session_id, workspace_id, type, timestamp, sequence, payload
                    FROM events
                    WHERE session_id = ?
                    ORDER BY sequence DESC, timestamp DESC, id DESC
                    LIMIT ?
                )
                ORDER BY sequence ASC, timestamp ASC, id ASC
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw EventDatabaseError.prepareFailed(sqliteErrorMessage(db))
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, sessionId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int64(statement, 2, Int64(limit))

            var events: [SessionEvent] = []
            events.reserveCapacity(limit)
            while sqlite3_step(statement) == SQLITE_ROW {
                events.append(try Self.parseEventRow(statement))
            }
            return events
        }
    }

    /// Get ancestor chain for an event (follows parent_id links)
    func getAncestors(_ eventId: String) async throws -> [SessionEvent] {
        var ancestors: [SessionEvent] = []
        var currentId: String? = eventId

        while let id = currentId {
            guard let event = try await get(id) else {
                logger.warning("Ancestor chain broken at event: \(id)", category: .session)
                break
            }
            ancestors.insert(event, at: 0)
            currentId = event.parentId
        }

        return ancestors
    }

    /// Read a bounded root-to-head suffix across fork session boundaries in a
    /// single indexed recursive query. This is the fork-aware equivalent of
    /// `getRecentBySession`; exact older history remains server-paginated.
    func getRecentAncestors(_ eventId: String, limit: Int) async throws -> [SessionEvent] {
        guard limit > 0 else { return [] }
        guard let transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        return try await transport.withDB { db in
            let sql = """
                WITH RECURSIVE ancestor_window(
                    id, parent_id, session_id, workspace_id, type,
                    timestamp, sequence, payload, depth
                ) AS (
                    SELECT id, parent_id, session_id, workspace_id, type,
                           timestamp, sequence, payload, 0
                    FROM events
                    WHERE id = ?
                    UNION ALL
                    SELECT event.id, event.parent_id, event.session_id,
                           event.workspace_id, event.type, event.timestamp,
                           event.sequence, event.payload, ancestor.depth + 1
                    FROM events AS event
                    JOIN ancestor_window AS ancestor ON event.id = ancestor.parent_id
                    WHERE ancestor.depth + 1 < ?
                )
                SELECT id, parent_id, session_id, workspace_id, type,
                       timestamp, sequence, payload
                FROM ancestor_window
                ORDER BY depth DESC
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw EventDatabaseError.prepareFailed(sqliteErrorMessage(db))
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, eventId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int64(statement, 2, Int64(limit))

            var events: [SessionEvent] = []
            events.reserveCapacity(limit)
            while sqlite3_step(statement) == SQLITE_ROW {
                events.append(try Self.parseEventRow(statement))
            }
            return events
        }
    }

    // MARK: - Delete Operations

    /// Delete all events for a session
    func deleteBySession(_ sessionId: String) async throws {
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        logger.debug("Deleting all events for session: \(sessionId.prefix(12))...", category: .database)

        try await transport.withDB { db in
            let sql = "DELETE FROM events WHERE session_id = ?"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw EventDatabaseError.prepareFailed(sqliteErrorMessage(db))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT_DESTRUCTOR)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw EventDatabaseError.deleteFailed(sqliteErrorMessage(db))
            }

            let deletedCount = Int(sqlite3_changes(db))
            logger.info("Deleted \(deletedCount) events for session: \(sessionId.prefix(12))...", category: .database)
        }
    }

    // MARK: - Private Helpers

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
