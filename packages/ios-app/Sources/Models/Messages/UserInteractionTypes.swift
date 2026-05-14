import Foundation

// MARK: - UserInteraction Types

/// A single option in a question
struct UserInteractionOption: Codable, Identifiable, Equatable {
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
struct UserInteraction: Codable, Identifiable, Equatable {
    /// Unique identifier for this question
    let id: String
    /// The question text
    let question: String
    /// Available options to choose from
    let options: [UserInteractionOption]
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

/// Parameters for the UserInteraction capability invocation
struct UserInteractionParams: Codable, Equatable {
    /// Array of questions (1-5)
    let questions: [UserInteraction]
    /// Optional context to provide alongside the questions
    let context: String?
}

/// A user's answer to a single question
struct UserInteractionAnswer: Codable, Equatable {
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

/// The complete result from the UserInteraction capability
struct UserInteractionResult: Codable, Equatable {
    /// All answers provided by the user
    let answers: [UserInteractionAnswer]
    /// Whether all questions were answered
    let complete: Bool
    /// ISO 8601 timestamp of when the result was submitted
    let submittedAt: String
}

/// Status for UserInteraction in async mode
/// In async mode, the capability returns immediately and user answers as a new prompt
enum UserInteractionStatus: Equatable {
    /// Capability arguments still streaming — chip shows spinner
    case generating
    /// Awaiting user response - the question chip is answerable
    case pending
    /// User submitted answers - chip shows completion
    case answered
    /// User sent a different message - chip is disabled (skipped)
    case superseded
}

/// Capability data for UserInteraction tracking (in-chat state)
struct UserInteractionInvocationData: Equatable {
    /// The capability invocation ID from the agent
    let invocationId: String
    /// Durable server pause id that must be submitted back to resolve exactly once
    var pauseId: String? = nil
    /// The question parameters (mutable: set to placeholder during .generating, updated on capability.invocation.started)
    var params: UserInteractionParams
    /// Current answers keyed by question ID
    var answers: [String: UserInteractionAnswer]
    /// Status in async mode (pending/answered/superseded)
    var status: UserInteractionStatus
    /// Final result (set when submitted)
    var result: UserInteractionResult?

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
