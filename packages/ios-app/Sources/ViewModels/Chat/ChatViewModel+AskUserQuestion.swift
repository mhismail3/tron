import Foundation

// MARK: - AskUserQuestion Methods

extension ChatViewModel {

    // MARK: - Sheet Management

    /// Open the AskUserQuestion sheet for a tool call
    func openAskUserQuestionSheet(for data: AskUserQuestionToolData) {
        // Allow opening for pending (to answer) or answered (to view)
        guard data.status == .pending || data.status == .answered else {
            logger.info("Not opening AskUserQuestion sheet - status is \(data.status)", category: .session)
            return
        }
        askUserQuestionState.currentData = data
        // Initialize answers from data (in case of re-opening or viewing answered)
        askUserQuestionState.answers = data.answers
        askUserQuestionState.showSheet = true
        let mode = data.status == .answered ? "read-only" : "interactive"
        logger.info("Opened AskUserQuestion sheet (\(mode)) for \(data.params.questions.count) questions", category: .session)
    }

    /// Dismiss AskUserQuestion sheet without submitting
    func dismissAskUserQuestionSheet() {
        askUserQuestionState.showSheet = false
        logger.info("AskUserQuestion sheet dismissed without submitting", category: .session)
    }

    // MARK: - Answer Submission

    /// Handle AskUserQuestion answers submission (async mode: sends as new prompt)
    func submitAskUserQuestionAnswers(_ answers: [AskUserQuestionAnswer]) async {
        guard let data = askUserQuestionState.currentData else {
            logger.error("Cannot submit answers - no current question data", category: .session)
            return
        }

        // Verify the question is still pending (not superseded)
        guard data.status == .pending else {
            logger.warning("Cannot submit answers - question status is \(data.status)", category: .session)
            showErrorAlert("This question is no longer active")
            askUserQuestionState.showSheet = false
            askUserQuestionState.currentData = nil
            askUserQuestionState.answers = [:]
            return
        }

        // Build the result
        let result = AskUserQuestionResult(
            answers: answers,
            complete: true,
            submittedAt: ISO8601DateFormatter().string(from: Date())
        )

        logger.info("Submitting AskUserQuestion answers as prompt for toolCallId=\(data.toolCallId)", category: .session)

        // Update the chip status to .answered BEFORE sending
        if let index = MessageFinder.lastIndexOfAskUserQuestion(toolCallId: data.toolCallId, in: messages) {
            if case .askUserQuestion(var toolData) = messages[index].content {
                toolData.status = .answered
                toolData.result = result
                // Convert array to dictionary
                var answersDict: [String: AskUserQuestionAnswer] = [:]
                for answer in answers {
                    answersDict[answer.questionId] = answer
                }
                toolData.answers = answersDict
                messages[index].content = .askUserQuestion(toolData)
            }
        }

        // Format answers as a user prompt and send
        let answerPrompt = formatAnswersAsPrompt(data: data, answers: answers)

        // Clear state before sending
        askUserQuestionState.showSheet = false
        askUserQuestionState.currentData = nil
        askUserQuestionState.answers = [:]

        // Send as a new prompt (this triggers a new agent turn)
        inputText = answerPrompt
        sendMessage()

        logger.info("AskUserQuestion answers submitted as prompt", category: .session)
    }

    /// Format answers into a user prompt for the agent
    private func formatAnswersAsPrompt(data: AskUserQuestionToolData, answers: [AskUserQuestionAnswer]) -> String {
        var lines: [String] = ["[Answers to your questions]", ""]

        for question in data.params.questions {
            guard let answer = answers.first(where: { $0.questionId == question.id }) else { continue }

            lines.append("**\(question.question)**")

            if let otherValue = answer.otherValue, !otherValue.isEmpty {
                lines.append("Answer: [Other] \(otherValue)")
            } else if !answer.selectedValues.isEmpty {
                let selected = answer.selectedValues.joined(separator: ", ")
                lines.append("Answer: \(selected)")
            } else {
                lines.append("Answer: (no selection)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Question State Management

    /// Mark all pending AskUserQuestion chips as superseded
    /// Called before sending a new user message (when user bypasses answering)
    func markPendingQuestionsAsSuperseded() {
        for i in messages.indices {
            if case .askUserQuestion(var data) = messages[i].content,
               data.status == .pending {
                data.status = .superseded
                messages[i].content = .askUserQuestion(data)
                logger.info("Marked AskUserQuestion \(data.toolCallId) as superseded", category: .session)
            }
        }
    }
}
