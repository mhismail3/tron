import Foundation

/// Client for session-related RPC methods.
/// Handles session creation, listing, resumption, deletion, and forking.
final class SessionClient: RPCDomainClient {

    // MARK: - Session Methods

    func create(
        workingDirectory: String,
        model: String? = nil,
        title: String? = nil,
        source: String? = nil
    ) async throws -> SessionCreateResult {
        let ws = try requireTransport().requireConnection()

        let params = SessionCreateParams(
            workingDirectory: workingDirectory,
            model: model,
            contextFiles: nil,
            title: title,
            source: source
        )

        let result: SessionCreateResult = try await ws.send(
            method: "session.create",
            params: params
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
        let ws = try requireTransport().requireConnection()

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

        return result
    }

    func resume(sessionId: String) async throws {
        let ws = try requireTransport().requireConnection()

        let params = SessionResumeParams(sessionId: sessionId)
        let result: SessionResumeResult = try await ws.send(
            method: "session.resume",
            params: params
        )

        currentTransport?.setCurrentSessionId(result.sessionId)
        currentTransport?.setCurrentModel(result.model)
        logger.info("Resumed session: \(sessionId) with \(result.messageCount) messages", category: .session)
    }

    func archive(_ sessionId: String) async throws {
        let ws = try requireTransport().requireConnection()

        let params = SessionArchiveParams(sessionId: sessionId)
        let _: EmptyParams = try await ws.send(method: "session.archive", params: params)

        if currentTransport?.currentSessionId == sessionId {
            currentTransport?.setCurrentSessionId(nil)
        }
        logger.info("Archived session: \(sessionId)", category: .session)
    }

    func unarchive(_ sessionId: String) async throws {
        let ws = try requireTransport().requireConnection()

        let params = SessionUnarchiveParams(sessionId: sessionId)
        let _: EmptyParams = try await ws.send(method: "session.unarchive", params: params)

        logger.info("Unarchived session: \(sessionId)", category: .session)
    }

    func getHistory(limit: Int = 100) async throws -> [HistoryMessage] {
        let (ws, sessionId) = try requireTransport().requireSession()

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
        let ws = try requireTransport().requireConnection()

        let params = SessionReconstructParams(
            sessionId: sessionId,
            limit: limit,
            beforeSequence: beforeSequence
        )

        let result: SessionReconstructResult = try await ws.send(
            method: "session.reconstruct",
            params: params
        )

        logger.info("Reconstructed session \(sessionId): \(result.events.count) events, isRunning=\(result.isRunning), lastSeq=\(result.lastSequence)", category: .session)
        return result
    }

    // MARK: - Fork

    func fork(_ sessionId: String, fromEventId: String? = nil) async throws -> SessionForkResult {
        let ws = try requireTransport().requireConnection()

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
