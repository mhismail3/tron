import Foundation
import SQLite3

/// Repository for event CRUD operations.
/// Extracted from EventDatabase for single responsibility.
@MainActor
final class EventRepository {

    private weak var transport: DatabaseTransport?

    init(transport: DatabaseTransport) {
        self.transport = transport
    }

    // MARK: - Insert Operations

    /// Insert a single event
    func insert(_ event: SessionEvent) throws {
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        let sql = """
            INSERT OR REPLACE INTO events
            (id, parent_id, session_id, workspace_id, type, timestamp, sequence, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(transport.db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(transport.errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

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

        let payloadData = try JSONEncoder().encode(event.payload)
        let payloadString = String(data: payloadData, encoding: .utf8) ?? "{}"
        sqlite3_bind_text(stmt, 8, payloadString, -1, SQLITE_TRANSIENT_DESTRUCTOR)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw EventDatabaseError.insertFailed(transport.errorMessage)
        }
    }

    /// Insert multiple events in a transaction
    func insertBatch(_ events: [SessionEvent]) throws {
        guard !events.isEmpty else { return }
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        logger.debug("Starting batch insert of \(events.count) events", category: .database)
        try transport.execute("BEGIN TRANSACTION")
        do {
            for event in events {
                try insert(event)
            }
            try transport.execute("COMMIT")
            logger.info("Batch insert committed: \(events.count) events", category: .database)
        } catch {
            try transport.execute("ROLLBACK")
            logger.error("Batch insert rolled back: \(error.localizedDescription)", category: .database)
            throw error
        }
    }

    /// Insert events, ignoring any that already exist (by ID).
    /// Returns the number of events actually inserted.
    func insertIgnoringDuplicates(_ events: [SessionEvent]) throws -> Int {
        guard !events.isEmpty else { return 0 }
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        logger.debug("Starting insertIgnoringDuplicates for \(events.count) events", category: .database)

        let sql = """
            INSERT OR IGNORE INTO events
            (id, parent_id, session_id, workspace_id, type, timestamp, sequence, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """

        var insertedCount = 0

        try transport.execute("BEGIN TRANSACTION")
        do {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(transport.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw EventDatabaseError.prepareFailed(transport.errorMessage)
            }
            defer { sqlite3_finalize(stmt) }

            for event in events {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)

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

                let payloadData = try JSONEncoder().encode(event.payload)
                let payloadString = String(data: payloadData, encoding: .utf8) ?? "{}"
                sqlite3_bind_text(stmt, 8, payloadString, -1, SQLITE_TRANSIENT_DESTRUCTOR)

                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw EventDatabaseError.insertFailed(transport.errorMessage)
                }

                if sqlite3_changes(transport.db) > 0 {
                    insertedCount += 1
                }
            }
            try transport.execute("COMMIT")
            logger.info("Inserted \(insertedCount) of \(events.count) events (duplicates ignored)", category: .database)
        } catch {
            try transport.execute("ROLLBACK")
            logger.error("insertIgnoringDuplicates rolled back: \(error.localizedDescription)", category: .database)
            throw error
        }

        return insertedCount
    }

    // MARK: - Query Operations

    /// Get a single event by ID
    func get(_ id: String) throws -> SessionEvent? {
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        let sql = """
            SELECT id, parent_id, session_id, workspace_id, type, timestamp, sequence, payload
            FROM events WHERE id = ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(transport.db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(transport.errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT_DESTRUCTOR)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }

        return try parseEventRow(stmt, transport: transport)
    }

    /// Get all events for a session ordered by sequence
    func getBySession(_ sessionId: String) throws -> [SessionEvent] {
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        let sql = """
            SELECT id, parent_id, session_id, workspace_id, type, timestamp, sequence, payload
            FROM events WHERE session_id = ? ORDER BY sequence ASC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(transport.db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(transport.errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT_DESTRUCTOR)

        var events: [SessionEvent] = []
        var rowIndex = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            do {
                let event = try parseEventRow(stmt, transport: transport)
                events.append(event)
            } catch {
                logger.warning("Failed to parse event row: sessionId=\(sessionId.prefix(12))..., rowIndex=\(rowIndex), error=\(error.localizedDescription)", category: .database)
            }
            rowIndex += 1
        }

        return events
    }

    /// Get ancestor chain for an event (follows parent_id links)
    func getAncestors(_ eventId: String) throws -> [SessionEvent] {
        var ancestors: [SessionEvent] = []
        var currentId: String? = eventId

        while let id = currentId {
            guard let event = try get(id) else {
                logger.warning("Ancestor chain broken at event: \(id)", category: .session)
                break
            }
            ancestors.insert(event, at: 0)
            currentId = event.parentId
        }

        return ancestors
    }

    /// Get direct children of an event
    func getChildren(_ eventId: String) throws -> [SessionEvent] {
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        let sql = """
            SELECT id, parent_id, session_id, workspace_id, type, timestamp, sequence, payload
            FROM events WHERE parent_id = ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(transport.db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(transport.errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, eventId, -1, SQLITE_TRANSIENT_DESTRUCTOR)

        var children: [SessionEvent] = []
        var rowIndex = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            do {
                let event = try parseEventRow(stmt, transport: transport)
                children.append(event)
            } catch {
                logger.warning("Failed to parse event row: parentId=\(eventId.prefix(12))..., rowIndex=\(rowIndex), error=\(error.localizedDescription)", category: .database)
            }
            rowIndex += 1
        }

        return children
    }

    /// Check if an event exists
    func exists(_ id: String) throws -> Bool {
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        let sql = "SELECT 1 FROM events WHERE id = ? LIMIT 1"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(transport.db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(transport.errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT_DESTRUCTOR)

        return sqlite3_step(stmt) == SQLITE_ROW
    }

    // MARK: - Delete Operations

    /// Delete all events for a session
    func deleteBySession(_ sessionId: String) throws {
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        logger.debug("Deleting all events for session: \(sessionId.prefix(12))...", category: .database)

        let sql = "DELETE FROM events WHERE session_id = ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(transport.db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(transport.errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT_DESTRUCTOR)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw EventDatabaseError.deleteFailed(transport.errorMessage)
        }

        let deletedCount = Int(sqlite3_changes(transport.db))
        logger.info("Deleted \(deletedCount) events for session: \(sessionId.prefix(12))...", category: .database)
    }

    /// Delete events by their IDs
    func delete(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        logger.debug("Deleting \(ids.count) events by ID", category: .database)

        try transport.execute("BEGIN TRANSACTION")
        do {
            let sql = "DELETE FROM events WHERE id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(transport.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw EventDatabaseError.prepareFailed(transport.errorMessage)
            }
            defer { sqlite3_finalize(stmt) }

            for id in ids {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT_DESTRUCTOR)

                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw EventDatabaseError.deleteFailed(transport.errorMessage)
                }
            }
            try transport.execute("COMMIT")
            logger.info("Deleted \(ids.count) events by ID", category: .database)
        } catch {
            try transport.execute("ROLLBACK")
            logger.error("Delete by IDs rolled back: \(error.localizedDescription)", category: .database)
            throw error
        }
    }

    // MARK: - Private Helpers

    private func parseEventRow(_ stmt: OpaquePointer?, transport: DatabaseTransport) throws -> SessionEvent {
        let id = String(cString: sqlite3_column_text(stmt, 0))
        let parentId = transport.getOptionalText(stmt, 1)
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
