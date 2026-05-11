import Foundation

/// Protocol defining the context required by ConnectionCoordinator.
///
/// This protocol allows ConnectionCoordinator to be tested independently from ChatViewModel
/// by defining the minimum interface it needs to interact with connection and session state.
///
/// Inherits from:
/// - LoggingContext: Logging and error display (showError)
/// - SessionIdentifiable: Session ID access
/// - ProcessingTrackable: Processing state and dashboard updates
@MainActor
protocol ConnectionContext: LoggingContext, SessionIdentifiable, ProcessingTrackable {
    /// Whether the view should dismiss (e.g., session not found)
    var shouldDismiss: Bool { get set }

    /// Whether currently connected to server
    var isConnected: Bool { get }

    /// Whether reconstruction is in progress (suppresses real-time events)
    var isReconstructing: Bool { get set }

    /// Highest processed event sequence (for WebSocket dedup)
    var sequenceHighWaterMark: Int64 { get set }

    /// Connect to the server
    func connect() async

    /// Disconnect from the server
    func disconnect() async

    /// Resume a session on the server
    func resumeSession(sessionId: String) async throws

    /// Reconstruct full session state from the server
    func reconstructSession(sessionId: String, limit: Int?, beforeSequence: Int64?) async throws -> SessionReconstructResult

    /// Process the reconstruction result (events → messages, in-flight → streaming)
    func processReconstructionResult(_ result: SessionReconstructResult) async

    /// Clean up stale streaming state before reconstruction
    func cleanUpStreamingState()

    /// Drain events that were buffered during reconstruction
    func drainEventBuffer()
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
    func connectAndReconstruct(context: ConnectionContext) async {
        context.logInfo("connectAndReconstruct() called for session \(context.sessionId)")

        // Suppress events BEFORE connecting. Events that arrive during reconstruction
        // are buffered and filtered by sequence after the high-water mark is set.
        context.isReconstructing = true

        // Connect to server
        await context.connect()

        if !context.isConnected {
            try? await Task.sleep(for: .milliseconds(100))
        }

        guard context.isConnected else {
            context.logWarning("Failed to connect to server - isConnected=false")
            context.isReconstructing = false
            return
        }
        context.logInfo("Connected to server successfully")

        // Resume the session (binds session to this WebSocket connection)
        do {
            try await context.resumeSession(sessionId: context.sessionId)
            context.logInfo("Session resumed successfully")
        } catch {
            context.logError("Failed to resume session: \(error.localizedDescription)")
            handleSessionResumeFailure(error, context: context)
            context.isReconstructing = false
            return
        }

        // Reconstruct session state from server (single engine invocation)
        do {
            let result = try await context.reconstructSession(
                sessionId: context.sessionId,
                limit: 50,
                beforeSequence: nil
            )

            // Clean up stale streaming state from previous connection
            context.cleanUpStreamingState()

            // Process the reconstruction result
            await context.processReconstructionResult(result)

            // Set high-water mark from server's lastSequence
            context.sequenceHighWaterMark = result.lastSequence

            // Reconciliation is server-authoritative: a completed reconstruction
            // must clear local processing state just as firmly as a running one
            // starts it. Live streams carry only future events.
            context.isProcessing = result.isRunning
            context.setSessionProcessing(result.isRunning)

            context.logInfo("[RECONSTRUCT] Complete: \(result.events.count) events, isRunning=\(result.isRunning), lastSeq=\(result.lastSequence), highWaterMark=\(context.sequenceHighWaterMark)")
        } catch {
            context.logWarning("[RECONSTRUCT] Failed: \(error.localizedDescription)")
        }

        // Always reset reconstruction flag and drain buffered events
        context.isReconstructing = false
        context.logInfo("[RECONSTRUCT] Draining event buffer, isReconstructing=false")
        context.drainEventBuffer()
    }

    /// Reconnect to server and reconstruct session state.
    /// Same flow as initial connect — no separate reconnect path.
    func reconnectAndReconstruct(context: ConnectionContext) async {
        context.logInfo("reconnectAndReconstruct() - checking connection state")

        if !context.isConnected {
            context.logInfo("Not connected, reconnecting...")
        }

        // Reuse the same flow — session::reconstruct handles everything
        await connectAndReconstruct(context: context)
    }

    // MARK: - Session Resume Error Handling

    /// Shared error handler for session resume failures in both connect and reconnect paths.
    /// Detects session-not-found errors and sets shouldDismiss to navigate away.
    private func handleSessionResumeFailure(_ error: Error, context: ConnectionContext) {
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
    }

    // MARK: - Disconnect

    /// Disconnect from the server.
    func disconnect(context: ConnectionContext) async {
        await context.disconnect()
    }
}
