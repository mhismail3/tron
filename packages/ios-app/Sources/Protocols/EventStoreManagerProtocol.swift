import Foundation
import Combine

/// Protocol for EventStoreManager enabling dependency injection and mocking
@MainActor
protocol EventStoreManagerProtocol: ObservableObject {
    // MARK: - Published State
    var sessions: [CachedSession] { get }
    var isSyncing: Bool { get }
    var lastSyncError: String? { get }
    var activeSessionId: String? { get }

    // MARK: - Session Change Notification
    var sessionUpdated: PassthroughSubject<String, Never> { get }

    // MARK: - Turn Content Cache
    var turnContentCache: [String: (messages: [[String: Any]], timestamp: Date)] { get set }
    var maxCachedSessions: Int { get }
    var cacheExpiry: TimeInterval { get }

    // MARK: - Processing State
    var processingSessionIds: Set<String> { get set }
    var pollingTask: Task<Void, Never>? { get set }
    var isPollingActive: Bool { get }
    var isInBackground: Bool { get }

    // MARK: - Dependencies
    var eventDB: EventDatabase { get }
    var rpcClient: RPCClient { get }

    /// Update the RPC client (e.g., when server settings change)
    func updateRPCClient(_ client: RPCClient)

    // MARK: - Computed Properties
    var sortedSessions: [CachedSession] { get }
    var activeSession: CachedSession? { get }

    // MARK: - State Setters
    func setIsSyncing(_ value: Bool)
    func setLastSyncError(_ value: String?)
    func clearLastSyncError()
    func setIsPollingActive(_ value: Bool)
    func setIsInBackground(_ value: Bool)
    func clearSessions()
    func setSessions(_ newSessions: [CachedSession])
    func updateSession(at index: Int, _ update: (inout CachedSession) -> Void)
    func setActiveSessionId(_ sessionId: String?)

    // MARK: - Session List
    func loadSessions()
    func setActiveSession(_ sessionId: String?)
    func sessionExists(_ sessionId: String) -> Bool

    // MARK: - State Reconstruction
    func getChatMessages(sessionId: String) throws -> [ChatMessage]
    func getReconstructedState(sessionId: String) throws -> UnifiedEventTransformer.ReconstructedState

    // MARK: - Server Sync (from +Sync extension)
    func fullSync() async
    func syncSessionEvents(sessionId: String) async throws
    func fullSyncSession(_ sessionId: String) async throws
    func updateSessionMetadata(sessionId: String) async throws
    func serverSessionToCached(_ info: SessionInfo, serverOrigin: String?) -> CachedSession
    func rawEventToSessionEvent(_ raw: RawEvent) -> SessionEvent

    // MARK: - Session Operations (from +Operations extension)
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

    // MARK: - Dashboard (from +Dashboard extension)
    func extractDashboardInfoFromEvents(sessionId: String)
    func updateSessionDashboardInfo(sessionId: String, lastUserPrompt: String?, lastAssistantResponse: String?, lastToolCount: Int?)
    func setSessionProcessing(_ sessionId: String, isProcessing: Bool)
    func restoreProcessingSessionIds()
    func setBackgroundState(_ inBackground: Bool)
    func startDashboardPolling()
    func stopDashboardPolling()
    func pollAllSessionStates() async
    func checkSessionProcessingState(sessionId: String) async

    // MARK: - Cache (from +Cache extension)
    func cacheTurnContent(sessionId: String, turnNumber: Int, messages: [[String: Any]])
    func getCachedTurnContent(sessionId: String) -> [[String: Any]]?
    func clearCachedTurnContent(sessionId: String)
    func cleanExpiredCacheEntries()
    func enrichEventsWithCachedContent(events: [SessionEvent], sessionId: String) throws -> [SessionEvent]
}

// MARK: - Default Implementation for Optional Parameters

extension EventStoreManagerProtocol {
    func forkSession(_ sessionId: String, fromEventId: String? = nil) async throws -> String {
        try await forkSession(sessionId, fromEventId: fromEventId)
    }
}

// MARK: - EventStoreManager Conformance

extension EventStoreManager: EventStoreManagerProtocol {}
