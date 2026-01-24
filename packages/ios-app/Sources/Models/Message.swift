import Foundation

// MARK: - Model Name Formatting

/// Central mapping of model IDs to human-readable display names
private let modelDisplayNames: [String: String] = [
    // Claude 4.5 family
    "claude-opus-4-5-20251101": "Opus 4.5",
    "claude-sonnet-4-5-20250929": "Sonnet 4.5",
    "claude-haiku-4-5-20251001": "Haiku 4.5",

    // Claude 4.1 family
    "claude-opus-4-1-20250805": "Opus 4.1",

    // Claude 4 family
    "claude-opus-4-20250514": "Opus 4",
    "claude-sonnet-4-20250514": "Sonnet 4",

    // Claude 3.7 family
    "claude-3-7-sonnet-20250219": "Sonnet 3.7",

    // Claude 3.5 family
    "claude-3-5-sonnet-20241022": "Sonnet 3.5",
    "claude-3-5-sonnet-20240620": "Sonnet 3.5",
    "claude-3-5-haiku-20241022": "Haiku 3.5",

    // Claude 3 family
    "claude-3-opus-20240229": "Opus 3",
    "claude-3-sonnet-20240229": "Sonnet 3",
    "claude-3-haiku-20240307": "Haiku 3",
]

/// Formats a model ID into a friendly display name using the central mapping
func formatModelDisplayName(_ modelId: String) -> String {
    // Direct lookup first
    if let displayName = modelDisplayNames[modelId] {
        return displayName
    }

    // Use ModelNameFormatter for all other models (Gemini, Codex, etc.)
    return modelId.shortModelName
}

// MARK: - Chat Message Model

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: MessageRole
    var content: MessageContent
    let timestamp: Date
    var isStreaming: Bool
    /// Version counter for streaming updates (triggers SwiftUI onChange reliably)
    var streamingVersion: Int = 0
    var tokenUsage: TokenUsage?
    /// Incremental token usage (delta from previous turn) for display purposes
    var incrementalTokens: TokenUsage?
    /// Files attached to this message (unified model - images, PDFs, documents)
    var attachments: [Attachment]?
    /// Skills referenced in this message (rendered as chips above the message)
    var skills: [Skill]?
    /// Spells referenced in this message (ephemeral skills, rendered as pink chips)
    var spells: [Skill]?

    // MARK: - Enriched Metadata (Phase 1)
    // These fields come from server-side event store enhancements

    /// Model that generated this response (e.g., "claude-sonnet-4-20250514")
    var model: String?

    /// Response latency in milliseconds
    var latencyMs: Int?

    /// Turn number in the agent loop
    var turnNumber: Int?

    /// Whether extended thinking was used
    var hasThinking: Bool?

    /// Why the turn ended (end_turn, tool_use, max_tokens)
    var stopReason: String?

    /// Event ID from the server's event store (for deletion, forking, etc.)
    var eventId: String?

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: MessageContent,
        timestamp: Date = Date(),
        isStreaming: Bool = false,
        streamingVersion: Int = 0,
        tokenUsage: TokenUsage? = nil,
        incrementalTokens: TokenUsage? = nil,
        attachments: [Attachment]? = nil,
        skills: [Skill]? = nil,
        spells: [Skill]? = nil,
        model: String? = nil,
        latencyMs: Int? = nil,
        turnNumber: Int? = nil,
        hasThinking: Bool? = nil,
        stopReason: String? = nil,
        eventId: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.streamingVersion = streamingVersion
        self.tokenUsage = tokenUsage
        self.incrementalTokens = incrementalTokens
        self.attachments = attachments
        self.skills = skills
        self.spells = spells
        self.model = model
        self.latencyMs = latencyMs
        self.turnNumber = turnNumber
        self.hasThinking = hasThinking
        self.stopReason = stopReason
        self.eventId = eventId
    }

    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }

    // MARK: - Formatted Metadata Helpers

    /// Format latency as human-readable string (e.g., "2.3s" or "450ms")
    var formattedLatency: String? {
        guard let ms = latencyMs else { return nil }
        if ms < 1000 {
            return "\(ms)ms"
        } else {
            return String(format: "%.1fs", Double(ms) / 1000.0)
        }
    }

    /// Short model name (e.g., "claude-sonnet-4-20250514" -> "Sonnet 4")
    var shortModelName: String? {
        guard let model = model else { return nil }
        return model.shortModelName
    }

    /// Whether this message can be deleted.
    /// Only user and assistant messages with event IDs can be deleted.
    var canBeDeleted: Bool {
        // Must have an eventId (from server)
        guard eventId != nil else { return false }

        // Must be a user or assistant message (not system, toolResult, etc.)
        guard role == .user || role == .assistant else { return false }

        // Don't allow deleting streaming messages
        guard !isStreaming else { return false }

        return true
    }
}

