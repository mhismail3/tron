import Foundation
import Combine
@testable import TronMobile

/// Mock RPC client for testing
@MainActor
final class MockRPCClient: ObservableObject, RPCClientProtocol {
    // MARK: - Published State
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var currentSessionId: String?
    @Published private(set) var currentModel: String = "claude-opus-4-5-20251101"

    // MARK: - Event Callbacks
    var onTextDelta: ((String) -> Void)?
    var onThinkingDelta: ((String) -> Void)?
    var onToolStart: ((ToolStartEvent) -> Void)?
    var onToolEnd: ((ToolEndEvent) -> Void)?
    var onTurnStart: ((TurnStartEvent) -> Void)?
    var onTurnEnd: ((TurnEndEvent) -> Void)?
    var onAgentTurn: ((AgentTurnEvent) -> Void)?
    var onCompaction: ((CompactionEvent) -> Void)?
    var onContextCleared: ((ContextClearedEvent) -> Void)?
    var onMessageDeleted: ((MessageDeletedEvent) -> Void)?
    var onSkillRemoved: ((SkillRemovedEvent) -> Void)?
    var onPlanModeEntered: ((PlanModeEnteredEvent) -> Void)?
    var onPlanModeExited: ((PlanModeExitedEvent) -> Void)?
    var onComplete: (() -> Void)?
    var onError: ((String) -> Void)?
    var onBrowserFrame: ((BrowserFrameEvent) -> Void)?
    var onBrowserClosed: ((String) -> Void)?
    var onGlobalComplete: ((String) -> Void)?
    var onGlobalError: ((String, String) -> Void)?
    var onGlobalProcessingStart: ((String) -> Void)?

    // MARK: - Computed Properties
    var isConnected: Bool { connectionState.isConnected }
    var hasActiveSession: Bool { currentSessionId != nil }

    // MARK: - Test Configuration
    var mockSessions: [SessionInfo] = []
    var mockAgentState = AgentStateResult(isRunning: false)
    var mockModels: [ModelInfo] = []
    var shouldFailConnection = false
    var shouldFailPrompt = false

    // MARK: - Call Tracking
    var connectCalled = false
    var disconnectCalled = false
    var sendPromptCalled = false
    var lastPromptSent: String?
    var abortAgentCalled = false

    // MARK: - Connection
    func connect() async {
        connectCalled = true
        if shouldFailConnection {
            connectionState = .failed(RPCClientError.invalidURL)
        } else {
            connectionState = .connected
        }
    }

    func disconnect() async {
        disconnectCalled = true
        currentSessionId = nil
        connectionState = .disconnected
    }

    func reconnect() async {
        await disconnect()
        await connect()
    }

    func setBackgroundState(_ inBackground: Bool) {}

    // MARK: - Session Methods
    func createSession(workingDirectory: String, model: String?) async throws -> SessionCreateResult {
        let sessionId = "mock-session-\(UUID().uuidString.prefix(8))"
        currentSessionId = sessionId
        currentModel = model ?? "claude-opus-4-5-20251101"
        return SessionCreateResult(sessionId: sessionId, model: currentModel)
    }

    func listSessions(workingDirectory: String?, limit: Int, includeEnded: Bool) async throws -> [SessionInfo] {
        return mockSessions
    }

    func resumeSession(sessionId: String) async throws {
        currentSessionId = sessionId
    }

    func endSession() async throws {
        currentSessionId = nil
    }

    func getSessionHistory(limit: Int) async throws -> [HistoryMessage] {
        return []
    }

    func deleteSession(_ sessionId: String) async throws -> Bool {
        mockSessions.removeAll { $0.sessionId == sessionId }
        if currentSessionId == sessionId {
            currentSessionId = nil
        }
        return true
    }

    func forkSession(_ sessionId: String, fromEventId: String?) async throws -> SessionForkResult {
        let newSessionId = "fork-\(UUID().uuidString.prefix(8))"
        return SessionForkResult(
            newSessionId: newSessionId,
            forkedFromEventId: fromEventId,
            rootEventId: "root-\(UUID().uuidString.prefix(8))",
            worktree: nil
        )
    }

    // MARK: - Agent Methods
    func sendPrompt(_ prompt: String, images: [ImageAttachment]?, attachments: [FileAttachment]?, reasoningLevel: String?, skills: [Skill]?) async throws {
        sendPromptCalled = true
        lastPromptSent = prompt
        if shouldFailPrompt {
            throw RPCClientError.noActiveSession
        }
    }

