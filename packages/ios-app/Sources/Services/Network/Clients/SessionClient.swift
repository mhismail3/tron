import Foundation

/// Client for session-related engine capabilities.
/// Handles session creation, listing, resumption, deletion, and forking.
final class SessionClient: EngineDomainClient {

    // MARK: - Session Methods

    func create(
        workingDirectory: String,
        model: String? = nil,
        title: String? = nil,
        source: String? = nil,
        profile: String? = nil,
        useWorktree: Bool? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> SessionCreateResult {
        _ = try requireTransport().requireConnection()

        let params = SessionCreateParams(
            workingDirectory: workingDirectory,
            model: model,
            contextFiles: nil,
            title: title,
            source: source,
            profile: profile,
            useWorktree: useWorktree
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
        offset: Int = 0,
        includeArchived: Bool = false
    ) async throws -> SessionListResult {
        _ = try requireTransport().requireConnection()

        let params = SessionListParams(
            workingDirectory: workingDirectory,
            limit: limit,
            offset: offset,
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

    // MARK: - Reconstruction

    /// Reconstruct full session state for reconnection.
    ///
    /// Returns persisted events + in-flight state + metadata in one response.
    /// The client uses `lastSequence` as its high-water mark for WebSocket dedup.
    func reconstruct(
        sessionId: String,
        limit: Int? = nil,
        beforeSequence: Int64? = nil
    ) async throws -> SessionReconstructResult {
        _ = try requireTransport().requireConnection()

        let params = SessionReconstructParams(
            sessionId: sessionId,
            limit: limit,
            beforeSequence: beforeSequence
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