// MARK: - Message Role

enum MessageRole: String, Codable, Equatable {
    case user
    case assistant
    case system
    case toolResult

    var displayName: String {
        switch self {
        case .user: return "You"
        case .assistant: return "Tron"
        case .system: return "System"
        case .toolResult: return "Tool"
        }
    }
}

// MARK: - System Event (Notifications)

/// System events are non-content notifications displayed in the chat
/// (model changes, context operations, status updates, etc.)
enum SystemEvent: Equatable {
    /// Model was switched during the session
    case modelChange(from: String, to: String)
    /// Reasoning level was changed
    case reasoningLevelChange(from: String, to: String)
    /// Session was interrupted
    case interrupted
    /// Voice transcription failed
    case transcriptionFailed
    /// No speech was detected in recording
    case transcriptionNoSpeech
    /// Context was compacted to save tokens
    case compaction(tokensBefore: Int, tokensAfter: Int, reason: String, summary: String?)
    /// Context was cleared
    case contextCleared(tokensBefore: Int, tokensAfter: Int)
    /// A message was deleted from context
    case messageDeleted(targetType: String)
    /// A skill was removed from context
    case skillRemoved(skillName: String)
    /// Rules were loaded on session start
    case rulesLoaded(count: Int)
    /// Plan mode was entered (read-only enforcement)
    case planModeEntered(skillName: String, blockedTools: [String])
    /// Plan mode was exited
    case planModeExited(reason: String, planPath: String?)
    /// Catching up to in-progress session
    case catchingUp

    /// Human-readable description for the event
    var textContent: String {
        switch self {
        case .modelChange(let from, let to):
            return "Switched from \(from) to \(to)"
        case .reasoningLevelChange(let from, let to):
            return "Reasoning: \(from) → \(to)"
        case .interrupted:
            return "Session interrupted"
        case .transcriptionFailed:
            return "Transcription failed"
        case .transcriptionNoSpeech:
            return "No speech detected"
        case .compaction(let before, let after, _, _):
            let saved = before - after
            return "Context compacted: \(formatTokens(saved)) tokens saved"
        case .contextCleared(let before, let after):
            let freed = before - after
            return "Context cleared: \(formatTokens(freed)) tokens freed"
        case .messageDeleted(let targetType):
            let typeLabel = targetType == "message.user" ? "user message" :
                           targetType == "message.assistant" ? "assistant message" :
                           targetType == "tool.result" ? "tool result" : "message"
            return "Deleted \(typeLabel) from context"
        case .skillRemoved(let skillName):
            return "\(skillName) removed from context"
        case .rulesLoaded(let count):
            return "Loaded \(count) \(count == 1 ? "rule" : "rules")"
        case .planModeEntered(let skillName, _):
            return "Plan mode active (\(skillName))"
        case .planModeExited(let reason, _):
            return "Plan mode \(reason)"
        case .catchingUp:
            return "Loading latest messages..."
        }
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1000 {
            return String(format: "%.1fk", Double(tokens) / 1000.0)
        }
        return "\(tokens)"
    }
}

// MARK: - Message Content

enum MessageContent: Equatable {
    // Core content types
    case text(String)
    case streaming(String)
    case thinking(visible: String, isExpanded: Bool, isStreaming: Bool)
    case toolUse(ToolUseData)
    case toolResult(ToolResultData)
    case error(String)
    case images([ImageContent])
    case attachments([Attachment])

    // System events (notifications) - consolidated
    case systemEvent(SystemEvent)

    // Special tool invocations (rendered as interactive chips)
    case askUserQuestion(AskUserQuestionToolData)
    case answeredQuestions(questionCount: Int)
    case subagent(SubagentToolData)
    case renderAppUI(RenderAppUIChipData)

    // MARK: - Legacy Convenience Cases (forward to systemEvent)
    // These allow gradual migration - existing code using .modelChange etc. still works

