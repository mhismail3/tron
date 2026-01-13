import Foundation
import Combine

// MARK: - RPC Client Errors

enum RPCClientError: Error, LocalizedError {
    case noActiveSession
    case invalidURL
    case connectionNotEstablished

    var errorDescription: String? {
        switch self {
        case .noActiveSession: return "No active session"
        case .invalidURL: return "Invalid server URL"
        case .connectionNotEstablished: return "Connection not established"
        }
    }
}

// MARK: - RPC Client

@MainActor
class RPCClient: ObservableObject {
    private var webSocket: WebSocketService?
    private var cancellables = Set<AnyCancellable>()

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var currentSessionId: String?
    @Published private(set) var currentModel: String = "claude-opus-4-5-20251101"

    // Event callbacks (for current session)
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
    var onComplete: (() -> Void)?
    var onError: ((String) -> Void)?

    // Browser event callbacks
    var onBrowserFrame: ((BrowserFrameEvent) -> Void)?
    var onBrowserClosed: ((String) -> Void)?  // sessionId

    // Global event callbacks (for ALL sessions - used by dashboard)
    var onGlobalComplete: ((String) -> Void)?  // sessionId
    var onGlobalError: ((String, String) -> Void)?  // sessionId, message
    var onGlobalProcessingStart: ((String) -> Void)?  // sessionId

    private let serverURL: URL

    init(serverURL: URL) {
        self.serverURL = serverURL
    }

    // MARK: - Connection

    func connect() async {
        // Prevent duplicate connections - check if WebSocket already exists.
        // This prevents race conditions where multiple connect() calls happen
        // before the first one completes (common during app startup when
        // multiple views call connect() simultaneously).
        if webSocket != nil {
            logger.debug("Already connected, skipping connect", category: .rpc)
            return
        }

        // Also check connection state to prevent races during state transitions.
        // If we're already connecting or reconnecting, don't start another connection.
        switch connectionState {
        case .connected, .connecting, .reconnecting:
            logger.debug("Connection already in progress (\(connectionState)), skipping", category: .rpc)
            return
        case .disconnected, .failed:
            break
        }

        // Set connecting state BEFORE creating WebSocket to prevent concurrent attempts.
        // This is critical: if another connect() call comes in during the await below,
        // it will see .connecting state and bail out.
        connectionState = .connecting

        logger.info("Initializing connection to \(self.serverURL.absoluteString)", category: .rpc)

        let ws = WebSocketService(serverURL: serverURL)
        self.webSocket = ws

        // Observe connection state via @Published property
        ws.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.connectionState = state
            }
            .store(in: &cancellables)

        // Set event handler callback
        ws.onEvent = { [weak self] data in
            self?.handleEventData(data)
        }

