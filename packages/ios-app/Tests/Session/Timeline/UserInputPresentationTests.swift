import Testing
@testable import TronMobile

@Suite("User input presentation")
struct UserInputPresentationTests {
    @Test("A pending draft submits any valid answered subset in canonical question order")
    func partialDraftAnswersAreValid() {
        let questions = [question(id: "first"), question(id: "second")]
        var draft = UserInputDraft(request: request(
            questions: questions,
            answers: [],
            status: .pending
        ))
        draft.selectedLabels["second"] = "First"

        #expect(draft.answers(for: questions) == [
            UserInputAnswer(
                questionId: "second",
                selectedLabel: "First",
                freeText: nil
            ),
        ])
    }
    @Test("Pending questions use singular and plural request copy")
    func pendingCopy() {
        let single = request(questions: [question(id: "format")])
        let multiple = request(questions: [
            question(id: "format"),
            question(id: "priority"),
            question(id: "audience"),
        ])

        #expect(UserInputPresentation.sheetTitle(for: single) == "Question")
        #expect(UserInputPresentation.chatTitle(for: single) == "Question for you")
        #expect(UserInputPresentation.sheetTitle(for: multiple) == "Questions")
        #expect(UserInputPresentation.chatTitle(for: multiple) == "Questions for you")
    }

    @Test("Answered requests carry their answer count")
    func answeredCopy() {
        let questions = [question(id: "format"), question(id: "priority"), question(id: "audience")]
        let answers = [
            UserInputAnswer(questionId: "format", selectedLabel: "First", freeText: nil),
            UserInputAnswer(questionId: "priority", selectedLabel: nil, freeText: "Accuracy"),
            UserInputAnswer(questionId: "audience", selectedLabel: "Second", freeText: nil),
        ]
        let answered = request(questions: questions, answers: answers, status: .answered)

        #expect(UserInputPresentation.sheetTitle(for: answered) == "Answers")
        #expect(UserInputPresentation.chatTitle(for: answered) == "Answered 3 questions")

        let single = request(
            questions: [question(id: "format")],
            answers: [UserInputAnswer(questionId: "format", selectedLabel: "First", freeText: nil)],
            status: .answered
        )
        #expect(UserInputPresentation.chatTitle(for: single) == "Answered 1 question")
    }

    @Test("Manual taps open durable answers while automatic presentation stays pending and one-shot")
    func presentationPolicySeparatesAuditFromAutomaticInterruption() {
        let pending = request(questions: [question(id: "format")])
        let answered = request(
            questions: [question(id: "format")],
            answers: [UserInputAnswer(
                questionId: "format",
                selectedLabel: "First",
                freeText: nil
            )],
            status: .answered
        )
        let failed = request(
            questions: [question(id: "format")],
            status: .failed("The request expired")
        )

        #expect(UserInputPresentation.shouldPresentSheet(
            for: pending,
            automatically: false,
            hasBeenPresented: true
        ))
        #expect(UserInputPresentation.shouldPresentSheet(
            for: answered,
            automatically: false,
            hasBeenPresented: false
        ))
        #expect(UserInputPresentation.shouldPresentSheet(
            for: failed,
            automatically: false,
            hasBeenPresented: false
        ))
        #expect(UserInputPresentation.shouldPresentSheet(
            for: pending,
            automatically: true,
            hasBeenPresented: false
        ))
        #expect(!UserInputPresentation.shouldPresentSheet(
            for: pending,
            automatically: true,
            hasBeenPresented: true
        ))
        #expect(!UserInputPresentation.shouldPresentSheet(
            for: answered,
            automatically: true,
            hasBeenPresented: false
        ))
    }

    @Test("Failed requests use unavailable copy")
    func failedCopy() {
        let failed = request(
            questions: [question(id: "format")],
            status: .failed("The request expired")
        )

        #expect(UserInputPresentation.sheetTitle(for: failed) == "Unavailable")
        #expect(UserInputPresentation.chatTitle(for: failed) == "Question unavailable")
    }

    private func request(
        questions: [UserInputQuestion],
        answers: [UserInputAnswer] = [],
        status: UserInputRequestStatus = .pending
    ) -> UserInputRequest {
        UserInputRequest(
            invocationId: "request-1",
            questions: questions,
            answers: answers,
            status: status
        )
    }

    private func question(id: String) -> UserInputQuestion {
        UserInputQuestion(
            header: id,
            id: id,
            question: "Choose \(id)",
            options: [
                UserInputOption(label: "First", description: "The first option"),
                UserInputOption(label: "Second", description: "The second option"),
            ]
        )
    }
}
