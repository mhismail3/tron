import Foundation

// NOTE: Uses global `logger` from TronLogger.swift (TronLogger.shared)
// Do NOT define a local logger property - it would shadow the global one

// MARK: - Capability Call Record (for persistence)

/// Tracks capability invocations during a turn for event-sourced persistence
struct CapabilityInvocationRecord {
    let invocationId: String
    let modelPrimitiveName: String
    var arguments: String
    var identity: CapabilityIdentity = CapabilityIdentity()
    var result: String?
    var isError: Bool = false
}

// MARK: - Event Store Manager

/// Central manager for event-sourced session state
/// Coordinates between EventDatabase (local SQLite) and EngineClient (server sync)
@Observable
@MainActor
final class EventStoreManager {
    // Uses global `logger` from TronLogger.swift

    let eventDB: EventDatabase
    private(set) var engineClient: EngineClient
    let defaults: UserDefaults
    weak var draftStore: DraftStore?

    // MARK: - Observable State

    private(set) var sessions: [CachedSession] = []
    private(set) var activeSessionId: String? {
        didSet {
            if activeSessionId != oldValue {
                logger.info("Active session changed: \(oldValue ?? "nil") → \(activeSessionId ?? "nil")", category: .session)
            }
        }
    }

    /// Whether to filter sessions by current server origin
    var filterByOrigin: Bool = true

    /// Current server origin from the engine client
    var currentServerOrigin: String {
        engineClient.serverOrigin
    }

    /// Handles synchronization of session events with the server
    @ObservationIgnored
    private(set) lazy var sessionSynchronizer: SessionSynchronizer = {
        SessionSynchronizer(engineClient: engineClient, eventDB: eventDB)
    }()

    /// Manages bounded live activity snapshots for session metadata persistence.
    @ObservationIgnored
    private(set) lazy var sessionActivityStreamManager = SessionActivityStreamManager()

    /// Coalescing coordinator for session-list refresh. Every caller routes through
    /// `requestSessionRefresh(reason:)` — direct `refreshSessionList()` calls are reserved
    /// for the coordinator's `performRefresh` closure.
    @ObservationIgnored
    private(set) lazy var refreshService: SessionRefreshService = SessionRefreshService(
        performRefresh: { [weak self] in await self?.refreshSessionList() },
        isConnected: { [weak self] in self?.engineClient.connectionState.isConnected ?? false }
    )

    // MARK: - Processing State

    var processingSessionIds: Set<String> = [] {
        didSet {
            if processingSessionIds != oldValue {
                #if DEBUG || BETA
                let added = processingSessionIds.subtracting(oldValue)
                let removed = oldValue.subtracting(processingSessionIds)
                if !added.isEmpty {
                    logger.debug("Processing started for sessions: \(added.map { String($0.prefix(12)) + "..." }.joined(separator: ", "))", category: .session)
                }
                if !removed.isEmpty {
                    logger.debug("Processing completed for sessions: \(removed.map { String($0.prefix(12)) + "..." }.joined(separator: ", "))", category: .session)
                }
                #endif
            }
        }
    }

    /// Task for global event handling
    @ObservationIgnored
    private var globalEventTask: Task<Void, Never>?
    @ObservationIgnored
    private var shutdownTask: Task<Void, Never>?
    @ObservationIgnored
    private var isTerminal = false

    private let globalEventStream: @MainActor (EngineClient) -> AsyncStream<ParsedEventV2>
    private let acceptedEventHook: @MainActor (ParsedEventV2) async -> Void

    // MARK: - Initialization

    init(
        eventDB: EventDatabase,
        engineClient: EngineClient,
        defaults: UserDefaults = .standard,
        globalEventStream: @escaping @MainActor (EngineClient) -> AsyncStream<ParsedEventV2> = { $0.events },
        acceptedEventHook: @escaping @MainActor (ParsedEventV2) async -> Void = { _ in }
    ) {
        self.eventDB = eventDB
        self.engineClient = engineClient
        self.defaults = defaults
        self.globalEventStream = globalEventStream
        self.acceptedEventHook = acceptedEventHook
        setupGlobalEventHandlers()
    }

    deinit {
        MainActor.assumeIsolated {
            globalEventTask?.cancel()
            loadSessionsTask?.cancel()
            shutdownTask?.cancel()
        }
    }

    /// Update the engine client (e.g., when server settings change)
    func updateEngineClient(_ client: EngineClient) {
        guard !isTerminal else { return }
        engineClient = client
        sessionSynchronizer.updateEngineClient(client)
        setupGlobalEventHandlers()
        logger.info("engine client updated to \(client.serverOrigin)", category: .session)
    }

    /// Set up handlers for global events (events from all sessions)
    /// These events update session list state for ALL sessions, not just the active one.
    private func setupGlobalEventHandlers() {
        guard !isTerminal else { return }
        let predecessor = globalEventTask
        predecessor?.cancel()
        let stream = globalEventStream(engineClient)
        globalEventTask = Task { @MainActor [weak self] in
            await predecessor?.value
            guard !Task.isCancelled else { return }
            for await event in stream {
                guard let self else { return }
                await self.acceptedEventHook(event)
                await self.handleGlobalEventV2(event)
                if Task.isCancelled { break }
            }
        }
    }

