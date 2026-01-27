import Foundation

// MARK: - Session Store Protocol

/// Protocol for core session state management and CRUD operations
@MainActor
protocol SessionStoreProtocol: AnyObject {
    // MARK: - Observable State
    var sessions: [CachedSession] { get }
    var isSyncing: Bool { get }
    var lastSyncError: String? { get }
    var activeSessionId: String? { get }

    // MARK: - Session Change Notification (Async Stream API)
    /// Async stream of session IDs that have been updated
    var sessionUpdates: AsyncStream<String> { get }

    // MARK: - Processing State
    var processingSessionIds: Set<String> { get set }

    // MARK: - Computed Properties
    var sortedSessions: [CachedSession] { get }
    var activeSession: CachedSession? { get }

    // MARK: - State Setters
    func setIsSyncing(_ value: Bool)
    func setLastSyncError(_ value: String?)
    func clearLastSyncError()
    func clearSessions()
    func setSessions(_ newSessions: [CachedSession])
    func updateSession(at index: Int, _ update: (inout CachedSession) -> Void)
    func setActiveSessionId(_ sessionId: String?)

    // MARK: - Optimistic Local Updates
    func removeSessionLocally(_ sessionId: String) -> (session: CachedSession, index: Int)?
    func insertSessionLocally(_ session: CachedSession, at index: Int)

    // MARK: - Session List
    func loadSessions()
    func setActiveSession(_ sessionId: String?)
    func sessionExists(_ sessionId: String) -> Bool

    // MARK: - State Reconstruction
    func getChatMessages(sessionId: String) throws -> [ChatMessage]
    func getReconstructedState(sessionId: String) throws -> ReconstructedState

    // MARK: - Session Operations
    func cacheNewSession(
        sessionId: String,
        workspaceId: String,
        model: String,
        workingDirectory: String
    ) throws

    func deleteSession(_ sessionId: String) async throws

    func updateSessionTokens(
        sessionId: String,
        inputTokens: Int,
        outputTokens: Int,
        lastTurnInputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int,
        cost: Double
    ) throws

    func forkSession(_ sessionId: String, fromEventId: String?) async throws -> String
    func getSessionEvents(_ sessionId: String) throws -> [SessionEvent]
    func getTreeVisualization(_ sessionId: String) throws -> [EventTreeNode]

    // MARK: - Lifecycle
    func initialize()
    func clearAll() throws
    func repairDuplicates()
    func repairSession(_ sessionId: String)

    // MARK: - Dashboard Info
    func extractDashboardInfoFromEvents(sessionId: String)
    func updateSessionDashboardInfo(sessionId: String, lastUserPrompt: String?, lastAssistantResponse: String?, lastToolCount: Int?)
    func setSessionProcessing(_ sessionId: String, isProcessing: Bool)
    func restoreProcessingSessionIds()
}

// MARK: - Session Sync Protocol

/// Protocol for server synchronization operations
@MainActor
protocol SessionSyncProtocol {
    func fullSync() async
    func syncSessionEvents(sessionId: String) async throws
    func fullSyncSession(_ sessionId: String) async throws
    func updateSessionMetadata(sessionId: String) async throws
    func serverSessionToCached(_ info: SessionInfo, serverOrigin: String?) -> CachedSession
    func rawEventToSessionEvent(_ raw: RawEvent) -> SessionEvent
}

// MARK: - Dashboard Polling Protocol

/// Protocol for dashboard polling lifecycle management
@MainActor
protocol DashboardPollingProtocol {
    func setBackgroundState(_ inBackground: Bool)
    func startDashboardPolling()
    func stopDashboardPolling()
    func pollAllSessionStates() async
    func checkSessionProcessingState(sessionId: String) async
}

// MARK: - Combined Protocol (for dependency injection)

/// Combined protocol for EventStoreManager enabling full dependency injection
/// Composes SessionStoreProtocol, SessionSyncProtocol, and DashboardPollingProtocol
@MainActor
protocol EventStoreManagerProtocol: SessionStoreProtocol, SessionSyncProtocol, DashboardPollingProtocol {
    // MARK: - Components
    var turnContentCache: TurnContentCache { get }
    var dashboardPoller: DashboardPoller { get }
    var sessionStateChecker: SessionStateChecker { get }
    var sessionSynchronizer: SessionSynchronizer { get }

    // MARK: - Dependencies
    var eventDB: EventDatabase { get }
    var rpcClient: RPCClient { get }

    /// Update the RPC client (e.g., when server settings change)
    func updateRPCClient(_ client: RPCClient)
}

// MARK: - Default Implementation for Optional Parameters

extension SessionStoreProtocol {
    func forkSession(_ sessionId: String, fromEventId: String? = nil) async throws -> String {
        try await forkSession(sessionId, fromEventId: fromEventId)
    }
}

// MARK: - EventStoreManager Conformance

extension EventStoreManager: EventStoreManagerProtocol {}
