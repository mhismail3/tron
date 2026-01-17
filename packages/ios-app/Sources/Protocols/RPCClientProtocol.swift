import Foundation
import Combine

/// Protocol for RPC client enabling dependency injection and mocking
@MainActor
protocol RPCClientProtocol: ObservableObject {
    // MARK: - Published State
    var connectionState: ConnectionState { get }
    var currentSessionId: String? { get }
    var currentModel: String { get }

    // MARK: - Event Callbacks
    var onTextDelta: ((String) -> Void)? { get set }
    var onThinkingDelta: ((String) -> Void)? { get set }
    var onToolStart: ((ToolStartEvent) -> Void)? { get set }
    var onToolEnd: ((ToolEndEvent) -> Void)? { get set }
    var onTurnStart: ((TurnStartEvent) -> Void)? { get set }
    var onTurnEnd: ((TurnEndEvent) -> Void)? { get set }
    var onAgentTurn: ((AgentTurnEvent) -> Void)? { get set }
    var onCompaction: ((CompactionEvent) -> Void)? { get set }
    var onContextCleared: ((ContextClearedEvent) -> Void)? { get set }
    var onMessageDeleted: ((MessageDeletedEvent) -> Void)? { get set }
    var onSkillRemoved: ((SkillRemovedEvent) -> Void)? { get set }
    var onPlanModeEntered: ((PlanModeEnteredEvent) -> Void)? { get set }
    var onPlanModeExited: ((PlanModeExitedEvent) -> Void)? { get set }
    var onComplete: (() -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }

    // Browser event callbacks
    var onBrowserFrame: ((BrowserFrameEvent) -> Void)? { get set }
    var onBrowserClosed: ((String) -> Void)? { get set }

    // Global event callbacks
    var onGlobalComplete: ((String) -> Void)? { get set }
    var onGlobalError: ((String, String) -> Void)? { get set }
    var onGlobalProcessingStart: ((String) -> Void)? { get set }

    // MARK: - Computed Properties
    var isConnected: Bool { get }
    var hasActiveSession: Bool { get }

    // MARK: - Connection
    func connect() async
    func disconnect() async
    func reconnect() async
    func setBackgroundState(_ inBackground: Bool)

    // MARK: - Session Methods
    func createSession(
        workingDirectory: String,
        model: String?
    ) async throws -> SessionCreateResult

    func listSessions(
        workingDirectory: String?,
        limit: Int,
        includeEnded: Bool
    ) async throws -> [SessionInfo]

    func resumeSession(sessionId: String) async throws
    func endSession() async throws
    func getSessionHistory(limit: Int) async throws -> [HistoryMessage]
    func deleteSession(_ sessionId: String) async throws -> Bool
    func forkSession(_ sessionId: String, fromEventId: String?) async throws -> SessionForkResult

    // MARK: - Agent Methods
    func sendPrompt(
        _ prompt: String,
        images: [ImageAttachment]?,
        attachments: [FileAttachment]?,
        reasoningLevel: String?,
        skills: [Skill]?
    ) async throws

    func abortAgent() async throws
    func getAgentState() async throws -> AgentStateResult
    func getAgentStateForSession(sessionId: String) async throws -> AgentStateResult

    // MARK: - Transcription Methods
    func transcribeAudio(
        audioData: Data,
        mimeType: String,
        fileName: String?,
        transcriptionModelId: String?,
        cleanupMode: String?,
        language: String?
    ) async throws -> TranscribeAudioResult

    func listTranscriptionModels() async throws -> TranscribeListModelsResult

    // MARK: - System Methods
    func ping() async throws
    func getSystemInfo() async throws -> SystemInfoResult

    // MARK: - Message Methods
    func deleteMessage(
        _ sessionId: String,
        targetEventId: String,
        reason: String?
    ) async throws -> MessageDeleteResult

    // MARK: - Tool Result Methods
    func sendToolResult(
        sessionId: String,
        toolCallId: String,
        result: AskUserQuestionResult
    ) async throws

    // MARK: - Model Methods
    func switchModel(_ sessionId: String, model: String) async throws -> ModelSwitchResult
    func listModels() async throws -> [ModelInfo]