    /// In-chat notification for model change
    static func modelChange(from: String, to: String) -> MessageContent {
        .systemEvent(.modelChange(from: from, to: to))
    }
    /// In-chat notification for reasoning level change
    static func reasoningLevelChange(from: String, to: String) -> MessageContent {
        .systemEvent(.reasoningLevelChange(from: from, to: to))
    }
    /// In-chat notification for interrupted session
    static var interrupted: MessageContent {
        .systemEvent(.interrupted)
    }
    /// In-chat notification for transcription failure
    static var transcriptionFailed: MessageContent {
        .systemEvent(.transcriptionFailed)
    }
    /// In-chat notification for no speech detected
    static var transcriptionNoSpeech: MessageContent {
        .systemEvent(.transcriptionNoSpeech)
    }
    /// In-chat notification for context compaction
    static func compaction(tokensBefore: Int, tokensAfter: Int, reason: String, summary: String?) -> MessageContent {
        .systemEvent(.compaction(tokensBefore: tokensBefore, tokensAfter: tokensAfter, reason: reason, summary: summary))
    }
    /// In-chat notification for context clearing
    static func contextCleared(tokensBefore: Int, tokensAfter: Int) -> MessageContent {
        .systemEvent(.contextCleared(tokensBefore: tokensBefore, tokensAfter: tokensAfter))
    }
    /// In-chat notification for message deletion from context
    static func messageDeleted(targetType: String) -> MessageContent {
        .systemEvent(.messageDeleted(targetType: targetType))
    }
    /// In-chat notification for skill removal from context
    static func skillRemoved(skillName: String) -> MessageContent {
        .systemEvent(.skillRemoved(skillName: skillName))
    }
    /// In-chat notification for rules loaded on session start
    static func rulesLoaded(count: Int) -> MessageContent {
        .systemEvent(.rulesLoaded(count: count))
    }
    /// In-chat notification for plan mode entered
    static func planModeEntered(skillName: String, blockedTools: [String]) -> MessageContent {
        .systemEvent(.planModeEntered(skillName: skillName, blockedTools: blockedTools))
    }
    /// In-chat notification for plan mode exited
    static func planModeExited(reason: String, planPath: String?) -> MessageContent {
        .systemEvent(.planModeExited(reason: reason, planPath: planPath))
    }
    /// In-chat notification for catching up to in-progress session
    static var catchingUp: MessageContent {
        .systemEvent(.catchingUp)
    }

    var textContent: String {
        switch self {
        case .text(let text), .streaming(let text):
            return text
        case .thinking(let visible, _, _):
            return visible
        case .toolUse(let tool):
            return "[\(tool.toolName)]"
        case .toolResult(let result):
            return result.content
        case .error(let message):
            return message
        case .images:
            return "[Images]"
        case .attachments(let files):
            let count = files.count
            return "[\(count) \(count == 1 ? "attachment" : "attachments")]"
        case .systemEvent(let event):
            return event.textContent
        case .askUserQuestion(let data):
            return "[\(data.params.questions.count) questions]"
        case .answeredQuestions(let count):
            return "Answered \(count) \(count == 1 ? "question" : "questions")"
        case .subagent(let data):
            switch data.status {
            case .spawning:
                return "Spawning subagent..."
            case .running:
                return "Subagent running (turn \(data.currentTurn))"
            case .completed:
                return data.resultSummary ?? "Subagent completed"
            case .failed:
                return data.error ?? "Subagent failed"
            }
        case .renderAppUI(let data):
            switch data.status {
            case .rendering:
                return "Rendering \(data.displayTitle)..."
            case .complete:
                return "\(data.displayTitle) rendered"
            case .error:
                return data.errorMessage ?? "Error generating"
            }
        }
    }

    var isToolRelated: Bool {
        switch self {
        case .toolUse, .toolResult:
            return true
        default:
            return false
        }
    }

    var isNotification: Bool {
        if case .systemEvent = self {
            return true
        }
        return false
    }

    var isAskUserQuestion: Bool {
        if case .askUserQuestion = self {
            return true
        }
        return false
    }

    /// Extract SystemEvent if this is a system notification
    var asSystemEvent: SystemEvent? {
        if case .systemEvent(let event) = self {
            return event
        }
        return nil
    }
}

