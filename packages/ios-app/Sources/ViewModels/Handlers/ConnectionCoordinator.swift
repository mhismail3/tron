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

    /// Connect to the server
    func connect() async

    /// Disconnect from the server
    func disconnect() async

    /// Resume a session on the server
    func resumeSession(sessionId: String) async throws

    /// Get agent state from the server
    func getAgentState(sessionId: String) async throws -> AgentStateResult

    /// List todos for a session
    func listTodos(sessionId: String) async throws -> TodoListResult

    /// Update todos in the todo state
    func updateTodos(_ todos: [RpcTodoItem], summary: String?)

    /// Append a "catching up" message and return its ID
    func appendCatchingUpMessage() -> UUID

    /// Process catch-up content from resumed session
    func processCatchUpContent(accumulatedText: String, toolCalls: [CurrentTurnToolCall]) async

    /// Remove the catching-up notification message after processing is complete
    func removeCatchingUpMessage()
}

/// Coordinates session connection, reconnection, and catch-up for ChatViewModel.
///
/// Responsibilities:
/// - Connecting to server and resuming sessions
/// - Reconnecting after app returns to foreground
/// - Checking agent state and setting up streaming for in-progress sessions
/// - Fetching todos on resume
/// - Converting history messages to chat messages
///
/// This coordinator extracts connection logic from ChatViewModel+Connection.swift,
/// making it independently testable while maintaining the same behavior.
@MainActor
final class ConnectionCoordinator {

    // MARK: - Initialization

    init() {}

    // MARK: - Connect and Resume

    /// Connect and resume the session.
    ///
    /// - Parameter context: The context providing access to state and dependencies
    func connectAndResume(context: ConnectionContext) async {
        context.logInfo("connectAndResume() called for session \(context.sessionId)")

        // Connect to server
        context.logDebug("Calling connect()...")
        await context.connect()

        // Only wait if not already connected (avoid unnecessary delay)
        if !context.isConnected {
            context.logVerbose("Waiting briefly for connection...")
            try? await Task.sleep(for: .milliseconds(100))
        }

        guard context.isConnected else {
            context.logWarning("Failed to connect to server - isConnected=false")
            return
        }
        context.logInfo("Connected to server successfully")

        // Resume the session
        do {
            context.logDebug("Calling resumeSession for \(context.sessionId)...")
            try await context.resumeSession(sessionId: context.sessionId)
            context.logInfo("Session resumed successfully")
        } catch {
            context.logError("Failed to resume session: \(error.localizedDescription)")

            // Check if session doesn't exist on server - signal to dismiss
            let errorString = error.localizedDescription.lowercased()
            if errorString.contains("not found") || errorString.contains("does not exist") {
                context.logWarning("Session \(context.sessionId) not found on server - dismissing view")
                context.shouldDismiss = true
                context.showError("Session not found on server")
            }
            // Don't show error alert for connection failures - the reconnection UI handles that
            return
        }

        // CRITICAL: Check if agent is currently running (handles resuming into in-progress session)
        // This must happen BEFORE loading messages so isProcessing flag is set correctly
        await checkAndResumeAgentState(context: context)

        // Fetch current todos for this session
        await fetchTodosOnResume(context: context)

        context.logDebug("Session resumed, using local EventDatabase for message history")
    }

    // MARK: - Reconnect and Resume

    /// Reconnect to server and resume streaming state after app returns to foreground.
    ///
    /// - Parameter context: The context providing access to state and dependencies
    func reconnectAndResume(context: ConnectionContext) async {
        context.logInfo("reconnectAndResume() - checking connection state")

        // Check if we're already connected
        if context.isConnected {
            context.logDebug("Already connected, checking agent state")
        } else {
            context.logInfo("Not connected, reconnecting...")
            await context.connect()

            // Wait briefly for connection
            if !context.isConnected {
                try? await Task.sleep(for: .milliseconds(100))
            }

            guard context.isConnected else {
                context.logWarning("Failed to reconnect")
                return
            }

            // Re-resume the session after reconnection
            do {
                try await context.resumeSession(sessionId: context.sessionId)
                context.logInfo("Session re-resumed after reconnection")
            } catch {
                context.logError("Failed to re-resume session: \(error)")
                return
            }
        }

        // Check if agent is running and catch up on any missed content
        await checkAndResumeAgentState(context: context)

        // Refresh todos in case they changed while disconnected
        await fetchTodosOnResume(context: context)
    }

    // MARK: - Fetch Todos

    /// Fetch current todos when resuming a session.
    ///
    /// - Parameter context: The context providing access to state and dependencies
    func fetchTodosOnResume(context: ConnectionContext) async {
        do {
            let result = try await context.listTodos(sessionId: context.sessionId)
            context.updateTodos(result.todos, summary: result.summary)
            context.logDebug("Fetched \(result.todos.count) todos on session resume")
        } catch {
            // Non-fatal - todos just won't show until next update
            context.logWarning("Failed to fetch todos on resume: \(error.localizedDescription)")
        }
    }

    // MARK: - Check Agent State

    /// Check agent state and set up streaming if agent is currently running.
    ///
    /// - Parameter context: The context providing access to state and dependencies
    func checkAndResumeAgentState(context: ConnectionContext) async {
        do {
            let agentState = try await context.getAgentState(sessionId: context.sessionId)
            if agentState.isRunning {
                context.logInfo("Agent is currently running - setting up streaming state for in-progress session")
                context.isProcessing = true

                // Add in-chat catching-up notification
                let _ = context.appendCatchingUpMessage()

                context.setSessionProcessing(true)

                // Use accumulated content from server if available (catch-up content)
                let accumulatedText = agentState.currentTurnText ?? ""
                let toolCalls = agentState.currentTurnToolCalls ?? []

                context.logInfo("Resume catch-up: \(accumulatedText.count) chars text, \(toolCalls.count) tool calls")

                // Process catch-up content
                await context.processCatchUpContent(accumulatedText: accumulatedText, toolCalls: toolCalls)

                // Remove the catching-up notification now that content has been processed.
                // This provides immediate feedback that catch-up is complete, rather than
                // waiting for the next turn_end which may not come for a while.
                context.removeCatchingUpMessage()

                context.logInfo("Processed catch-up content for in-progress turn")
            } else {
                context.logDebug("Agent is not running - normal session resume")
            }
        } catch {
            context.logWarning("Failed to check agent state: \(error.localizedDescription)")
        }
    }

    // MARK: - Disconnect

    /// Disconnect from the server.
    ///
    /// - Parameter context: The context providing access to state and dependencies
    func disconnect(context: ConnectionContext) async {
        await context.disconnect()
    }

    // MARK: - History Conversion

    /// Convert a history message to a chat message.
    ///
    /// - Parameter history: The history message to convert
    /// - Returns: A ChatMessage with the appropriate role and content
    func historyToMessage(_ history: HistoryMessage) -> ChatMessage {
        let role: MessageRole = switch history.role {
        case "user": .user
        case "assistant": .assistant
        case "system": .system
        default: .assistant
        }

        return ChatMessage(
            role: role,
            content: .text(history.content)
        )
    }
}