    // MARK: - Filesystem Methods
    func listDirectory(path: String?, showHidden: Bool) async throws -> DirectoryListResult
    func getHome() async throws -> HomeResult
    func createDirectory(path: String, recursive: Bool) async throws -> FilesystemCreateDirResult

    // MARK: - Memory Methods
    func searchMemory(
        query: String?,
        type: String?,
        source: String?,
        limit: Int
    ) async throws -> MemorySearchResult

    func getHandoffs(workingDirectory: String?, limit: Int) async throws -> [Handoff]

    // MARK: - Context Methods
    func getContextSnapshot(sessionId: String) async throws -> ContextSnapshotResult
    func getDetailedContextSnapshot(sessionId: String) async throws -> DetailedContextSnapshotResult
    func clearContext(sessionId: String) async throws -> ContextClearResult
    func compactContext(sessionId: String) async throws -> ContextCompactResult

    // MARK: - Event Sync Methods
    func getEventHistory(
        sessionId: String,
        types: [String]?,
        limit: Int?,
        beforeEventId: String?
    ) async throws -> EventsGetHistoryResult

    func getEventsSince(
        sessionId: String?,
        workspaceId: String?,
        afterEventId: String?,
        afterTimestamp: String?,
        limit: Int?
    ) async throws -> EventsGetSinceResult

    func getAllEvents(sessionId: String) async throws -> [RawEvent]

    // MARK: - Worktree Methods
    func getWorktreeStatus(sessionId: String) async throws -> WorktreeGetStatusResult
    func getWorktreeStatus() async throws -> WorktreeGetStatusResult
    func commitWorktree(sessionId: String, message: String) async throws -> WorktreeCommitResult
    func commitWorktree(message: String) async throws -> WorktreeCommitResult
    func mergeWorktree(sessionId: String, targetBranch: String, strategy: String?) async throws -> WorktreeMergeResult
    func mergeWorktree(targetBranch: String, strategy: String?) async throws -> WorktreeMergeResult
    func listWorktrees() async throws -> [WorktreeListItem]

    // MARK: - Tree Methods
    func getAncestors(_ eventId: String) async throws -> [RawEvent]

    // MARK: - Voice Notes Methods
    func saveVoiceNote(
        audioData: Data,
        mimeType: String,
        fileName: String?,
        transcriptionModelId: String?
    ) async throws -> VoiceNotesSaveResult

    func listVoiceNotes(limit: Int, offset: Int) async throws -> VoiceNotesListResult
    func deleteVoiceNote(filename: String) async throws -> VoiceNotesDeleteResult

    // MARK: - Browser Methods
    func startBrowserStream(
        sessionId: String,
        quality: Int,
        maxWidth: Int,
        maxHeight: Int
    ) async throws -> BrowserStartStreamResult

    func stopBrowserStream(sessionId: String) async throws -> BrowserStopStreamResult
    func getBrowserStatus(sessionId: String) async throws -> BrowserGetStatusResult
    func getBrowserStatus() async throws -> BrowserGetStatusResult

    // MARK: - Skill Methods
    func listSkills(sessionId: String?, source: String?) async throws -> SkillListResponse
    func getSkill(name: String, sessionId: String?) async throws -> SkillGetResponse
    func refreshSkills(sessionId: String?) async throws -> SkillRefreshResponse
    func removeSkill(sessionId: String, skillName: String) async throws -> SkillRemoveResponse

    // MARK: - File Reading
    func readFile(path: String) async throws -> String
}

// MARK: - Default Implementation for Optional Parameters

extension RPCClientProtocol {
    func listSessions(
        workingDirectory: String? = nil,
        limit: Int = 50,
        includeEnded: Bool = false
    ) async throws -> [SessionInfo] {
        try await listSessions(workingDirectory: workingDirectory, limit: limit, includeEnded: includeEnded)
    }

    func createSession(
        workingDirectory: String,
        model: String? = nil
    ) async throws -> SessionCreateResult {
        try await createSession(workingDirectory: workingDirectory, model: model)
    }

    func getSessionHistory(limit: Int = 100) async throws -> [HistoryMessage] {
        try await getSessionHistory(limit: limit)
    }

    func forkSession(_ sessionId: String, fromEventId: String? = nil) async throws -> SessionForkResult {
        try await forkSession(sessionId, fromEventId: fromEventId)
    }