        await ws.connect()
    }

    func disconnect() async {
        logger.info("Disconnecting from server", category: .rpc)
        currentSessionId = nil
        webSocket?.disconnect()
        webSocket = nil
        // Explicitly reset state to allow future connections.
        // The Combine subscription may not have delivered the .disconnected state yet
        // when webSocket is set to nil, leaving connectionState stale.
        connectionState = .disconnected
    }

    func reconnect() async {
        await disconnect()
        try? await Task.sleep(for: .milliseconds(500))
        await connect()
    }

    /// Forward background state to WebSocketService to pause heartbeats and save battery
    func setBackgroundState(_ inBackground: Bool) {
        webSocket?.setBackgroundState(inBackground)
    }

    // MARK: - Event Handling

    private func handleEventData(_ data: Data) {
        guard let event = ParsedEvent.parse(from: data) else {
            logger.warning("Failed to parse event data", category: .events)
            return
        }

        // Check session ID matches (for session-scoped events)
        func checkSession(_ sessionId: String?) -> Bool {
            guard let eventSessionId = sessionId else { return true }
            return eventSessionId == currentSessionId
        }

        switch event {
        case .textDelta(let e):
            guard checkSession(e.sessionId) else { return }
            onTextDelta?(e.delta)

        case .thinkingDelta(let e):
            guard checkSession(e.sessionId) else { return }
            onThinkingDelta?(e.delta)

        case .toolStart(let e):
            guard checkSession(e.sessionId) else { return }
            onToolStart?(e)

        case .toolEnd(let e):
            guard checkSession(e.sessionId) else { return }
            onToolEnd?(e)

        case .turnStart(let e):
            // Always notify global listeners for dashboard updates
            if let sessionId = e.sessionId {
                onGlobalProcessingStart?(sessionId)
            }
            guard checkSession(e.sessionId) else { return }
            onTurnStart?(e)

        case .turnEnd(let e):
            guard checkSession(e.sessionId) else { return }
            onTurnEnd?(e)

        case .agentTurn(let e):
            guard checkSession(e.sessionId) else { return }
            onAgentTurn?(e)

        case .complete(let e):
            // Always notify global listeners for dashboard updates
            if let sessionId = e.sessionId {
                onGlobalComplete?(sessionId)
            }
            guard checkSession(e.sessionId) else { return }
            onComplete?()

        case .compaction(let e):
            guard checkSession(e.sessionId) else { return }
            onCompaction?(e)

        case .contextCleared(let e):
            guard checkSession(e.sessionId) else { return }
            onContextCleared?(e)

        case .messageDeleted(let e):
            guard checkSession(e.sessionId) else { return }
            onMessageDeleted?(e)

        case .skillRemoved(let e):
            guard checkSession(e.sessionId) else { return }
            onSkillRemoved?(e)

        case .error(let e):
            // Always notify global listeners for dashboard updates
            if let sessionId = e.sessionId {
                onGlobalError?(sessionId, e.message)
            }
            guard checkSession(e.sessionId) else { return }
            onError?(e.message)

        case .connected(let e):
            logger.info("Server version: \(e.version ?? "unknown")", category: .rpc)

        case .browserFrame(let e):
            // Browser frames don't need session check - they include their own sessionId
            onBrowserFrame?(e)

        case .browserClosed(let sessionId):
            onBrowserClosed?(sessionId)

        case .unknown(let type):
            logger.debug("Unknown event type: \(type)", category: .events)
        }
    }

    // MARK: - Session Methods

    func createSession(
        workingDirectory: String,
        model: String? = nil
    ) async throws -> SessionCreateResult {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = SessionCreateParams(
            workingDirectory: workingDirectory,
            model: model,
            contextFiles: nil
        )

        let result: SessionCreateResult = try await ws.send(
            method: "session.create",
            params: params
        )

        currentSessionId = result.sessionId
        currentModel = result.model
        logger.info("Created session: \(result.sessionId)", category: .session)

        return result
    }

    func listSessions(
        workingDirectory: String? = nil,
        limit: Int = 50,
        includeEnded: Bool = false
    ) async throws -> [SessionInfo] {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = SessionListParams(
            workingDirectory: workingDirectory,
            limit: limit,
            includeEnded: includeEnded
        )

        let result: SessionListResult = try await ws.send(
            method: "session.list",
            params: params
        )

        return result.sessions
    }

    func resumeSession(sessionId: String) async throws {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = SessionResumeParams(sessionId: sessionId)
        let result: SessionResumeResult = try await ws.send(
            method: "session.resume",
            params: params
        )

        currentSessionId = result.sessionId
        currentModel = result.model
        logger.info("Resumed session: \(sessionId) with \(result.messageCount) messages", category: .session)
    }

    func endSession() async throws {
        guard let ws = webSocket,
              let sessionId = currentSessionId else {
            return
        }

        let params = SessionEndParams(sessionId: sessionId)
        let _: EmptyParams = try await ws.send(method: "session.end", params: params)

        currentSessionId = nil
        logger.info("Ended session: \(sessionId)", category: .session)
    }

    func getSessionHistory(limit: Int = 100) async throws -> [HistoryMessage] {
        guard let ws = webSocket,
              let sessionId = currentSessionId else {
            throw RPCClientError.noActiveSession
        }

        let params = SessionHistoryParams(
            sessionId: sessionId,
            limit: limit,
            beforeId: nil
        )

        let result: SessionHistoryResult = try await ws.send(
            method: "session.getHistory",
            params: params
        )

        return result.messages
    }

    // MARK: - Agent Methods

    func sendPrompt(
        _ prompt: String,
        images: [ImageAttachment]? = nil,
        attachments: [FileAttachment]? = nil,
        reasoningLevel: String? = nil,
        skills: [Skill]? = nil
    ) async throws {
        guard let ws = webSocket,
              let sessionId = currentSessionId else {
            throw RPCClientError.noActiveSession
        }

        let params = AgentPromptParams(
            sessionId: sessionId,
            prompt: prompt,
            images: images,
            attachments: attachments,
            reasoningLevel: reasoningLevel,
            skills: skills
        )

        let result: AgentPromptResult = try await ws.send(
            method: "agent.prompt",
            params: params
        )

        if !result.acknowledged {
            logger.warning("Prompt not acknowledged by server", category: .chat)
        }
    }

    func abortAgent() async throws {
        guard let ws = webSocket,
              let sessionId = currentSessionId else {
            return
        }

        let params = AgentAbortParams(sessionId: sessionId)
        let _: EmptyParams = try await ws.send(method: "agent.abort", params: params)
        logger.info("Aborted agent", category: .chat)
    }

    func getAgentState() async throws -> AgentStateResult {
        guard let ws = webSocket,
              let sessionId = currentSessionId else {
            throw RPCClientError.noActiveSession
        }

        let params = AgentStateParams(sessionId: sessionId)
        return try await ws.send(method: "agent.getState", params: params)
    }

    /// Get agent state for a specific session (used for dashboard polling)
    func getAgentStateForSession(sessionId: String) async throws -> AgentStateResult {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = AgentStateParams(sessionId: sessionId)
        return try await ws.send(method: "agent.getState", params: params)
    }

    // MARK: - Transcription Methods

    func transcribeAudio(
        audioData: Data,
        mimeType: String = "audio/m4a",
        fileName: String? = nil,
        transcriptionModelId: String? = nil,
        cleanupMode: String? = nil,
        language: String? = nil
    ) async throws -> TranscribeAudioResult {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let audioBase64 = await Task.detached(priority: .utility) {
            audioData.base64EncodedString()
        }.value

        let params = TranscribeAudioParams(
            sessionId: currentSessionId,
            audioBase64: audioBase64,
            mimeType: mimeType,
            fileName: fileName,
            transcriptionModelId: transcriptionModelId,
            cleanupMode: cleanupMode,
            language: language,
            prompt: nil,
            task: nil
        )

        return try await ws.send(
            method: "transcribe.audio",
            params: params,
            timeout: 180.0
        )
    }

    func listTranscriptionModels() async throws -> TranscribeListModelsResult {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        return try await ws.send(
            method: "transcribe.listModels",
            params: EmptyParams()
        )
    }

    // MARK: - System Methods

    func ping() async throws {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let _: SystemPingResult = try await ws.send(
            method: "system.ping",
            params: EmptyParams()
        )
    }

    func getSystemInfo() async throws -> SystemInfoResult {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        return try await ws.send(
            method: "system.getInfo",
            params: EmptyParams()
        )
    }

    // MARK: - Session Management (Extended)

    func deleteSession(_ sessionId: String) async throws -> Bool {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = SessionDeleteParams(sessionId: sessionId)
        let result: SessionDeleteResult = try await ws.send(
            method: "session.delete",
            params: params
        )

        if currentSessionId == sessionId {
            currentSessionId = nil
        }

        logger.info("Deleted session: \(sessionId)", category: .session)
        return result.deleted
    }

    func forkSession(_ sessionId: String, fromEventId: String? = nil) async throws -> SessionForkResult {
        guard let ws = webSocket else {
            logger.error("[FORK] Cannot fork - WebSocket not connected", category: .session)
            throw RPCClientError.connectionNotEstablished
        }

        let params = SessionForkParams(sessionId: sessionId, fromEventId: fromEventId)
        logger.info("[FORK] Sending fork request: sessionId=\(sessionId), fromEventId=\(fromEventId ?? "HEAD")", category: .session)

        let result: SessionForkResult = try await ws.send(
            method: "session.fork",
            params: params
        )

        logger.info("[FORK] Fork succeeded: newSessionId=\(result.newSessionId), forkedFromEventId=\(result.forkedFromEventId ?? "unknown"), rootEventId=\(result.rootEventId ?? "unknown")", category: .session)
        return result
    }

    // MARK: - Message Methods

    /// Delete a message from a session.
    /// This appends a message.deleted event to the event log.
    /// The message will be filtered out during reconstruction (two-pass).
    func deleteMessage(_ sessionId: String, targetEventId: String, reason: String? = "user_request") async throws -> MessageDeleteResult {
        guard let ws = webSocket else {
            logger.error("[DELETE] Cannot delete message - WebSocket not connected", category: .session)
            throw RPCClientError.connectionNotEstablished
        }

        let params = MessageDeleteParams(sessionId: sessionId, targetEventId: targetEventId, reason: reason)
        logger.info("[DELETE] Sending delete request: sessionId=\(sessionId), targetEventId=\(targetEventId)", category: .session)

        let result: MessageDeleteResult = try await ws.send(
            method: "message.delete",
            params: params
        )

        logger.info("[DELETE] Delete succeeded: deletionEventId=\(result.deletionEventId), targetType=\(result.targetType)", category: .session)
        return result
    }

    // MARK: - Model Methods

    func switchModel(_ sessionId: String, model: String) async throws -> ModelSwitchResult {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = ModelSwitchParams(sessionId: sessionId, model: model)
        let result: ModelSwitchResult = try await ws.send(
            method: "model.switch",
            params: params
        )

        if currentSessionId == sessionId {
            currentModel = result.newModel
        }

        logger.info("Switched model from \(result.previousModel) to \(result.newModel)", category: .session)
        return result
    }

    func listModels() async throws -> [ModelInfo] {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let result: ModelListResult = try await ws.send(
            method: "model.list",
            params: EmptyParams()
        )

        return result.models
    }

    // MARK: - Filesystem Methods

    func listDirectory(path: String?, showHidden: Bool = false) async throws -> DirectoryListResult {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = FilesystemListDirParams(path: path, showHidden: showHidden)
        return try await ws.send(
            method: "filesystem.listDir",
            params: params
        )
    }

    func getHome() async throws -> HomeResult {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        return try await ws.send(
            method: "filesystem.getHome",
            params: EmptyParams()
        )
    }

    /// Create a new directory
    func createDirectory(path: String, recursive: Bool = false) async throws -> FilesystemCreateDirResult {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = FilesystemCreateDirParams(path: path, recursive: recursive)
        return try await ws.send(
            method: "filesystem.createDir",
            params: params
        )
    }

    // MARK: - Memory Methods

    func searchMemory(
        query: String? = nil,
        type: String? = nil,
        source: String? = nil,
        limit: Int = 20
    ) async throws -> MemorySearchResult {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = MemorySearchParams(
            searchText: query,
            type: type,
            source: source,
            limit: limit
        )

        return try await ws.send(
            method: "memory.search",
            params: params
        )
    }

    func getHandoffs(workingDirectory: String? = nil, limit: Int = 10) async throws -> [Handoff] {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = HandoffsParams(workingDirectory: workingDirectory, limit: limit)
        let result: HandoffsResult = try await ws.send(
            method: "memory.getHandoffs",
            params: params
        )

        return result.handoffs
    }

    // MARK: - Context Methods

    /// Get context snapshot for a session
    func getContextSnapshot(sessionId: String) async throws -> ContextSnapshotResult {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = ContextGetSnapshotParams(sessionId: sessionId)
        return try await ws.send(
            method: "context.getSnapshot",
            params: params
        )
    }

    /// Get detailed context snapshot with per-message token breakdown
    func getDetailedContextSnapshot(sessionId: String) async throws -> DetailedContextSnapshotResult {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = ContextGetSnapshotParams(sessionId: sessionId)
        return try await ws.send(
            method: "context.getDetailedSnapshot",
            params: params
        )
    }

    /// Clear all messages from context, preserving system prompt and tools
    func clearContext(sessionId: String) async throws -> ContextClearResult {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = ContextClearParams(sessionId: sessionId)
        return try await ws.send(
            method: "context.clear",
            params: params
        )
    }

    /// Compact context by summarizing older messages
    func compactContext(sessionId: String) async throws -> ContextCompactResult {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = ContextCompactParams(sessionId: sessionId)
        return try await ws.send(
            method: "context.compact",
            params: params,
            timeout: 60.0  // Compaction can take a while
        )
    }

    // MARK: - Event Sync Methods

    /// Get event history for a session
    func getEventHistory(
        sessionId: String,
        types: [String]? = nil,
        limit: Int? = nil,
        beforeEventId: String? = nil
    ) async throws -> EventsGetHistoryResult {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = EventsGetHistoryParams(
            sessionId: sessionId,
            types: types,
            limit: limit,
            beforeEventId: beforeEventId
        )

        return try await ws.send(method: "events.getHistory", params: params)
    }

    /// Get events since a cursor (for incremental sync)
    func getEventsSince(
        sessionId: String? = nil,
        workspaceId: String? = nil,
        afterEventId: String? = nil,
        afterTimestamp: String? = nil,
        limit: Int? = nil
    ) async throws -> EventsGetSinceResult {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = EventsGetSinceParams(
            sessionId: sessionId,
            workspaceId: workspaceId,
            afterEventId: afterEventId,
            afterTimestamp: afterTimestamp,
            limit: limit
        )

        return try await ws.send(method: "events.getSince", params: params)
    }

    /// Get all events for a session (full sync)
    func getAllEvents(sessionId: String) async throws -> [RawEvent] {
        var allEvents: [RawEvent] = []
        var hasMore = true
        var beforeEventId: String? = nil

        while hasMore {
            let result = try await getEventHistory(
                sessionId: sessionId,
                limit: 100,
                beforeEventId: beforeEventId
            )
            allEvents.append(contentsOf: result.events)
            hasMore = result.hasMore
            beforeEventId = result.oldestEventId
        }

        // Events come in reverse order, so reverse them
        return allEvents.reversed()
    }

    // MARK: - Worktree Methods

    /// Get worktree status for a session
    func getWorktreeStatus(sessionId: String) async throws -> WorktreeGetStatusResult {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = WorktreeGetStatusParams(sessionId: sessionId)
        return try await ws.send(method: "worktree.getStatus", params: params)
    }

    /// Get worktree status for current session
    func getWorktreeStatus() async throws -> WorktreeGetStatusResult {
        guard let sessionId = currentSessionId else {
            throw RPCClientError.noActiveSession
        }
        return try await getWorktreeStatus(sessionId: sessionId)
    }

    /// Commit changes in a session's worktree
    func commitWorktree(sessionId: String, message: String) async throws -> WorktreeCommitResult {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = WorktreeCommitParams(sessionId: sessionId, message: message)
        let result: WorktreeCommitResult = try await ws.send(method: "worktree.commit", params: params)

        if result.success {
            logger.info("Committed worktree changes: \(result.commitHash ?? "unknown")", category: .session)
        }

        return result
    }

    /// Commit changes in current session's worktree
    func commitWorktree(message: String) async throws -> WorktreeCommitResult {
        guard let sessionId = currentSessionId else {
            throw RPCClientError.noActiveSession
        }
        return try await commitWorktree(sessionId: sessionId, message: message)
    }

    /// Merge a session's worktree to a target branch
    func mergeWorktree(
        sessionId: String,
        targetBranch: String,
        strategy: String? = nil
    ) async throws -> WorktreeMergeResult {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = WorktreeMergeParams(
            sessionId: sessionId,
            targetBranch: targetBranch,
            strategy: strategy
        )
        let result: WorktreeMergeResult = try await ws.send(method: "worktree.merge", params: params)

        if result.success {
            logger.info("Merged worktree to \(targetBranch): \(result.mergeCommit ?? "unknown")", category: .session)
        }

        return result
    }

    /// Merge current session's worktree to a target branch
    func mergeWorktree(targetBranch: String, strategy: String? = nil) async throws -> WorktreeMergeResult {
        guard let sessionId = currentSessionId else {
            throw RPCClientError.noActiveSession
        }
        return try await mergeWorktree(sessionId: sessionId, targetBranch: targetBranch, strategy: strategy)
    }

    /// List all worktrees
    func listWorktrees() async throws -> [WorktreeListItem] {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let result: WorktreeListResult = try await ws.send(
            method: "worktree.list",
            params: EmptyParams()
        )

        return result.worktrees
    }

    // MARK: - Tree Methods

    /// Get ancestor events for an event (traverses across session boundaries via parent_id chain)
    func getAncestors(_ eventId: String) async throws -> [RawEvent] {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = TreeGetAncestorsParams(eventId: eventId)
        logger.info("[ANCESTORS] Fetching ancestors for eventId=\(eventId)", category: .session)

        let result: TreeGetAncestorsResult = try await ws.send(
            method: "tree.getAncestors",
            params: params
        )

        logger.info("[ANCESTORS] Received \(result.events.count) ancestor events", category: .session)
        return result.events
    }

    // MARK: - Voice Notes Methods

    /// Save a voice note with transcription
    func saveVoiceNote(
        audioData: Data,
        mimeType: String = "audio/m4a",
        fileName: String? = nil,
        transcriptionModelId: String? = nil
    ) async throws -> VoiceNotesSaveResult {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        // Encode audio to base64 off main thread
        let audioBase64 = await Task.detached(priority: .utility) {
            audioData.base64EncodedString()
        }.value

        let params = VoiceNotesSaveParams(
            audioBase64: audioBase64,
            mimeType: mimeType,
            fileName: fileName,
            transcriptionModelId: transcriptionModelId
        )

        return try await ws.send(
            method: "voiceNotes.save",
            params: params,
            timeout: 180.0  // 3 minutes for transcription
        )
    }

    /// List saved voice notes
    func listVoiceNotes(limit: Int = 50, offset: Int = 0) async throws -> VoiceNotesListResult {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = VoiceNotesListParams(limit: limit, offset: offset)
        return try await ws.send(method: "voiceNotes.list", params: params)
    }

    /// Delete a voice note
    func deleteVoiceNote(filename: String) async throws -> VoiceNotesDeleteResult {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = VoiceNotesDeleteParams(filename: filename)
        return try await ws.send(method: "voiceNotes.delete", params: params)
    }

    // MARK: - Browser Methods

    /// Start browser frame streaming for a session
    func startBrowserStream(
        sessionId: String,
        quality: Int = 60,
        maxWidth: Int = 1280,
        maxHeight: Int = 800
    ) async throws -> BrowserStartStreamResult {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = BrowserStartStreamParams(
            sessionId: sessionId,
            quality: quality,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            format: "jpeg",
            everyNthFrame: 1
        )

        return try await ws.send(method: "browser.startStream", params: params)
    }

    /// Stop browser frame streaming for a session
    func stopBrowserStream(sessionId: String) async throws -> BrowserStopStreamResult {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = BrowserStopStreamParams(sessionId: sessionId)
        return try await ws.send(method: "browser.stopStream", params: params)
    }

    /// Get browser status for a session
    func getBrowserStatus(sessionId: String) async throws -> BrowserGetStatusResult {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = BrowserGetStatusParams(sessionId: sessionId)
        return try await ws.send(method: "browser.getStatus", params: params)
    }

    /// Get browser status for current session
    func getBrowserStatus() async throws -> BrowserGetStatusResult {
        guard let sessionId = currentSessionId else {
            throw RPCClientError.noActiveSession
        }
        return try await getBrowserStatus(sessionId: sessionId)
    }

    // MARK: - Skill Methods

    /// List available skills
    func listSkills(sessionId: String? = nil, source: String? = nil) async throws -> SkillListResponse {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = SkillListParams(
            sessionId: sessionId ?? currentSessionId,
            source: source
        )
        return try await ws.send(method: "skill.list", params: params)
    }

    /// Get a skill by name
    func getSkill(name: String, sessionId: String? = nil) async throws -> SkillGetResponse {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = SkillGetParams(
            sessionId: sessionId ?? currentSessionId,
            name: name
        )
        return try await ws.send(method: "skill.get", params: params)
    }

    /// Refresh skills cache
    func refreshSkills(sessionId: String? = nil) async throws -> SkillRefreshResponse {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = SkillRefreshParams(sessionId: sessionId ?? currentSessionId)
        return try await ws.send(method: "skill.refresh", params: params)
    }

    /// Remove a skill from session context
    func removeSkill(sessionId: String, skillName: String) async throws -> SkillRemoveResponse {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = SkillRemoveParams(sessionId: sessionId, skillName: skillName)
        return try await ws.send(method: "skill.remove", params: params)
    }

    // MARK: - File Reading

    /// Read file content from server
    func readFile(path: String) async throws -> String {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        struct ReadFileParams: Codable {
            let path: String
        }

        struct ReadFileResult: Codable {
            let content: String
        }

        let params = ReadFileParams(path: path)
        let result: ReadFileResult = try await ws.send(method: "file.read", params: params)
        return result.content
    }

    // MARK: - State Accessors

    var isConnected: Bool {
        connectionState.isConnected
    }

    var hasActiveSession: Bool {
        currentSessionId != nil
    }
}
