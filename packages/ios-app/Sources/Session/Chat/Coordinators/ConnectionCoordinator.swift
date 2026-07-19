import Foundation

/// Protocol defining the context required by ConnectionCoordinator.
///
/// This protocol allows ConnectionCoordinator to be tested independently from ChatViewModel
/// by defining the minimum interface it needs to interact with connection and session state.
@MainActor
protocol ConnectionContext: ChatCoordinatorContext, LocalChatNotificationPresenting {
    var sessionId: String { get }

    /// Whether the view should dismiss (e.g., session not found)
    var shouldDismiss: Bool { get set }

    /// Whether currently connected to server
    var isConnected: Bool { get }

    /// Whether reconstruction is in progress (suppresses real-time events)
    var isReconstructing: Bool { get set }

    /// Highest processed event sequence (for WebSocket dedup)
    var sequenceHighWaterMark: Int64 { get set }

    /// Event count to request for this reconstruction pass.
    var reconstructionEventLimit: Int { get }

    /// Connect to the server
    func connect() async

    /// Resume a session on the server
    func resumeSession(sessionId: String) async throws

    /// Reconstruct full session state from the server
    func reconstructSession(sessionId: String, limit: Int?, beforeEventId: String?) async throws -> SessionReconstructResult

    /// Process the reconstruction result (events → messages, in-flight → streaming)
    func processReconstructionResult(_ result: SessionReconstructResult) async

    /// Clean up stale streaming state before reconstruction
    func cleanUpStreamingState()

    /// Drain events that were buffered during a successfully committed reconstruction
    func drainEventBuffer()

    func setSessionProcessing(_ isProcessing: Bool)
}

/// Terminal state for one connection/reconstruction attempt.
///
/// A retryable or cancelled attempt deliberately leaves reconstruction mode
/// active and retains its buffered live suffix. Only a committed server
/// snapshot may release that suffix for sequence-filtered dispatch.
enum ConnectionReconstructionOutcome: Equatable {
    case completed
    case retryableFailure
    case terminalFailure
    case cancelled
}

/// Coordinates session connection, reconnection, and state reconstruction for ChatViewModel.
///
/// Responsibilities:
/// - Connecting to server and resuming sessions
/// - Reconnecting after app returns to foreground
/// - Reconstructing session state via single `session::reconstruct` engine invocation
/// - Setting sequence high-water mark for deterministic event dedup
///
/// This coordinator extracts connection logic from ChatViewModel+Connection.swift,
/// making it independently testable while maintaining the same behavior.
@MainActor
final class ConnectionCoordinator {

    // MARK: - Initialization

    init() {}

    // MARK: - Connect and Reconstruct

    /// Connect, resume, and reconstruct the session.
    ///
    /// Single flow for both initial connect and reconnection. The server's
    /// `session::reconstruct` response provides everything: persisted events,
    /// in-flight state, and session metadata.
    func connectAndReconstruct(context: ConnectionContext) async -> ConnectionReconstructionOutcome {
        context.logInfo("connectAndReconstruct() called for session \(context.sessionId)")

        // Suppress events BEFORE connecting. Events that arrive during reconstruction
        // are buffered and filtered by sequence after the high-water mark is set.
        context.isReconstructing = true

        // Connect to server
        await context.connect()
        guard !Task.isCancelled else {
            context.logInfo("[RECONSTRUCT] Cancelled during connect; retaining buffered events")
            return .cancelled
        }

        if !context.isConnected {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !Task.isCancelled else {
            context.logInfo("[RECONSTRUCT] Cancelled during connect grace period; retaining buffered events")
            return .cancelled
        }

        guard context.isConnected else {
            context.logWarning("Failed to connect to server - isConnected=false")
            return .retryableFailure
        }
        context.logInfo("Connected to server successfully")

        // Resume the session (binds session to this WebSocket connection)
        do {
            try await context.resumeSession(sessionId: context.sessionId)
            guard !Task.isCancelled else {
                context.logInfo("[RECONSTRUCT] Cancelled during resume; retaining buffered events")
                return .cancelled
            }
            context.logInfo("Session resumed successfully")
        } catch {
            guard !Task.isCancelled else {
                context.logInfo("[RECONSTRUCT] Resume cancelled; retaining buffered events")
                return .cancelled
            }
            context.logError("Failed to resume session: \(error.localizedDescription)")
            return handleSessionResumeFailure(error, context: context)
                ? .terminalFailure
                : .retryableFailure
        }

        // Reconstruct session state from server (single engine invocation)
        do {
            let result = try await context.reconstructSession(
                sessionId: context.sessionId,
                limit: context.reconstructionEventLimit,
                beforeEventId: nil
            )
            guard !Task.isCancelled else {
                context.logInfo("[RECONSTRUCT] Cancelled after snapshot fetch; retaining buffered events")
                return .cancelled
            }

            // Commit the authoritative sequence cut before any projection work
            // that can suspend. If that work is cancelled, the replacement
            // reconstruction retains the buffer and starts from a safe cut.
            context.sequenceHighWaterMark = max(context.sequenceHighWaterMark, result.lastSequence)

            // Clean up stale streaming state from previous connection
            context.cleanUpStreamingState()

            // Process the reconstruction result
            await context.processReconstructionResult(result)
            guard !Task.isCancelled else {
                context.logInfo("[RECONSTRUCT] Cancelled during projection; retaining buffered events")
                return .cancelled
            }

            // The reconstruction projection owns the detailed agent phase,
            // including preservation of a pending local Stop. The session list
            // keeps only the server's coarse running bit.
            context.setSessionProcessing(result.isRunning)

            context.logInfo("[RECONSTRUCT] Complete: \(result.events.count) events, isRunning=\(result.isRunning), lastSeq=\(result.lastSequence), highWaterMark=\(context.sequenceHighWaterMark)")
            context.isReconstructing = false
            context.logInfo("[RECONSTRUCT] Snapshot committed; draining buffered live suffix")
            context.drainEventBuffer()
            return .completed
        } catch {
            guard !Task.isCancelled else {
                context.logInfo("[RECONSTRUCT] Fetch cancelled; retaining buffered events")
                return .cancelled
            }
            context.logWarning("[RECONSTRUCT] Failed: \(error.localizedDescription)")
            context.appendLocalError(
                dedupKey: "session.reconstruct.failed",
                title: "Could not load chat",
                message: "Session history could not be loaded: \(error.localizedDescription)",
                suggestion: "Check the connection. Tron will retry while the server remains reachable."
            )
            return .retryableFailure
        }
    }

    // MARK: - Session Resume Error Handling

    /// Handles session resume failures for the shared connection/reconstruction path.
    /// Detects session-not-found errors and sets shouldDismiss to navigate away.
    private func handleSessionResumeFailure(_ error: Error, context: ConnectionContext) -> Bool {
        let isNotFound: Bool
        if let rpcError = error as? EngineProtocolError {
            isNotFound = rpcError.errorCode == .sessionNotFound
        } else {
            let errorString = error.localizedDescription.lowercased()
            isNotFound = errorString.contains("not found") || errorString.contains("does not exist")
        }
        if isNotFound {
            context.logWarning("Session \(context.sessionId) not found on server - dismissing view")
            context.shouldDismiss = true
            context.showError("Session not found on server")
        }
        return isNotFound
    }
}