    // MARK: - State Setters (for extensions)

    func clearSessions() {
        sessions = []
    }

    func setSessions(_ newSessions: [CachedSession]) {
        sessions = newSessions
    }

    func updateSession(at index: Int, _ update: (inout CachedSession) -> Void) {
        guard sessions.indices.contains(index) else { return }
        update(&sessions[index])
    }

    func setActiveSessionId(_ sessionId: String?) {
        activeSessionId = sessionId
    }

    /// Remove a session from the local array by ID (for optimistic UI updates)
    /// Returns the removed session and its index for potential rollback
    func removeSessionLocally(_ sessionId: String) -> (session: CachedSession, index: Int)? {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else {
            return nil
        }
        let session = sessions[index]
        sessions.remove(at: index)
        return (session, index)
    }

    /// Insert a session back into the local array at a specific index (for rollback)
    func insertSessionLocally(_ session: CachedSession, at index: Int) {
        let clampedIndex = min(index, sessions.count)
        sessions.insert(session, at: clampedIndex)
    }

    /// Mark a session as deleting/not-deleting in the local array.
    func markSessionDeleting(_ sessionId: String, isDeleting: Bool) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[index].isDeleting = isDeleting
    }

    // MARK: - Session List (from EventDatabase)

    /// Latest predecessor chain for immediate and debounced database loads.
    @ObservationIgnored
    private var loadSessionsTask: Task<Void, Never>?
    /// Whether this is the first loadSessions call (skip debounce for initialize)
    @ObservationIgnored
    private var hasLoadedSessionsOnce = false

    /// Load sessions from local EventDatabase.
    /// Debounced: rapid calls within 100ms are coalesced into a single execution.
    /// First call (during initialize) executes immediately.
    func loadSessions() {
        guard !isTerminal else { return }
        let shouldDebounce = hasLoadedSessionsOnce
        hasLoadedSessionsOnce = true
        let predecessor = loadSessionsTask
        predecessor?.cancel()
        loadSessionsTask = Task { @MainActor [weak self] in
            await predecessor?.value
            if shouldDebounce {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
            }
            guard let self, !self.isTerminal else { return }
            await self._loadSessionsImmediate()
        }
    }

    /// Idempotent terminal drain. The outer owner closes the database only
    /// after this method has joined every accepted event, refresh, and load.
    func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }

        isTerminal = true
        let globalTask = globalEventTask
        let refreshCoordinator = refreshService
        let loadTask = loadSessionsTask
        let activityManager = sessionActivityStreamManager
        globalTask?.cancel()

        let drain = Task { @MainActor in
            await globalTask?.value
            await refreshCoordinator.shutdown()
            loadTask?.cancel()
            await loadTask?.value
            activityManager.clearAll()
        }
        shutdownTask = drain
        await drain.value
    }

    /// Actual loadSessions implementation (called directly or after debounce).
    private func _loadSessionsImmediate() async {
        do {
            // Preserve transient state that isn't persisted to DB
            var preservedState: [String: (activityLines: [ActivityLine]?, isProcessing: Bool?)] = [:]
            for session in sessions {
                preservedState[session.id] = (session.lastActivityLines, session.isProcessing)
            }

            // Filter by current server origin if enabled
            let origin = filterByOrigin ? currentServerOrigin : nil
            sessions = try await eventDB.sessions.getByOrigin(origin).filter { !$0.isArchived }
            logger.info("Loaded \(self.sessions.count) sessions from EventDatabase (origin filter: \(origin ?? "none"))", category: .session)

            // Restore preserved transient state
            for i in sessions.indices {
                let sessionId = sessions[i].id

                if let preserved = preservedState[sessionId] {
                    sessions[i].isProcessing = preserved.isProcessing
                    if let activityLines = preserved.activityLines {
                        sessions[i].lastActivityLines = activityLines
                    }
                }

                if processingSessionIds.contains(sessionId) {
                    sessions[i].isProcessing = true
                }
            }
        } catch {
            logger.error("Failed to load sessions: \(error.localizedDescription)", category: .session)
            sessions = []
        }
    }

    /// Get sorted sessions (most recent first)
    var sortedSessions: [CachedSession] {
        sessions.sorted {
            if $0.lastActivityAt != $1.lastActivityAt {
                return $0.lastActivityAt > $1.lastActivityAt
            }
            return $0.id > $1.id
        }
    }

    /// Get active session
    var activeSession: CachedSession? {
        guard let id = activeSessionId else { return nil }
        return sessions.first { $0.id == id }
    }

    /// Set the active session
    func setActiveSession(_ sessionId: String?) {
        activeSessionId = sessionId
        defaults.set(sessionId, forKey: "tron.activeSessionId")
    }

    /// Check if a session exists locally
    func sessionExists(_ sessionId: String) -> Bool {
        sessions.contains { $0.id == sessionId }
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
