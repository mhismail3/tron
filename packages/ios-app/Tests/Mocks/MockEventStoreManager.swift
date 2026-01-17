import Foundation
import Combine
@testable import TronMobile

/// Mock EventStoreManager for testing
/// Note: Does not strictly conform to EventStoreManagerProtocol to avoid concrete type requirements.
/// Use this directly in tests for simulating EventStoreManager behavior.
@MainActor
final class MockEventStoreManager: ObservableObject {
    // MARK: - Published State
    @Published var sessions: [CachedSession] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncError: String?
    @Published private(set) var activeSessionId: String?

    // MARK: - Session Change Notification
    let sessionUpdated = PassthroughSubject<String, Never>()

    // MARK: - Turn Content Cache
    var turnContentCache: [String: (messages: [[String: Any]], timestamp: Date)] = [:]
    let maxCachedSessions = 10
    let cacheExpiry: TimeInterval = 120

    // MARK: - Processing State
    var processingSessionIds: Set<String> = []
    var pollingTask: Task<Void, Never>?
    private(set) var isPollingActive = false
    private(set) var isInBackground = false

    // MARK: - In-Memory Storage (replaces database)
    var mockEvents: [String: SessionEvent] = [:]
    var mockSessions: [String: CachedSession] = [:]

    // MARK: - Call Tracking
    var loadSessionsCalled = false
    var fullSyncCalled = false
    var syncSessionEventsCalled = false
    var deleteSessionCalled = false
    var forkSessionCalled = false
    var initializeCalled = false

    // MARK: - Computed Properties
    var sortedSessions: [CachedSession] {
        sessions.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    var activeSession: CachedSession? {
        guard let id = activeSessionId else { return nil }
        return sessions.first { $0.id == id }
    }

    // MARK: - State Setters
    func setIsSyncing(_ value: Bool) {
        isSyncing = value
    }

    func setLastSyncError(_ value: String?) {
        lastSyncError = value
    }

    func clearLastSyncError() {
        lastSyncError = nil
    }

    func setIsPollingActive(_ value: Bool) {
        isPollingActive = value
    }

    func setIsInBackground(_ value: Bool) {
        isInBackground = value
    }

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

    // MARK: - Session List
    func loadSessions() {
        loadSessionsCalled = true
        sessions = Array(mockSessions.values).sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    func setActiveSession(_ sessionId: String?) {
        activeSessionId = sessionId
    }

    func sessionExists(_ sessionId: String) -> Bool {
        sessions.contains { $0.id == sessionId }
    }

    // MARK: - State Reconstruction
    func getChatMessages(sessionId: String) throws -> [ChatMessage] {
        guard let session = mockSessions[sessionId],
              let headEventId = session.headEventId else {
            return []
        }
        let events = getAncestors(headEventId)
        return UnifiedEventTransformer.transformPersistedEvents(events)
    }

    func getReconstructedState(sessionId: String) throws -> UnifiedEventTransformer.ReconstructedState {
        guard let session = mockSessions[sessionId],
              let headEventId = session.headEventId else {
            return UnifiedEventTransformer.ReconstructedState()
        }
        let events = getAncestors(headEventId)
        return UnifiedEventTransformer.reconstructSessionState(from: events)
    }

    private func getAncestors(_ eventId: String) -> [SessionEvent] {
        var ancestors: [SessionEvent] = []
        var currentId: String? = eventId

        while let id = currentId {
            guard let event = mockEvents[id] else { break }
            ancestors.insert(event, at: 0)
            currentId = event.parentId
        }

        return ancestors
    }

    // MARK: - Server Sync
    func fullSync() async {
        fullSyncCalled = true
        isSyncing = true
        try? await Task.sleep(for: .milliseconds(10))
        isSyncing = false
    }

    func syncSessionEvents(sessionId: String) async throws {
        syncSessionEventsCalled = true
    }

    func fullSyncSession(_ sessionId: String) async throws {
        // Clear events for session
        mockEvents = mockEvents.filter { $0.value.sessionId != sessionId }
    }

    func updateSessionMetadata(sessionId: String) async throws {}

    func serverSessionToCached(_ info: SessionInfo) -> CachedSession {
        let now = ISO8601DateFormatter().string(from: Date())
        return CachedSession(
            id: info.sessionId,
            workspaceId: info.workingDirectory ?? "",
            rootEventId: nil,
            headEventId: nil,
            title: info.displayName,
            latestModel: info.model,
            workingDirectory: info.workingDirectory ?? "",
            createdAt: info.createdAt,
            lastActivityAt: now,
            endedAt: info.isActive ? nil : now,
            eventCount: 0,
            messageCount: info.messageCount,
            inputTokens: info.inputTokens ?? 0,
            outputTokens: info.outputTokens ?? 0,
            lastTurnInputTokens: info.lastTurnInputTokens ?? 0,
            cacheReadTokens: info.cacheReadTokens ?? 0,
            cacheCreationTokens: info.cacheCreationTokens ?? 0,
            cost: info.cost ?? 0
        )
    }

    func rawEventToSessionEvent(_ raw: RawEvent) -> SessionEvent {
        SessionEvent(
            id: raw.id,
            parentId: raw.parentId,
            sessionId: raw.sessionId,
            workspaceId: raw.workspaceId,
            type: raw.type,
            timestamp: raw.timestamp,
            sequence: raw.sequence,
            payload: raw.payload
        )
    }

    // MARK: - Session Operations
    func cacheNewSession(sessionId: String, workspaceId: String, model: String, workingDirectory: String) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let session = CachedSession(
            id: sessionId,
            workspaceId: workspaceId,
            rootEventId: nil,
            headEventId: nil,
            title: URL(fileURLWithPath: workingDirectory).lastPathComponent,
            latestModel: model,
            workingDirectory: workingDirectory,
            createdAt: now,
            lastActivityAt: now,
            endedAt: nil,
            eventCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            cost: 0
        )
        mockSessions[sessionId] = session
        loadSessions()
    }

    func deleteSession(_ sessionId: String) async throws {
        deleteSessionCalled = true
        mockSessions.removeValue(forKey: sessionId)
        mockEvents = mockEvents.filter { $0.value.sessionId != sessionId }
        if activeSessionId == sessionId {
            setActiveSession(sessions.first?.id)
        }
        loadSessions()
    }

    func updateSessionTokens(sessionId: String, inputTokens: Int, outputTokens: Int, lastTurnInputTokens: Int, cacheReadTokens: Int, cacheCreationTokens: Int, cost: Double) throws {
        guard var session = mockSessions[sessionId] else { return }
        session.inputTokens = inputTokens
        session.outputTokens = outputTokens
        session.lastTurnInputTokens = lastTurnInputTokens
        session.cacheReadTokens = cacheReadTokens
        session.cacheCreationTokens = cacheCreationTokens
        session.cost = cost
        mockSessions[sessionId] = session
        loadSessions()
    }

    func forkSession(_ sessionId: String, fromEventId: String? = nil) async throws -> String {
        forkSessionCalled = true
        return "fork-\(UUID().uuidString.prefix(8))"
    }

    func getSessionEvents(_ sessionId: String) throws -> [SessionEvent] {
        return mockEvents.values
            .filter { $0.sessionId == sessionId }
            .sorted { $0.sequence < $1.sequence }
    }

    func getTreeVisualization(_ sessionId: String) throws -> [EventTreeNode] {
        return []
    }

    // MARK: - Lifecycle
    func initialize() {
        initializeCalled = true
        loadSessions()
    }

    func clearAll() throws {
        mockEvents.removeAll()
        mockSessions.removeAll()
        clearSessions()
        setActiveSessionId(nil)
    }

    func repairDuplicates() {}

    func repairSession(_ sessionId: String) {}

    // MARK: - Dashboard
    func extractDashboardInfoFromEvents(sessionId: String) {}

    func updateSessionDashboardInfo(sessionId: String, lastUserPrompt: String? = nil, lastAssistantResponse: String? = nil, lastToolCount: Int? = nil) {
        if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            updateSession(at: index) { session in
                if let prompt = lastUserPrompt {
                    session.lastUserPrompt = prompt
                }
                if let response = lastAssistantResponse {
                    session.lastAssistantResponse = response
                }
                if let toolCount = lastToolCount {
                    session.lastToolCount = toolCount
                }
            }
        }
    }

