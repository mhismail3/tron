import Foundation
import Combine
import os

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
    private let logger = Logger(subsystem: "com.tron.mobile", category: "RPCClient")

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
        logger.info("Initializing connection to \(self.serverURL.absoluteString)")

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
        logger.info("Disconnecting")
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
            logger.warning("Failed to parse event")
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
            logger.info("Connected to server version: \(e.version ?? "unknown")")

        case .unknown(let type):
            logger.debug("Unknown event type: \(type)")
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
        logger.info("Created session: \(result.sessionId)")

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
        let result: SessionCreateResult = try await ws.send(
            method: "session.resume",
            params: params
        )

        currentSessionId = result.sessionId
        currentModel = result.model
        logger.info("Resumed session: \(sessionId)")
    }

    func endSession() async throws {
        guard let ws = webSocket,
              let sessionId = currentSessionId else {
            return
        }

        let params = SessionEndParams(sessionId: sessionId)
        let _: EmptyParams = try await ws.send(method: "session.end", params: params)

        currentSessionId = nil
        logger.info("Ended session: \(sessionId)")
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
            logger.warning("Prompt not acknowledged")
        }
    }

    func abortAgent() async throws {
        guard let ws = webSocket,
              let sessionId = currentSessionId else {
            return
        }

        let params = AgentAbortParams(sessionId: sessionId)
        let _: EmptyParams = try await ws.send(method: "agent.abort", params: params)
        logger.info("Aborted agent")
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

    // MARK: - State Accessors

    var isConnected: Bool {
        connectionState.isConnected
    }

    var hasActiveSession: Bool {
        currentSessionId != nil
    }
}