// MARK: - Tool Use Data

struct ToolUseData: Equatable {
    let toolName: String
    let toolCallId: String
    let arguments: String
    var status: ToolStatus
    var result: String?
    var durationMs: Int?

    var displayName: String {
        switch toolName.lowercased() {
        case "read": return "Reading file"
        case "write": return "Writing file"
        case "edit": return "Editing file"
        case "bash": return "Running command"
        case "glob": return "Searching files"
        case "grep": return "Searching content"
        case "task": return "Spawning agent"
        case "webfetch": return "Fetching URL"
        case "websearch": return "Searching web"
        default: return toolName
        }
    }

    var truncatedArguments: String {
        if arguments.count > 200 {
            return String(arguments.prefix(200)) + "..."
        }
        return arguments
    }

    var formattedDuration: String? {
        guard let ms = durationMs else { return nil }
        if ms < 1000 {
            return "\(ms)ms"
        } else {
            return String(format: "%.1fs", Double(ms) / 1000.0)
        }
    }
}

// MARK: - Tool Status

enum ToolStatus: Equatable {
    case running
    case success
    case error

    var iconName: String {
        switch self {
        case .running: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        }
    }
}

// MARK: - Tool Result Data

struct ToolResultData: Equatable {
    let toolCallId: String
    let content: String
    let isError: Bool
    let toolName: String?
    let arguments: String?
    let durationMs: Int?

    init(toolCallId: String, content: String, isError: Bool, toolName: String? = nil, arguments: String? = nil, durationMs: Int? = nil) {
        self.toolCallId = toolCallId
        self.content = content
        self.isError = isError
        self.toolName = toolName
        self.arguments = arguments
        self.durationMs = durationMs
    }

    var truncatedContent: String {
        if content.count > 500 {
            return String(content.prefix(500)) + "..."
        }
        return content
    }
}

// MARK: - Image Content

struct ImageContent: Equatable, Identifiable {
    let id: UUID
    let data: Data
    let mimeType: String

    init(data: Data, mimeType: String = "image/jpeg") {
        self.id = UUID()
        self.data = data
        self.mimeType = mimeType
    }
}

// MARK: - Message Extensions

extension ChatMessage {
    /// Create a user message with optional attachments, skills, and spells
    static func user(_ text: String, attachments: [Attachment]? = nil, skills: [Skill]? = nil, spells: [Skill]? = nil) -> ChatMessage {
        ChatMessage(role: .user, content: .text(text), attachments: attachments, skills: skills, spells: spells)
    }

    static func assistant(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: .text(text))
    }

    static func streaming(_ text: String = "") -> ChatMessage {
        ChatMessage(role: .assistant, content: .streaming(text), isStreaming: true)
    }

    static func system(_ text: String) -> ChatMessage {
        ChatMessage(role: .system, content: .text(text))
    }

    static func error(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: .error(text))
    }

    /// In-chat notification for model changes
    static func modelChange(from: String, to: String) -> ChatMessage {
        ChatMessage(role: .system, content: .modelChange(from: from, to: to))
    }

    /// In-chat notification for reasoning level changes
    static func reasoningLevelChange(from: String, to: String) -> ChatMessage {
        ChatMessage(role: .system, content: .reasoningLevelChange(from: from, to: to))
    }

    /// In-chat notification for session interruption
    static func interrupted() -> ChatMessage {
        ChatMessage(role: .system, content: .interrupted)
    }

    /// In-chat notification for transcription failure
    static func transcriptionFailed() -> ChatMessage {
        ChatMessage(role: .system, content: .transcriptionFailed)
    }

    /// In-chat notification for no speech detected
    static func transcriptionNoSpeech() -> ChatMessage {
        ChatMessage(role: .system, content: .transcriptionNoSpeech)
    }

    /// In-chat notification for context compaction
    static func compaction(tokensBefore: Int, tokensAfter: Int, reason: String, summary: String? = nil) -> ChatMessage {
        ChatMessage(role: .system, content: .compaction(tokensBefore: tokensBefore, tokensAfter: tokensAfter, reason: reason, summary: summary))
    }

    /// In-chat notification for context clearing
    static func contextCleared(tokensBefore: Int, tokensAfter: Int) -> ChatMessage {
        ChatMessage(role: .system, content: .contextCleared(tokensBefore: tokensBefore, tokensAfter: tokensAfter))
    }

    /// In-chat notification for message deletion from context
    static func messageDeleted(targetType: String) -> ChatMessage {
        ChatMessage(role: .system, content: .messageDeleted(targetType: targetType))
    }

    /// In-chat notification for skill removal from context
    static func skillRemoved(skillName: String) -> ChatMessage {
        ChatMessage(role: .system, content: .skillRemoved(skillName: skillName))
    }

    /// In-chat notification for rules loaded on session start
    static func rulesLoaded(count: Int) -> ChatMessage {
        ChatMessage(role: .system, content: .rulesLoaded(count: count))
    }

    /// In-chat notification for plan mode entering
    static func planModeEntered(skillName: String, blockedTools: [String]) -> ChatMessage {
        ChatMessage(role: .system, content: .planModeEntered(skillName: skillName, blockedTools: blockedTools))
    }

    /// In-chat notification for plan mode exiting
    static func planModeExited(reason: String, planPath: String?) -> ChatMessage {
        ChatMessage(role: .system, content: .planModeExited(reason: reason, planPath: planPath))
    }

    /// In-chat notification for catching up to in-progress session
    static func catchingUp() -> ChatMessage {
        ChatMessage(role: .system, content: .catchingUp)
    }

    /// Thinking block message (appears before the text response)
    static func thinking(_ text: String, isExpanded: Bool = false, isStreaming: Bool = false) -> ChatMessage {
        ChatMessage(role: .assistant, content: .thinking(visible: text, isExpanded: isExpanded, isStreaming: isStreaming))
    }
}

