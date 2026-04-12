import Foundation
import SQLite3

// MARK: - Event Database

// NOTE: Uses global `logger` from TronLogger.swift (TronLogger.shared)
// Do NOT define a local logger property - it would shadow the global one

/// SQLite-based local event store for iOS
/// Provides offline support and fast state reconstruction
@Observable
@MainActor
final class EventDatabase: DatabaseTransport {

    private let dbActor: DatabaseActor
    let dbPath: String

    private(set) var isInitialized = false

    // MARK: - Domain Repositories

    @ObservationIgnored
    lazy var events: EventRepository = EventRepository(transport: self)
    @ObservationIgnored
    lazy var sessions: SessionRepository = SessionRepository(transport: self)
    @ObservationIgnored
    lazy var sync: SyncRepository = SyncRepository(transport: self)
    @ObservationIgnored
    lazy var thinking: ThinkingRepository = ThinkingRepository(transport: self, eventRepository: events)
    @ObservationIgnored
    lazy var tree: TreeRepository = TreeRepository(eventRepository: events, sessionRepository: sessions)
    @ObservationIgnored
    lazy var drafts: DraftRepository = DraftRepository(transport: self)

    // MARK: - Initialization

    /// Failable initializer — returns nil if Documents directory is inaccessible.
    init?() {
        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let tronDir = documentsURL.appendingPathComponent(".tron", isDirectory: true)
        let dbDir = tronDir.appendingPathComponent("database", isDirectory: true)

        // Create directories if needed
        try? fileManager.createDirectory(at: dbDir, withIntermediateDirectories: true)

        self.dbPath = dbDir.appendingPathComponent("prod.db").path
        self.dbActor = DatabaseActor(dbPath: self.dbPath)
    }

    /// Fallback initializer for when Documents directory is unavailable (e.g., device restore).
    /// Data in the fallback path may be lost when the temp directory is cleaned.
    init(fallbackPath: String) {
        let dir = (fallbackPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.dbPath = fallbackPath
        self.dbActor = DatabaseActor(dbPath: fallbackPath)
    }

    func initialize() async throws {
        guard !isInitialized else { return }

        try await dbActor.open()

        isInitialized = true
        logger.info("Event database initialized at \(self.dbPath)", category: .session)
    }

    func close() async {
        await dbActor.close()
        isInitialized = false
    }

    // MARK: - DatabaseTransport

    nonisolated func withDB<T: Sendable>(_ body: @Sendable (OpaquePointer?) throws -> T) async throws -> T {
        try await dbActor.withDB(body)
    }

    // MARK: - Utilities

    func clearAll() async throws {
        try await dbActor.exec("DELETE FROM events")
        try await dbActor.exec("DELETE FROM sessions")
        try await dbActor.exec("DELETE FROM sync_state")
        try await dbActor.exec("DELETE FROM session_drafts")
    }
}

// MARK: - Errors

enum EventDatabaseError: LocalizedError, Sendable {
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
