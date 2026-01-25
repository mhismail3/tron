import Foundation
import SQLite3

// MARK: - Event Database

// NOTE: Uses global `logger` from TronLogger.swift (TronLogger.shared)
// Do NOT define a local logger property - it would shadow the global one

/// SQLite-based local event store for iOS
/// Provides offline support and fast state reconstruction
@MainActor
class EventDatabase: ObservableObject, DatabaseTransport {

    private(set) var db: OpaquePointer?
    let dbPath: String

    @Published private(set) var isInitialized = false

    // MARK: - Domain Repositories

    lazy var events: EventRepository = EventRepository(transport: self)
    lazy var sessions: SessionRepository = SessionRepository(transport: self)
    lazy var sync: SyncRepository = SyncRepository(transport: self)
    lazy var thinking: ThinkingRepository = ThinkingRepository(transport: self, eventRepository: events)
    lazy var tree: TreeRepository = TreeRepository(eventRepository: events, sessionRepository: sessions)

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

    // MARK: - DatabaseTransport Helpers

    var errorMessage: String {
        String(cString: sqlite3_errmsg(db))
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw EventDatabaseError.executeFailed(errorMessage)
        }
    }

    func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value = value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    func getOptionalText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: ptr)
    }
}

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