    func abortAgent() async throws {
        abortAgentCalled = true
    }

    func getAgentState() async throws -> AgentStateResult {
        return mockAgentState
    }

    func getAgentStateForSession(sessionId: String) async throws -> AgentStateResult {
        return mockAgentState
    }

    // MARK: - Transcription Methods
    func transcribeAudio(audioData: Data, mimeType: String, fileName: String?, transcriptionModelId: String?, cleanupMode: String?, language: String?) async throws -> TranscribeAudioResult {
        return TranscribeAudioResult(text: "Mock transcription", duration: 1.0)
    }

    func listTranscriptionModels() async throws -> TranscribeListModelsResult {
        return TranscribeListModelsResult(models: [], defaultModelId: "default")
    }

    // MARK: - System Methods
    func ping() async throws {}

    func getSystemInfo() async throws -> SystemInfoResult {
        return SystemInfoResult(version: "1.0.0-mock", hostname: "mock-host", uptime: 0, gitCommit: nil)
    }

    // MARK: - Message Methods
    func deleteMessage(_ sessionId: String, targetEventId: String, reason: String?) async throws -> MessageDeleteResult {
        return MessageDeleteResult(success: true, deletionEventId: "del-\(UUID().uuidString.prefix(8))", targetType: "message")
    }

    // MARK: - Tool Result Methods
    func sendToolResult(sessionId: String, toolCallId: String, result: AskUserQuestionResult) async throws {}

    // MARK: - Model Methods
    func switchModel(_ sessionId: String, model: String) async throws -> ModelSwitchResult {
        let previous = currentModel
        currentModel = model
        return ModelSwitchResult(previousModel: previous, newModel: model)
    }

    func listModels() async throws -> [ModelInfo] {
        return mockModels
    }

    // MARK: - Filesystem Methods
    func listDirectory(path: String?, showHidden: Bool) async throws -> DirectoryListResult {
        return DirectoryListResult(entries: [], path: path ?? "/")
    }

    func getHome() async throws -> HomeResult {
        return HomeResult(home: "/Users/mock")
    }

    func createDirectory(path: String, recursive: Bool) async throws -> FilesystemCreateDirResult {
        return FilesystemCreateDirResult(success: true, path: path)
    }

    // MARK: - Memory Methods
    func searchMemory(query: String?, type: String?, source: String?, limit: Int) async throws -> MemorySearchResult {
        return MemorySearchResult(results: [])
    }

    func getHandoffs(workingDirectory: String?, limit: Int) async throws -> [Handoff] {
        return []
    }

    // MARK: - Context Methods
    func getContextSnapshot(sessionId: String) async throws -> ContextSnapshotResult {
        return ContextSnapshotResult(tokenCount: 0, maxTokens: 200000, messageCount: 0, systemPromptTokens: 0, toolsTokens: 0)
    }

    func getDetailedContextSnapshot(sessionId: String) async throws -> DetailedContextSnapshotResult {
        return DetailedContextSnapshotResult(
            tokenCount: 0,
            maxTokens: 200000,
            systemPromptTokens: 0,
            toolsTokens: 0,
            messages: []
        )
    }

    func clearContext(sessionId: String) async throws -> ContextClearResult {
        return ContextClearResult(clearedMessageCount: 0, clearedTokenCount: 0)
    }

    func compactContext(sessionId: String) async throws -> ContextCompactResult {
        return ContextCompactResult(originalTokens: 0, compactedTokens: 0, messagesPruned: 0, summaryCreated: false)
    }

    // MARK: - Event Sync Methods
    func getEventHistory(sessionId: String, types: [String]?, limit: Int?, beforeEventId: String?) async throws -> EventsGetHistoryResult {
        return EventsGetHistoryResult(events: [], hasMore: false, oldestEventId: nil)
    }

    func getEventsSince(sessionId: String?, workspaceId: String?, afterEventId: String?, afterTimestamp: String?, limit: Int?) async throws -> EventsGetSinceResult {
        return EventsGetSinceResult(events: [], hasMore: false, newestEventId: nil)
    }

    func getAllEvents(sessionId: String) async throws -> [RawEvent] {
        return []
    }

    // MARK: - Worktree Methods
    func getWorktreeStatus(sessionId: String) async throws -> WorktreeGetStatusResult {
        return WorktreeGetStatusResult(hasWorktree: false, branch: nil, clean: true, changedFiles: [], untrackedFiles: [])
    }

