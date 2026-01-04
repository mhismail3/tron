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
    @Published private(set) var currentModel: String = "claude-sonnet-4-20250514"

    // Event callbacks
    var onTextDelta: ((String) -> Void)?
    var onThinkingDelta: ((String) -> Void)?
    var onToolStart: ((ToolStartEvent) -> Void)?
    var onToolEnd: ((ToolEndEvent) -> Void)?
    var onTurnStart: ((TurnStartEvent) -> Void)?
    var onTurnEnd: ((TurnEndEvent) -> Void)?
    var onComplete: (() -> Void)?
    var onError: ((String) -> Void)?

    private let serverURL: URL

    init(serverURL: URL) {
        self.serverURL = serverURL
    }

    // MARK: - Connection

    func connect() async {
        // Don't reconnect if already connected
        if webSocket != nil && connectionState.isConnected {
            log.debug("Already connected, skipping connect", category: .rpc)
            return
        }

        log.info("Initializing connection to \(self.serverURL.absoluteString)", category: .rpc)

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
        log.info("Disconnecting from server", category: .rpc)
        currentSessionId = nil
        webSocket?.disconnect()
        webSocket = nil
    }

    func reconnect() async {
        await disconnect()
        try? await Task.sleep(for: .milliseconds(500))
        await connect()
    }

    // MARK: - Event Handling

    private func handleEventData(_ data: Data) {
        guard let event = ParsedEvent.parse(from: data) else {
            log.warning("Failed to parse event data", category: .events)
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
            guard checkSession(e.sessionId) else { return }
            onTurnStart?(e)

        case .turnEnd(let e):
            guard checkSession(e.sessionId) else { return }
            onTurnEnd?(e)

        case .complete(let e):
            guard checkSession(e.sessionId) else { return }
            onComplete?()

        case .error(let e):
            guard checkSession(e.sessionId) else { return }
            onError?(e.message)

        case .connected(let e):
            log.info("Server version: \(e.version ?? "unknown")", category: .rpc)

        case .unknown(let type):
            log.debug("Unknown event type: \(type)", category: .events)
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
        log.info("Created session: \(result.sessionId)", category: .session)

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
        log.info("Resumed session: \(sessionId) with \(result.messageCount) messages", category: .session)
    }

    func endSession() async throws {
        guard let ws = webSocket,
              let sessionId = currentSessionId else {
            return
        }

        let params = SessionEndParams(sessionId: sessionId)
        let _: EmptyParams = try await ws.send(method: "session.end", params: params)

        currentSessionId = nil
        log.info("Ended session: \(sessionId)", category: .session)
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
        images: [ImageAttachment]? = nil
    ) async throws {
        guard let ws = webSocket,
              let sessionId = currentSessionId else {
            throw RPCClientError.noActiveSession
        }

        let params = AgentPromptParams(
            sessionId: sessionId,
            prompt: prompt,
            images: images
        )

        let result: AgentPromptResult = try await ws.send(
            method: "agent.prompt",
            params: params
        )

        if !result.acknowledged {
            log.warning("Prompt not acknowledged by server", category: .chat)
        }
    }

    func abortAgent() async throws {
        guard let ws = webSocket,
              let sessionId = currentSessionId else {
            return
        }

        let params = AgentAbortParams(sessionId: sessionId)
        let _: EmptyParams = try await ws.send(method: "agent.abort", params: params)
        log.info("Aborted agent", category: .chat)
    }

    func getAgentState() async throws -> AgentStateResult {
        guard let ws = webSocket,
              let sessionId = currentSessionId else {
            throw RPCClientError.noActiveSession
        }

        let params = AgentStateParams(sessionId: sessionId)
        return try await ws.send(method: "agent.getState", params: params)
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

        log.info("Deleted session: \(sessionId)", category: .session)
        return result.deleted
    }

    func forkSession(_ sessionId: String, fromIndex: Int? = nil) async throws -> SessionForkResult {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = SessionForkParams(sessionId: sessionId, fromMessageIndex: fromIndex)
        let result: SessionForkResult = try await ws.send(
            method: "session.fork",
            params: params
        )

        log.info("Forked session \(sessionId) to \(result.newSessionId)", category: .session)
        return result
    }

    func rewindSession(_ sessionId: String, toIndex: Int) async throws -> SessionRewindResult {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = SessionRewindParams(sessionId: sessionId, toMessageIndex: toIndex)
        let result: SessionRewindResult = try await ws.send(
            method: "session.rewind",
            params: params
        )

        log.info("Rewound session \(sessionId) to message \(toIndex)", category: .session)
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

        log.info("Switched model from \(result.previousModel) to \(result.newModel)", category: .session)
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

    // MARK: - State Accessors

    var isConnected: Bool {
        connectionState.isConnected
    }

    var hasActiveSession: Bool {
        currentSessionId != nil
    }
}