    func sendPrompt(
        _ prompt: String,
        images: [ImageAttachment]? = nil,
        attachments: [FileAttachment]? = nil,
        reasoningLevel: String? = nil,
        skills: [Skill]? = nil
    ) async throws {
        try await sendPrompt(prompt, images: images, attachments: attachments, reasoningLevel: reasoningLevel, skills: skills)
    }

    func transcribeAudio(
        audioData: Data,
        mimeType: String = "audio/m4a",
        fileName: String? = nil,
        transcriptionModelId: String? = nil,
        cleanupMode: String? = nil,
        language: String? = nil
    ) async throws -> TranscribeAudioResult {
        try await transcribeAudio(audioData: audioData, mimeType: mimeType, fileName: fileName, transcriptionModelId: transcriptionModelId, cleanupMode: cleanupMode, language: language)
    }

    func deleteMessage(_ sessionId: String, targetEventId: String, reason: String? = "user_request") async throws -> MessageDeleteResult {
        try await deleteMessage(sessionId, targetEventId: targetEventId, reason: reason)
    }

    func listDirectory(path: String?, showHidden: Bool = false) async throws -> DirectoryListResult {
        try await listDirectory(path: path, showHidden: showHidden)
    }

    func createDirectory(path: String, recursive: Bool = false) async throws -> FilesystemCreateDirResult {
        try await createDirectory(path: path, recursive: recursive)
    }

    func searchMemory(query: String? = nil, type: String? = nil, source: String? = nil, limit: Int = 20) async throws -> MemorySearchResult {
        try await searchMemory(query: query, type: type, source: source, limit: limit)
    }

    func getHandoffs(workingDirectory: String? = nil, limit: Int = 10) async throws -> [Handoff] {
        try await getHandoffs(workingDirectory: workingDirectory, limit: limit)
    }

    func getEventHistory(sessionId: String, types: [String]? = nil, limit: Int? = nil, beforeEventId: String? = nil) async throws -> EventsGetHistoryResult {
        try await getEventHistory(sessionId: sessionId, types: types, limit: limit, beforeEventId: beforeEventId)
    }

    func getEventsSince(sessionId: String? = nil, workspaceId: String? = nil, afterEventId: String? = nil, afterTimestamp: String? = nil, limit: Int? = nil) async throws -> EventsGetSinceResult {
        try await getEventsSince(sessionId: sessionId, workspaceId: workspaceId, afterEventId: afterEventId, afterTimestamp: afterTimestamp, limit: limit)
    }

    func mergeWorktree(sessionId: String, targetBranch: String, strategy: String? = nil) async throws -> WorktreeMergeResult {
        try await mergeWorktree(sessionId: sessionId, targetBranch: targetBranch, strategy: strategy)
    }

    func mergeWorktree(targetBranch: String, strategy: String? = nil) async throws -> WorktreeMergeResult {
        try await mergeWorktree(targetBranch: targetBranch, strategy: strategy)
    }

    func saveVoiceNote(audioData: Data, mimeType: String = "audio/m4a", fileName: String? = nil, transcriptionModelId: String? = nil) async throws -> VoiceNotesSaveResult {
        try await saveVoiceNote(audioData: audioData, mimeType: mimeType, fileName: fileName, transcriptionModelId: transcriptionModelId)
    }

    func listVoiceNotes(limit: Int = 50, offset: Int = 0) async throws -> VoiceNotesListResult {
        try await listVoiceNotes(limit: limit, offset: offset)
    }

    func startBrowserStream(sessionId: String, quality: Int = 60, maxWidth: Int = 1280, maxHeight: Int = 800) async throws -> BrowserStartStreamResult {
        try await startBrowserStream(sessionId: sessionId, quality: quality, maxWidth: maxWidth, maxHeight: maxHeight)
    }

    func listSkills(sessionId: String? = nil, source: String? = nil) async throws -> SkillListResponse {
        try await listSkills(sessionId: sessionId, source: source)
    }

    func getSkill(name: String, sessionId: String? = nil) async throws -> SkillGetResponse {
        try await getSkill(name: name, sessionId: sessionId)
    }

    func refreshSkills(sessionId: String? = nil) async throws -> SkillRefreshResponse {
        try await refreshSkills(sessionId: sessionId)
    }
}

// MARK: - RPCClient Conformance

extension RPCClient: RPCClientProtocol {}
