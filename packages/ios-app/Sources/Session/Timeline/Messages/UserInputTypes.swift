import Foundation

enum UserInputRequestStatus: Equatable, Sendable {
    case pending
    case answered
    case failed(String)
}

struct UserInputOption: Codable, Equatable, Identifiable, Sendable {
    let label: String
    let description: String

    var id: String { label }
}

struct UserInputQuestion: Codable, Equatable, Identifiable, Sendable {
    let header: String
    let id: String
    let question: String
    let options: [UserInputOption]
}

struct UserInputAnswer: Codable, Equatable, Sendable {
    let questionId: String
    let selectedLabel: String?
    let freeText: String?
}

/// Sheet-owned selection state retained by the chat coordinator while a
/// question request remains pending. It is deliberately separate from the
/// canonical submitted answers so closing a sheet never fabricates history.
struct UserInputDraft: Codable, Equatable, Sendable {
    var selectedLabels: [String: String] = [:]
    var customAnswers: [String: String] = [:]
    var customQuestionIds: Set<String> = []
    /// Device-local acknowledgement that this request already auto-presented.
    /// It prevents a replayed live event from reopening the sheet after the
    /// user deliberately dismissed it without answering.
    var hasBeenPresented = false

    private enum CodingKeys: String, CodingKey {
        case selectedLabels
        case customAnswers
        case customQuestionIds
        case hasBeenPresented
    }

    init(request: UserInputRequest) {
        for answer in request.answers {
            if let freeText = answer.freeText {
                customQuestionIds.insert(answer.questionId)
                customAnswers[answer.questionId] = freeText
            } else if let selectedLabel = answer.selectedLabel {
                selectedLabels[answer.questionId] = selectedLabel
            }
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedLabels = try container.decodeIfPresent(
            [String: String].self,
            forKey: .selectedLabels
        ) ?? [:]
        customAnswers = try container.decodeIfPresent(
            [String: String].self,
            forKey: .customAnswers
        ) ?? [:]
        customQuestionIds = try container.decodeIfPresent(
            Set<String>.self,
            forKey: .customQuestionIds
        ) ?? []
        hasBeenPresented = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasBeenPresented
        ) ?? false
    }

    /// Reconcile device-local draft state against the current canonical tool
    /// request. A worker version can change while a question remains pending;
    /// stale question IDs and option labels must never be submitted.
    func reconciled(with request: UserInputRequest) -> UserInputDraft {
        var result = UserInputDraft(request: request)
        result.hasBeenPresented = hasBeenPresented
        guard request.isAnswerable else { return result }

        for question in request.questions {
            if customQuestionIds.contains(question.id) {
                result.customQuestionIds.insert(question.id)
                if let answer = customAnswers[question.id] {
                    result.customAnswers[question.id] = answer
                }
                result.selectedLabels.removeValue(forKey: question.id)
                continue
            }

            if let label = selectedLabels[question.id],
               question.options.contains(where: { $0.label == label }) {
                result.selectedLabels[question.id] = label
                result.customQuestionIds.remove(question.id)
                result.customAnswers.removeValue(forKey: question.id)
            }
        }
        return result
    }

    func answer(for question: UserInputQuestion) -> UserInputAnswer? {
        if customQuestionIds.contains(question.id) {
            guard let freeText = customAnswers[question.id]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !freeText.isEmpty else { return nil }
            return UserInputAnswer(
                questionId: question.id,
                selectedLabel: nil,
                freeText: freeText
            )
        }
        guard let selectedLabel = selectedLabels[question.id] else { return nil }
        return UserInputAnswer(
            questionId: question.id,
            selectedLabel: selectedLabel,
            freeText: nil
        )
    }

    func answers(for questions: [UserInputQuestion]) -> [UserInputAnswer] {
        questions.compactMap(answer(for:))
    }
}

struct UserInputRequest: Equatable, Identifiable, Sendable {
    let invocationId: String
    let questions: [UserInputQuestion]
    var answers: [UserInputAnswer]
    var status: UserInputRequestStatus

    var id: String { invocationId }
    var isAnswerable: Bool { status == .pending }

    static func decode(
        invocationId: String,
        arguments: [String: AnyCodable]?
    ) -> UserInputRequest? {
        guard let arguments,
              let data = try? JSONEncoder().encode(arguments),
              let params = try? JSONDecoder().decode(Params.self, from: data),
              questionsAreValid(params.questions) else {
            return nil
        }
        return UserInputRequest(
            invocationId: invocationId,
            questions: params.questions,
            answers: [],
            status: .pending
        )
    }

    static func decode(invocationId: String, argumentsJSON: String) -> UserInputRequest? {
        guard let data = argumentsJSON.data(using: .utf8),
              let params = try? JSONDecoder().decode(Params.self, from: data),
              questionsAreValid(params.questions) else {
            return nil
        }
        return UserInputRequest(
            invocationId: invocationId,
            questions: params.questions,
            answers: [],
            status: .pending
        )
    }

    private struct Params: Codable {
        let questions: [UserInputQuestion]
    }

    private static func questionsAreValid(_ questions: [UserInputQuestion]) -> Bool {
        guard (1...3).contains(questions.count) else { return false }
        var questionIds = Set<String>()
        for question in questions {
            guard !question.id.isEmpty,
                  questionIds.insert(question.id).inserted,
                  (2...3).contains(question.options.count) else {
                return false
            }
            let labels = question.options.map {
                $0.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
            guard Set(labels).count == labels.count,
                  !labels.contains("other") else {
                return false
            }
        }
        return true
    }
}

struct UserInputAnswerRecord: Equatable, Sendable {
    let invocationId: String
    let answers: [UserInputAnswer]
}

enum UserInputPresentation {
    /// Manual chip taps are an audit surface and may open any durable request
    /// state. Automatic presentation is intentionally narrower: only a new,
    /// pending request that has not already been shown may interrupt the user.
    static func shouldPresentSheet(
        for request: UserInputRequest,
        automatically: Bool,
        hasBeenPresented: Bool
    ) -> Bool {
        guard automatically else { return true }
        return request.isAnswerable && !hasBeenPresented
    }

    static func sheetTitle(for request: UserInputRequest) -> String {
        switch request.status {
        case .pending:
            request.questions.count == 1 ? "Question" : "Questions"
        case .answered:
            "Answers"
        case .failed:
            "Unavailable"
        }
    }

    static func chatTitle(for request: UserInputRequest) -> String {
        switch request.status {
        case .pending:
            request.questions.count == 1 ? "Question for you" : "Questions for you"
        case .answered:
            answeredTitle(count: request.answers.count)
        case .failed:
            "Question unavailable"
        }
    }

    private static func answeredTitle(count: Int) -> String {
        guard count > 0 else { return "Answered" }
        return "Answered \(count) question\(count == 1 ? "" : "s")"
    }
}
