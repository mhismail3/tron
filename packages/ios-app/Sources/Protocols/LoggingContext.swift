import Foundation

// MARK: - Logging Context

/// Base protocol providing logging and error display capabilities for all context protocols.
/// Coordinators use these methods to log events and show errors without coupling to specific implementations.
@MainActor
protocol LoggingContext: AnyObject {
    func logVerbose(_ message: String)
    func logDebug(_ message: String)
    func logInfo(_ message: String)
    func logWarning(_ message: String)
    func logError(_ message: String)

    /// Show an error message to the user.
    /// Included in LoggingContext since error display is needed by most coordinators.
    func showError(_ message: String)
}

// MARK: - Base Coordinator Context Protocols
//
// These protocols eliminate duplicate method declarations across coordinator contexts.
// Each specific context (ConnectionContext, MessagingContext, etc.) composes these
// base protocols instead of redeclaring the same methods.
//
// Usage:
//   protocol ConnectionContext: LoggingContext, SessionIdentifiable, ProcessingTrackable { ... }
//   protocol MessagingContext: LoggingContext, SessionIdentifiable, ProcessingTrackable, StreamingManaging { ... }

// MARK: - Session Identity

/// Protocol for contexts that have access to the current session.
@MainActor
protocol SessionIdentifiable: AnyObject {
    /// Current session ID.
    var sessionId: String { get }
}

// MARK: - Agent Phase

/// Lifecycle phases of the agent during a turn.
///
/// Valid transitions:
/// ```
/// idle → processing          (turn start / send message)
/// processing → postProcessing (agent.complete)
/// postProcessing → idle       (agent.ready)
/// any → idle                  (agent.error / disconnect)
/// ```
///
/// `isCompacting` is orthogonal and tracked separately.
enum AgentPhase: Equatable, Sendable {
    case idle
    case processing
    case postProcessing

    var isIdle: Bool { self == .idle }
    var isProcessing: Bool { self == .processing }
    var isPostProcessing: Bool { self == .postProcessing }
}

// MARK: - Processing State

/// Protocol for contexts that track agent processing state.
@MainActor
protocol ProcessingTrackable: AnyObject {
    /// The current agent lifecycle phase.
    var agentPhase: AgentPhase { get set }

    /// Update the session's processing state in the dashboard/database.
    func setSessionProcessing(_ isProcessing: Bool)
}

extension ProcessingTrackable {
    /// Whether the agent is currently processing (convenience).
    var isProcessing: Bool {
        get { agentPhase == .processing }
        set { agentPhase = newValue ? .processing : .idle }
    }

    /// Whether background hooks are running after completion (convenience).
    var isPostProcessing: Bool {
        get { agentPhase == .postProcessing }
        set { agentPhase = newValue ? .postProcessing : .idle }
    }
}

// MARK: - Streaming Management

/// Protocol for contexts that manage streaming state.
@MainActor
protocol StreamingManaging: AnyObject {
    /// Flush any pending text updates before state changes.
    func flushPendingTextUpdates()

    /// Finalize the current streaming message.
    func finalizeStreamingMessage()

    /// Reset the streaming manager state.
    func resetStreamingManager()
}

// MARK: - Tool State Tracking

/// Protocol for contexts that track tool call state during a turn.
@MainActor
protocol ToolStateTracking: AnyObject {
    /// Map of current tool messages by message ID.
    var currentToolMessages: [UUID: ChatMessage] { get set }

    /// Tool calls tracked for the current turn.
    var currentTurnToolCalls: [ToolCallRecord] { get set }

    /// Whether AskUserQuestion was called in the current turn.
    var askUserQuestionCalledInTurn: Bool { get set }

    /// Current browser status.
    var browserStatus: BrowserGetStatusResult? { get set }
}

// MARK: - Browser Management

/// Protocol for contexts that can manage browser sessions.
@MainActor
protocol BrowserManaging: AnyObject {
    /// Close the browser session.
    func closeBrowserSession()
}

// MARK: - Dashboard Updates

/// Protocol for contexts that can update session dashboard info.
@MainActor
protocol DashboardUpdating: AnyObject {
    /// Update session dashboard info in the database.
    func updateSessionDashboardInfo(lastUserPrompt: String?, lastAssistantResponse: String?)
}
