import Foundation

/// Client for session-related engine tools.
/// Handles session creation, listing, resumption, deletion, and forking.
final class SessionClient: EngineDomainClient {

    // MARK: - Session Methods

    func create(
        workingDirectory: String,
        model: String? = nil,
        title: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> SessionCreateResult {
        _ = try requireTransport().requireConnection()

        let params = SessionCreateParams(
            workingDirectory: workingDirectory,
            model: model,
            title: title
        )

        let result: SessionCreateResult = try await invokeWrite(
            "session::create",
            params,
            idempotencyKey: idempotencyKey
        )

        currentTransport?.setCurrentSessionId(result.sessionId)
        currentTransport?.setCurrentModel(result.model)
        logger.info("Created session: \(result.sessionId)", category: .session)

        return result
    }

    func list(
        workingDirectory: String? = nil,
        limit: Int = 50,
        cursor: String? = nil,
        includeArchived: Bool = false
    ) async throws -> SessionListResult {
        _ = try requireTransport().requireConnection()

        let params = SessionListParams(
            workingDirectory: workingDirectory,
            limit: limit,
            cursor: cursor,
            includeArchived: includeArchived
        )

        let result: SessionListResult = try await invokeRead(
            "session::list",
            params
        )

        return result
    }

    func resume(sessionId: String, idempotencyKey: EngineIdempotencyKey) async throws {
        _ = try requireTransport().requireConnection()

        let params = SessionResumeParams(sessionId: sessionId)
        let result: SessionResumeResult = try await invokeWrite(
            "session::resume",
            params,
            idempotencyKey: idempotencyKey,
            context: sessionContext(sessionId)
        )

        currentTransport?.setCurrentSessionId(result.sessionId)
        currentTransport?.setCurrentModel(result.model)
        logger.info("Resumed session: \(sessionId) with \(result.messageCount) messages", category: .session)
    }

    func archive(_ sessionId: String, idempotencyKey: EngineIdempotencyKey) async throws {
        _ = try requireTransport().requireConnection()

        let params = SessionArchiveParams(sessionId: sessionId)
        let _: EmptyParams = try await invokeWrite(
            "session::archive",
            params,
            idempotencyKey: idempotencyKey,
            context: sessionContext(sessionId)
        )

        if currentTransport?.currentSessionId == sessionId {
            currentTransport?.setCurrentSessionId(nil)
        }
        logger.info("Archived session: \(sessionId)", category: .session)
    }

    func unarchive(_ sessionId: String, idempotencyKey: EngineIdempotencyKey) async throws {
        _ = try requireTransport().requireConnection()

        let params = SessionUnarchiveParams(sessionId: sessionId)
        let _: EmptyParams = try await invokeWrite(
            "session::unarchive",
            params,
            idempotencyKey: idempotencyKey,
            context: sessionContext(sessionId)
        )

        logger.info("Unarchived session: \(sessionId)", category: .session)
    }

    func getHistory(limit: Int = 100) async throws -> [HistoryMessage] {
        let (_, sessionId) = try requireTransport().requireSession()

        let params = SessionHistoryParams(
            sessionId: sessionId,
            limit: limit,
            beforeId: nil
        )

        let result: SessionHistoryResult = try await invokeRead(
            "session::get_history",
            params
        )

        return result.messages
    }

    func contextRequests(
        sessionId: String,
        beforeSequence: Int64? = nil,
        limit: Int = 10
    ) async throws -> SessionContextRequestsResultDTO {
        try await invokeRead(
            "session::context_requests",
            SessionContextRequestsParams(
                sessionId: sessionId,
                beforeSequence: beforeSequence,
                limit: min(max(limit, 1), 20)
            ),
            context: sessionContext(sessionId)
        )
    }

    func contextRequestDetail(
        sessionId: String,
        eventId: String
    ) async throws -> SessionContextRequestDetailDTO {
        try await invokeRead(
            "session::context_request_detail",
            SessionContextRequestDetailParams(sessionId: sessionId, eventId: eventId),
            context: sessionContext(sessionId)
        )
    }

    func agentUpdates(
        sessionId: String,
        limit: Int = 100
    ) async throws -> SessionAgentUpdatesResultDTO {
        try await invokeRead(
            "session::agent_updates",
            SessionAgentUpdatesParams(
                sessionId: sessionId,
                limit: min(max(limit, 1), 200)
            ),
            context: sessionContext(sessionId)
        )
    }

    // MARK: - Reconstruction

    /// Reconstruct full session state for reconnection.
    ///
    /// Returns persisted events + in-flight state + metadata in one response.
    /// The client uses `lastSequence` as its high-water mark for WebSocket dedup.
    func reconstruct(
        sessionId: String,
        limit: Int? = nil,
        beforeEventId: String? = nil
    ) async throws -> SessionReconstructResult {
        _ = try requireTransport().requireConnection()

        let params = SessionReconstructParams(
            sessionId: sessionId,
            limit: limit,
            beforeEventId: beforeEventId
        )

        let result: SessionReconstructResult = try await invokeRead(
            "session::reconstruct",
            params
        )

        logger.info("Reconstructed session \(sessionId): \(result.events.count) events, isRunning=\(result.isRunning), lastSeq=\(result.lastSequence)", category: .session)
        return result
    }

    // MARK: - Fork

    func fork(
        _ sessionId: String,
        fromEventId: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> SessionForkResult {
        _ = try requireTransport().requireConnection()

        let params = SessionForkParams(sessionId: sessionId, fromEventId: fromEventId)
        logger.info("[FORK] Sending fork request: sessionId=\(sessionId), fromEventId=\(fromEventId ?? "HEAD")", category: .session)

        let result: SessionForkResult = try await invokeWrite(
            "session::fork",
            params,
            idempotencyKey: idempotencyKey,
            context: sessionContext(sessionId)
        )

        logger.info("[FORK] Fork succeeded: newSessionId=\(result.newSessionId), forkedFromEventId=\(result.forkedFromEventId ?? "unknown"), rootEventId=\(result.rootEventId ?? "unknown")", category: .session)
        return result
    }

    private func sessionContext(_ sessionId: String) -> EngineInvocationContext {
        EngineInvocationContext(sessionId: sessionId)
    }
}
