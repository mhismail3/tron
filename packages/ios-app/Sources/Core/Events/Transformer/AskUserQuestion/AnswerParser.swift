import Foundation

/// Parser for extracting answers from AskUserQuestion answer messages.
///
/// The answer format from the agent is:
/// ```
/// [Answers to your questions]
///
/// **Question text?**
/// Answer: SelectedValue1, SelectedValue2
///
/// **Question text 2?**
/// Answer: [Other] custom input
/// ```
enum AnswerParser {

    /// Parse answers from the formatted answer message content.
    ///
    /// - Parameters:
    ///   - content: The full message content containing answers
    ///   - params: The original question parameters for matching
    /// - Returns: Dictionary mapping question IDs to their answers
    static func parseAnswers(
        from content: String,
        params: AskUserQuestionParams
    ) -> [String: AskUserQuestionAnswer] {
        var answers: [String: AskUserQuestionAnswer] = [:]

        // Split by question markers (lines starting with **)
        let lines = content.components(separatedBy: "\n")
        var currentQuestionText: String?
        var currentAnswerLine: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Check for question line: **Question text?**
            if trimmed.hasPrefix("**") && trimmed.hasSuffix("**") {
                // Save previous question/answer pair if exists
                if let questionText = currentQuestionText, let answerLine = currentAnswerLine {
                    if let answer = parseAnswer(questionText: questionText, answerLine: answerLine, params: params) {
                        answers[answer.questionId] = answer
                    }
                }

                // Extract new question text (remove ** markers)
                currentQuestionText = String(trimmed.dropFirst(2).dropLast(2))
                currentAnswerLine = nil
            }
            // Check for answer line: Answer: ...
            else if trimmed.hasPrefix("Answer:") {
                currentAnswerLine = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
        }

        // Don't forget the last question/answer pair
        if let questionText = currentQuestionText, let answerLine = currentAnswerLine {
            if let answer = parseAnswer(questionText: questionText, answerLine: answerLine, params: params) {
                answers[answer.questionId] = answer
            }
        }

        return answers
    }

    /// Parse a single answer line and match it to a question from params.
    ///
    /// - Parameters:
    ///   - questionText: The question text extracted from the message
    ///   - answerLine: The answer text after "Answer:"
    ///   - params: The original question parameters for matching
    /// - Returns: The parsed answer, or nil if question not found
    static func parseAnswer(
        questionText: String,
        answerLine: String,
        params: AskUserQuestionParams
    ) -> AskUserQuestionAnswer? {
        // Find the matching question by text
        guard let question = params.questions.first(where: { $0.question == questionText }) else {
            TronLogger.shared.verbose("Could not find question matching: \(questionText)", category: .events)
            return nil
        }

        // Check for [Other] prefix
        if answerLine.hasPrefix("[Other]") {
            let otherValue = String(answerLine.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            return AskUserQuestionAnswer(
                questionId: question.id,
                selectedValues: [],
                otherValue: otherValue.isEmpty ? nil : otherValue
            )
        }

        // Check for "(no selection)"
        if answerLine == "(no selection)" {
            return AskUserQuestionAnswer(
                questionId: question.id,
                selectedValues: [],
                otherValue: nil
            )
        }

        // Parse comma-separated values
        let selectedValues = answerLine.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }
        return AskUserQuestionAnswer(
            questionId: question.id,
            selectedValues: selectedValues,
            otherValue: nil
        )
    }
}
