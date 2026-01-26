import Foundation
import SQLite3

/// Repository for sync state operations.
/// Extracted from EventDatabase for single responsibility.
@MainActor
final class SyncRepository {

    private weak var transport: DatabaseTransport?

    init(transport: DatabaseTransport) {
        self.transport = transport
    }

    // MARK: - Query Operations

    /// Get sync state for a session
    func getState(_ sessionId: String) throws -> SyncState? {
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        let sql = "SELECT key, last_synced_event_id, last_sync_timestamp, pending_event_ids FROM sync_state WHERE key = ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(transport.db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(transport.errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT_DESTRUCTOR)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }

        let key = String(cString: sqlite3_column_text(stmt, 0))
        let lastSyncedEventId = transport.getOptionalText(stmt, 1)
        let lastSyncTimestamp = transport.getOptionalText(stmt, 2)
        let pendingIdsJson = transport.getOptionalText(stmt, 3) ?? "[]"

        var pendingEventIds: [String] = []
        if let jsonData = pendingIdsJson.data(using: .utf8) {
            do {
                pendingEventIds = try JSONDecoder().decode([String].self, from: jsonData)
            } catch {
                logger.warning("Failed to decode sync state pendingEventIds: key=\(key), error=\(error.localizedDescription)", category: .database)
            }
        }

        return SyncState(
            key: key,
            lastSyncedEventId: lastSyncedEventId,
            lastSyncTimestamp: lastSyncTimestamp,
            pendingEventIds: pendingEventIds
        )
    }

    // MARK: - Update Operations

    /// Update sync state for a session
    func update(_ state: SyncState) throws {
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        let sql = """
            INSERT OR REPLACE INTO sync_state
            (key, last_synced_event_id, last_sync_timestamp, pending_event_ids)
            VALUES (?, ?, ?, ?)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(transport.db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(transport.errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, state.key, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        transport.bindOptionalText(stmt, 2, state.lastSyncedEventId)
        transport.bindOptionalText(stmt, 3, state.lastSyncTimestamp)

        var pendingIdsJson = Data()
        do {
            pendingIdsJson = try JSONEncoder().encode(state.pendingEventIds)
        } catch {
            logger.warning("Failed to encode sync state pendingEventIds: key=\(state.key), count=\(state.pendingEventIds.count), error=\(error.localizedDescription)", category: .database)
        }
        sqlite3_bind_text(stmt, 4, String(data: pendingIdsJson, encoding: .utf8), -1, SQLITE_TRANSIENT_DESTRUCTOR)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw EventDatabaseError.insertFailed(transport.errorMessage)
        }
    }
}