    func setSessionProcessing(_ sessionId: String, isProcessing: Bool) {
        if isProcessing {
            processingSessionIds.insert(sessionId)
        } else {
            processingSessionIds.remove(sessionId)
        }
        if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            updateSession(at: index) { $0.isProcessing = isProcessing }
        }
    }

    func restoreProcessingSessionIds() {}

    func setBackgroundState(_ inBackground: Bool) {
        isInBackground = inBackground
    }

    func startDashboardPolling() {
        isPollingActive = true
    }

    func stopDashboardPolling() {
        isPollingActive = false
        pollingTask?.cancel()
        pollingTask = nil
    }

    func pollAllSessionStates() async {}

    func checkSessionProcessingState(sessionId: String) async {}

    // MARK: - Cache
    func cacheTurnContent(sessionId: String, turnNumber: Int, messages: [[String: Any]]) {
        turnContentCache[sessionId] = (messages, Date())
    }

    func getCachedTurnContent(sessionId: String) -> [[String: Any]]? {
        return turnContentCache[sessionId]?.messages
    }

    func clearCachedTurnContent(sessionId: String) {
        turnContentCache.removeValue(forKey: sessionId)
    }

    func cleanExpiredCacheEntries() {
        let now = Date()
        turnContentCache = turnContentCache.filter { now.timeIntervalSince($0.value.timestamp) <= cacheExpiry }
    }

    func enrichEventsWithCachedContent(events: [SessionEvent], sessionId: String) throws -> [SessionEvent] {
        return events
    }

    // MARK: - Test Helpers
    func addMockSession(_ session: CachedSession) {
        mockSessions[session.id] = session
        loadSessions()
    }

    func addMockEvent(_ event: SessionEvent) {
        mockEvents[event.id] = event
    }

    func createMockSession(
        id: String = "mock-session",
        workspaceId: String = "/test",
        title: String? = "Mock Session",
        model: String = "claude-opus-4-5-20251101"
    ) -> CachedSession {
        let now = ISO8601DateFormatter().string(from: Date())
        return CachedSession(
            id: id,
            workspaceId: workspaceId,
            rootEventId: nil,
            headEventId: nil,
            title: title,
            latestModel: model,
            workingDirectory: workspaceId,
            createdAt: now,
            lastActivityAt: now,
            endedAt: nil,
            eventCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            cost: 0
        )
    }

    func createMockEvent(
        id: String = "mock-event",
        sessionId: String = "mock-session",
        type: String = "message.user",
        payload: [String: AnyCodable] = [:]
    ) -> SessionEvent {
        return SessionEvent(
            id: id,
            parentId: nil,
            sessionId: sessionId,
            workspaceId: "/test",
            type: type,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            sequence: 0,
            payload: payload
        )
    }
}