    func getWorktreeStatus() async throws -> WorktreeGetStatusResult {
        guard let sessionId = currentSessionId else {
            throw RPCClientError.noActiveSession
        }
        return try await getWorktreeStatus(sessionId: sessionId)
    }

    func commitWorktree(sessionId: String, message: String) async throws -> WorktreeCommitResult {
        return WorktreeCommitResult(success: true, commitHash: "abc123", message: message)
    }

    func commitWorktree(message: String) async throws -> WorktreeCommitResult {
        guard let sessionId = currentSessionId else {
            throw RPCClientError.noActiveSession
        }
        return try await commitWorktree(sessionId: sessionId, message: message)
    }

    func mergeWorktree(sessionId: String, targetBranch: String, strategy: String?) async throws -> WorktreeMergeResult {
        return WorktreeMergeResult(success: true, mergeCommit: "def456", conflicts: [])
    }

    func mergeWorktree(targetBranch: String, strategy: String?) async throws -> WorktreeMergeResult {
        guard let sessionId = currentSessionId else {
            throw RPCClientError.noActiveSession
        }
        return try await mergeWorktree(sessionId: sessionId, targetBranch: targetBranch, strategy: strategy)
    }

    func listWorktrees() async throws -> [WorktreeListItem] {
        return []
    }

    // MARK: - Tree Methods
    func getAncestors(_ eventId: String) async throws -> [RawEvent] {
        return []
    }

    // MARK: - Voice Notes Methods
    func saveVoiceNote(audioData: Data, mimeType: String, fileName: String?, transcriptionModelId: String?) async throws -> VoiceNotesSaveResult {
        return VoiceNotesSaveResult(filename: "mock.m4a", transcription: "Mock transcription", duration: 1.0)
    }

    func listVoiceNotes(limit: Int, offset: Int) async throws -> VoiceNotesListResult {
        return VoiceNotesListResult(notes: [], total: 0)
    }

    func deleteVoiceNote(filename: String) async throws -> VoiceNotesDeleteResult {
        return VoiceNotesDeleteResult(success: true)
    }

    // MARK: - Browser Methods
    func startBrowserStream(sessionId: String, quality: Int, maxWidth: Int, maxHeight: Int) async throws -> BrowserStartStreamResult {
        return BrowserStartStreamResult(started: true)
    }

    func stopBrowserStream(sessionId: String) async throws -> BrowserStopStreamResult {
        return BrowserStopStreamResult(stopped: true)
    }

    func getBrowserStatus(sessionId: String) async throws -> BrowserGetStatusResult {
        return BrowserGetStatusResult(isActive: false, isStreaming: false, url: nil)
    }

    func getBrowserStatus() async throws -> BrowserGetStatusResult {
        guard let sessionId = currentSessionId else {
            throw RPCClientError.noActiveSession
        }
        return try await getBrowserStatus(sessionId: sessionId)
    }

    // MARK: - Skill Methods
    func listSkills(sessionId: String?, source: String?) async throws -> SkillListResponse {
        return SkillListResponse(skills: [])
    }

    func getSkill(name: String, sessionId: String?) async throws -> SkillGetResponse {
        return SkillGetResponse(skill: nil)
    }

    func refreshSkills(sessionId: String?) async throws -> SkillRefreshResponse {
        return SkillRefreshResponse(refreshed: true, count: 0)
    }

    func removeSkill(sessionId: String, skillName: String) async throws -> SkillRemoveResponse {
        return SkillRemoveResponse(removed: true)
    }

    // MARK: - File Reading
    func readFile(path: String) async throws -> String {
        return "Mock file content"
    }

    // MARK: - Test Helpers
    func setConnectionState(_ state: ConnectionState) {
        connectionState = state
    }

    func setCurrentSession(_ sessionId: String?, model: String? = nil) {
        currentSessionId = sessionId
        if let model = model {
            currentModel = model
        }
    }

    func simulateTextDelta(_ text: String) {
        onTextDelta?(text)
    }

    func simulateToolStart(_ event: ToolStartEvent) {
        onToolStart?(event)
    }

    func simulateToolEnd(_ event: ToolEndEvent) {
        onToolEnd?(event)
    }

    func simulateComplete() {
        onComplete?()
    }

    func simulateError(_ message: String) {
        onError?(message)
    }
}
