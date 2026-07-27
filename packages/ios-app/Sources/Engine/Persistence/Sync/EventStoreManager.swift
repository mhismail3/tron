import Foundation

// NOTE: Uses global `logger` from TronLogger.swift (TronLogger.shared)
// Do NOT define a local logger property - it would shadow the global one

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
        SessionSynchronizer(eventDB: eventDB)
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

    private struct ProcessingOverrideKey: Hashable {
        let serverOrigin: String
        let sessionId: String
    }

    private struct ProcessingOverride {
        let revision: UInt64
        let isProcessing: Bool
    }

    /// Orders server snapshots against transient live or optimistic overrides.
    /// `sessions` remains the sole observable processing projection.
    @ObservationIgnored
    private(set) var processingStateRevision: UInt64 = 0
    @ObservationIgnored
    private var processingOverrides: [ProcessingOverrideKey: ProcessingOverride] = [:]

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
        let previousOrigin = engineClient.serverOrigin
        engineClient = client
        if client.serverOrigin != previousOrigin {
            processingOverrides.removeAll()
        }
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
        processingOverrides.removeAll()
    }

    func setSessions(_ newSessions: [CachedSession]) {
        sessions = newSessions
    }

    func updateSession(at index: Int, _ update: (inout CachedSession) -> Void) {
        guard sessions.indices.contains(index) else { return }
        update(&sessions[index])
    }

    func applySessionProcessingState(_ sessionId: String, isProcessing: Bool) {
        processingStateRevision &+= 1
        let key = ProcessingOverrideKey(
            serverOrigin: engineClient.serverOrigin,
            sessionId: sessionId
        )
        processingOverrides[key] = ProcessingOverride(
            revision: processingStateRevision,
            isProcessing: isProcessing
        )

        let previousValue = sessions.first(where: { $0.id == sessionId })?.isProcessing == true
        if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            updateSession(at: index) { $0.isProcessing = isProcessing }
        }

        #if DEBUG || BETA
        if previousValue != isProcessing {
            let state = isProcessing ? "started" : "completed"
            logger.debug(
                "Processing \(state) for session \(String(sessionId.prefix(12)))...",
                category: .session
            )
        }
        #endif
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
        processingOverrides.removeValue(
            forKey: ProcessingOverrideKey(
                serverOrigin: session.serverOrigin ?? engineClient.serverOrigin,
                sessionId: sessionId
            )
        )
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
    private var loadSessionsTask: Task<Bool, Never>?
    /// An ordinary projection reload chains behind, rather than cancels, an
    /// accepted server-processing publication.
    @ObservationIgnored
    private var loadSessionsTaskAcceptsServerProcessingState = false
    /// Whether this is the first loadSessions call (skip debounce for initialize)
    @ObservationIgnored
    private var hasLoadedSessionsOnce = false

    /// Load sessions from local EventDatabase.
    /// Debounced: rapid calls within 100ms are coalesced into a single execution.
    /// First call (during initialize) executes immediately.
    func loadSessions() {
        _ = scheduleSessionLoad(
            using: engineClient,
            acceptingServerProcessingStateAt: nil,
            authoritativeProcessingSessionIds: nil
        )
    }

    /// A direct, already-durable publication supersedes any older database
    /// snapshot currently waiting in the debounced load lane.
    func cancelPendingSessionLoadForDirectPublication() {
        loadSessionsTask?.cancel()
        loadSessionsTask = nil
        loadSessionsTaskAcceptsServerProcessingState = false
    }

    /// Publish a reconciled server snapshot through the owned load lane.
    /// Returns only after that exact client generation either publishes or retires.
    func loadSessionsAfterRefresh(
        using operationClient: EngineClient,
        acceptingServerProcessingStateAt revision: UInt64,
        authoritativeProcessingSessionIds: Set<String>
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard let task = scheduleSessionLoad(
            using: operationClient,
            acceptingServerProcessingStateAt: revision,
            authoritativeProcessingSessionIds: authoritativeProcessingSessionIds
        ) else {
            return false
        }
        return await withTaskCancellationHandler {
            let published = await task.value
            return !Task.isCancelled && published
        } onCancel: {
            task.cancel()
        }
    }

    private func scheduleSessionLoad(
        using operationClient: EngineClient,
        acceptingServerProcessingStateAt revision: UInt64?,
        authoritativeProcessingSessionIds: Set<String>?
    ) -> Task<Bool, Never>? {
        guard !isTerminal else { return nil }
        let shouldDebounce = hasLoadedSessionsOnce
        hasLoadedSessionsOnce = true
        let origin = filterByOrigin ? operationClient.serverOrigin : nil
        let predecessor = loadSessionsTask
        if revision != nil || !loadSessionsTaskAcceptsServerProcessingState {
            predecessor?.cancel()
        }
        let task = Task { @MainActor [weak self] in
            _ = await predecessor?.value
            guard !Task.isCancelled else { return false }
            if shouldDebounce {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return false }
            }
            guard let self,
                  !self.isTerminal,
                  self.engineClient === operationClient else {
                return false
            }
            return await self._loadSessionsImmediate(
                using: operationClient,
                origin: origin,
                acceptingServerProcessingStateAt: revision,
                authoritativeProcessingSessionIds: authoritativeProcessingSessionIds
            )
        }
        loadSessionsTask = task
        loadSessionsTaskAcceptsServerProcessingState = revision != nil
        return task
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
            _ = await loadTask?.value
            activityManager.clearAll()
        }
        shutdownTask = drain
        await drain.value
    }

    /// Actual loadSessions implementation (called directly or after debounce).
    private func _loadSessionsImmediate(
        using operationClient: EngineClient,
        origin: String?,
        acceptingServerProcessingStateAt revision: UInt64?,
        authoritativeProcessingSessionIds: Set<String>?
    ) async -> Bool {
        do {
            var loadedSessions = try await eventDB.sessions.getByOrigin(origin).filter { !$0.isArchived }
            guard !Task.isCancelled,
                  !isTerminal,
                  engineClient === operationClient else {
                return false
            }

            // Capture transient projection state after the database suspension so an
            // accepted live update cannot be replaced by an earlier in-memory snapshot.
            let preservedActivityLines: [String: [ActivityLine]] = Dictionary(
                uniqueKeysWithValues: sessions.compactMap { session in
                    guard origin == nil || session.serverOrigin == origin,
                          let activityLines = session.lastActivityLines else {
                        return nil
                    }
                    return (session.id, activityLines)
                }
            )

            for i in loadedSessions.indices {
                let sessionId = loadedSessions[i].id
                if let activityLines = preservedActivityLines[sessionId] {
                    loadedSessions[i].lastActivityLines = activityLines
                }

                let rowOrigin = loadedSessions[i].serverOrigin ?? operationClient.serverOrigin
                let key = ProcessingOverrideKey(serverOrigin: rowOrigin, sessionId: sessionId)
                if let override = processingOverrides[key] {
                    let snapshotSuppliedProcessingState =
                        authoritativeProcessingSessionIds?.contains(sessionId) == true
                    let overrideIsNewer = revision.map { override.revision > $0 } ?? true
                    if !snapshotSuppliedProcessingState || overrideIsNewer {
                        loadedSessions[i].isProcessing = override.isProcessing
                    }
                }
            }

            guard !Task.isCancelled,
                  !isTerminal,
                  engineClient === operationClient else {
                return false
            }
            sessions = loadedSessions
            if let revision, let authoritativeProcessingSessionIds {
                processingOverrides = processingOverrides.filter { key, override in
                    key.serverOrigin != operationClient.serverOrigin ||
                        !authoritativeProcessingSessionIds.contains(key.sessionId) ||
                        override.revision > revision
                }
            }
            logger.info(
                "Loaded \(sessions.count) sessions from EventDatabase (origin filter: \(origin ?? "none"))",
                category: .session
            )
            return true
        } catch {
            guard !Task.isCancelled,
                  !isTerminal,
                  engineClient === operationClient else {
                return false
            }
            logger.error("Failed to load sessions: \(error.localizedDescription)", category: .session)
            sessions = []
            return false
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
