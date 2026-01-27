import Foundation

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
