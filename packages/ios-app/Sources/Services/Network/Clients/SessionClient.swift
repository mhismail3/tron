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
        offset: Int = 0,
        includeArchived: Bool = false
    ) async throws -> SessionListResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = SessionListParams(
            workingDirectory: workingDirectory,
            limit: limit,
            offset: offset,
            includeArchived: includeArchived
        )

        let result: SessionListResult = try await ws.send(
            method: "session.list",
            params: params
        )

        // DEBUG: Log cache tokens from server response
        for session in result.sessions {
            logger.debug("[SESSION-LIST-RAW] \(session.sessionId.prefix(12)): cacheRead=\(session.cacheReadTokens ?? -1) cacheWrite=\(session.cacheCreationTokens ?? -1)", category: .session)
        }

        return result
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

    func archive(_ sessionId: String) async throws {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = SessionArchiveParams(sessionId: sessionId)
        let _: EmptyParams = try await ws.send(method: "session.archive", params: params)

        if transport.currentSessionId == sessionId {
            transport.setCurrentSessionId(nil)
        }
        logger.info("Archived session: \(sessionId)", category: .session)
    }

    func unarchive(_ sessionId: String) async throws {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = SessionUnarchiveParams(sessionId: sessionId)
        let _: EmptyParams = try await ws.send(method: "session.unarchive", params: params)

        logger.info("Unarchived session: \(sessionId)", category: .session)
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