// MARK: - RenderAppUI Types

/// Status for a RenderAppUI canvas render
enum RenderAppUIStatus: String, Equatable {
    case rendering
    case complete
    case error
}

/// Data for tracking a RenderAppUI tool call (rendered as a chip in chat)
struct RenderAppUIChipData: Equatable {
    /// The tool call ID from RenderAppUI (var to allow updating placeholder → real ID)
    var toolCallId: String
    /// Canvas ID for the rendered UI
    let canvasId: String
    /// Title of the rendered app
    let title: String?
    /// Current status
    var status: RenderAppUIStatus
    /// Error message (when failed)
    var errorMessage: String?

    /// Display title (falls back to "App" if no title)
    var displayTitle: String {
        title ?? "App"
    }

    /// Whether this chip should be tappable (rendering and complete chips are tappable)
    /// Rendering: tap to watch generation in real time
    /// Complete: tap to view the rendered UI
    /// Error: not tappable (nothing to show)
    var isTappable: Bool {
        status == .rendering || status == .complete
    }
}

// MARK: - TodoWrite Types

/// Data for rendering a TodoWrite tool call as a compact chip
struct TodoWriteChipData: Equatable {
    /// The tool call ID from TodoWrite
    let toolCallId: String
    /// Count of new tasks (pending + in_progress)
    let newCount: Int
    /// Count of completed tasks
    let doneCount: Int
    /// Total count of tasks
    let totalCount: Int
}

// MARK: - NotifyApp Types

/// Status for a NotifyApp push notification
enum NotifyAppStatus: String, Equatable, Codable {
    case sending
    case sent
    case failed
}

/// Data for rendering a NotifyApp tool call as a compact chip
struct NotifyAppChipData: Equatable, Identifiable {
    /// The tool call ID from NotifyApp
    let toolCallId: String
    /// Notification title
    let title: String
    /// Notification body
    let body: String
    /// Markdown content for the detail sheet
    let sheetContent: String?
    /// Current status
    var status: NotifyAppStatus
    /// Number of devices notified successfully
    var successCount: Int?
    /// Number of devices that failed
    var failureCount: Int?
    /// Error message (when failed)
    var errorMessage: String?

    /// Identifiable conformance uses toolCallId
    var id: String { toolCallId }
}

// MARK: - Subagent Types

/// Status for a spawned subagent
enum SubagentStatus: String, Codable, Equatable {
    case spawning
    case running
    case completed
    case failed
}

