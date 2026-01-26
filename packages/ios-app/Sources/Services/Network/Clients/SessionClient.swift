import Foundation

/// Client for session-related RPC methods.
/// Handles session creation, listing, resumption, deletion, and forking.
@MainActor
final class SessionClient {
    private weak var transport: RPCTransport?

    init(transport: RPCTransport) {
        self.transport = transport
    }

    // MARK: - Session Methods

    func create(
        workingDirectory: String,
        model: String? = nil
    ) async throws -> SessionCreateResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = SessionCreateParams(
            workingDirectory: workingDirectory,
            model: model,
            contextFiles: nil
        )

        let result: SessionCreateResult = try await ws.send(
            method: "session.create",
            params: params
        )

        transport.setCurrentSessionId(result.sessionId)
        transport.setCurrentModel(result.model)
        logger.info("Created session: \(result.sessionId)", category: .session)

        return result
    }

    func list(
        workingDirectory: String? = nil,
        limit: Int = 50,
        includeEnded: Bool = false
    ) async throws -> [SessionInfo] {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

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

    func resume(sessionId: String) async throws {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = SessionResumeParams(sessionId: sessionId)
        let result: SessionResumeResult = try await ws.send(
            method: "session.resume",
            params: params
        )

        transport.setCurrentSessionId(result.sessionId)
        transport.setCurrentModel(result.model)
        logger.info("Resumed session: \(sessionId) with \(result.messageCount) messages", category: .session)
    }

    func end() async throws {
        guard let transport else { return }
        guard let (ws, sessionId) = try? transport.requireSession() else { return }

        let params = SessionEndParams(sessionId: sessionId)
        let _: EmptyParams = try await ws.send(method: "session.end", params: params)

        transport.setCurrentSessionId(nil)
        logger.info("Ended session: \(sessionId)", category: .session)
    }

    func getHistory(limit: Int = 100) async throws -> [HistoryMessage] {
        guard let transport else { throw RPCClientError.noActiveSession }
        let (ws, sessionId) = try transport.requireSession()

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

    func delete(_ sessionId: String) async throws -> Bool {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = SessionDeleteParams(sessionId: sessionId)
        let result: SessionDeleteResult = try await ws.send(
            method: "session.delete",
            params: params
        )

        if transport.currentSessionId == sessionId {
            transport.setCurrentSessionId(nil)
        }

        logger.info("Deleted session: \(sessionId)", category: .session)
        return result.deleted
    }

    func fork(_ sessionId: String, fromEventId: String? = nil) async throws -> SessionForkResult {
        guard let transport else {
            logger.error("[FORK] Cannot fork - WebSocket not connected", category: .session)
            throw RPCClientError.connectionNotEstablished
        }
        let ws = try transport.requireConnection()

        let params = SessionForkParams(sessionId: sessionId, fromEventId: fromEventId)
        logger.info("[FORK] Sending fork request: sessionId=\(sessionId), fromEventId=\(fromEventId ?? "HEAD")", category: .session)

        let result: SessionForkResult = try await ws.send(
            method: "session.fork",
            params: params
        )

        logger.info("[FORK] Fork succeeded: newSessionId=\(result.newSessionId), forkedFromEventId=\(result.forkedFromEventId ?? "unknown"), rootEventId=\(result.rootEventId ?? "unknown")", category: .session)
        return result
    }
}
