import Testing
@testable import TronMobile

@Suite("User input presentation")
struct UserInputPresentationTests {
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

    @Test("Answered requests carry their answer count and audit summary")
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
        #expect(UserInputPresentation.chatDetail(for: answered) == "First · Accuracy · Second")
    }

    @Test("Failed requests expose their durable reason")
    func failedCopy() {
        let failed = request(
            questions: [question(id: "format")],
            status: .failed("The request expired")
        )

        #expect(UserInputPresentation.sheetTitle(for: failed) == "Unavailable")
        #expect(UserInputPresentation.chatTitle(for: failed) == "Question unavailable")
        #expect(UserInputPresentation.chatDetail(for: failed) == "The request expired")
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