/// Data for tracking a spawned subagent (rendered as a chip in chat)
struct SubagentToolData: Equatable {
    /// The tool call ID from SpawnSubagent
    let toolCallId: String
    /// Session ID of the spawned subagent
    let subagentSessionId: String
    /// The task assigned to the subagent
    let task: String
    /// Model used by the subagent
    let model: String?
    /// Current status
    var status: SubagentStatus
    /// Current turn number (while running)
    var currentTurn: Int
    /// Result summary (when completed)
    var resultSummary: String?
    /// Full output (when completed)
    var fullOutput: String?
    /// Duration in milliseconds
    var duration: Int?
    /// Error message (when failed)
    var error: String?
    /// Token usage (when completed)
    var tokenUsage: TokenUsage?

    /// Formatted duration for display
    var formattedDuration: String? {
        guard let ms = duration else { return nil }
        if ms < 1000 {
            return "\(ms)ms"
        } else {
            return String(format: "%.1fs", Double(ms) / 1000.0)
        }
    }

    /// Short task preview for chip display
    var taskPreview: String {
        if task.count > 40 {
            return String(task.prefix(40)) + "..."
        }
        return task
    }
}

// MARK: - AskUserQuestion Types

/// A single option in a question
struct AskUserQuestionOption: Codable, Identifiable, Equatable {
    /// Display label for the option
    let label: String
    /// Optional value (defaults to label if not provided)
    let value: String?
    /// Optional description providing more context
    let description: String?

    /// ID uses value if present, otherwise label
    var id: String { value ?? label }
}

/// A single question with options
struct AskUserQuestion: Codable, Identifiable, Equatable {
    /// Unique identifier for this question
    let id: String
    /// The question text
    let question: String
    /// Available options to choose from
    let options: [AskUserQuestionOption]
    /// Selection mode: single choice or multiple choice
    let mode: SelectionMode
    /// Whether to allow a free-form "Other" option
    let allowOther: Bool?
    /// Placeholder text for the "Other" input field
    let otherPlaceholder: String?

    /// Selection mode for a question
    enum SelectionMode: String, Codable, Equatable {
        case single
        case multi
    }
}

/// Parameters for the AskUserQuestion tool call
struct AskUserQuestionParams: Codable, Equatable {
    /// Array of questions (1-5)
    let questions: [AskUserQuestion]
    /// Optional context to provide alongside the questions
    let context: String?
}

/// A user's answer to a single question
struct AskUserQuestionAnswer: Codable, Equatable {
    /// ID of the question being answered
    let questionId: String
    /// Selected option values (labels or explicit values)
    var selectedValues: [String]
    /// Free-form response if allowOther was true
    var otherValue: String?

    init(questionId: String, selectedValues: [String], otherValue: String?) {
        self.questionId = questionId
        self.selectedValues = selectedValues
        self.otherValue = otherValue
    }
}

/// The complete result from the AskUserQuestion tool
struct AskUserQuestionResult: Codable, Equatable {
    /// All answers provided by the user
    let answers: [AskUserQuestionAnswer]
    /// Whether all questions were answered
    let complete: Bool
    /// ISO 8601 timestamp of when the result was submitted
    let submittedAt: String
}

/// Status for AskUserQuestion in async mode
/// In async mode, the tool returns immediately and user answers as a new prompt
enum AskUserQuestionStatus: Equatable {
    /// Awaiting user response - the question chip is answerable
    case pending
    /// User submitted answers - chip shows completion
    case answered
    /// User sent a different message - chip is disabled (skipped)
    case superseded
}

/// Tool data for AskUserQuestion tracking (in-chat state)
struct AskUserQuestionToolData: Equatable {
    /// The tool call ID from the agent
    let toolCallId: String
    /// The question parameters
    let params: AskUserQuestionParams
    /// Current answers keyed by question ID
    var answers: [String: AskUserQuestionAnswer]
    /// Status in async mode (pending/answered/superseded)
    var status: AskUserQuestionStatus
    /// Final result (set when submitted)
    var result: AskUserQuestionResult?

    /// Check if all questions have been answered
    var isComplete: Bool {
        params.questions.allSatisfy { question in
            if let answer = answers[question.id] {
                return !answer.selectedValues.isEmpty || (answer.otherValue?.isEmpty == false)
            }
            return false
        }
    }

    /// Number of questions answered
    var answeredCount: Int {
        params.questions.filter { question in
            if let answer = answers[question.id] {
                return !answer.selectedValues.isEmpty || (answer.otherValue?.isEmpty == false)
            }
            return false
        }.count
    }

    /// Total number of questions
    var totalCount: Int {
        params.questions.count
    }
}
