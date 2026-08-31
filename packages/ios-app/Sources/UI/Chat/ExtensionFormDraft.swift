import Foundation

struct ExtensionFormQuestionDraft: Codable, Equatable, Sendable {
    var optionIDs: Set<String> = []
    var other = ""
}

/// Ephemeral, ID-keyed form state. The Gateway descriptor remains authoritative;
/// this draft never enters session cache or canonical state.
struct ExtensionFormDraft: Codable, Equatable, Sendable {
    private(set) var values: [String: ExtensionFormQuestionDraft] = [:]

    init() {}

    init(form: ExtensionFormDescriptor) {
        values = Dictionary(uniqueKeysWithValues: form.questions.map { ($0.id, ExtensionFormQuestionDraft()) })
    }

    init(restoring stored: ExtensionFormDraft, for form: ExtensionFormDescriptor) {
        values = Dictionary(uniqueKeysWithValues: form.questions.map { question in
            let candidate = stored.value(for: question.id)
            let allowed = Set(question.options.map(\.id))
            let optionIDs = candidate.optionIDs.filter(allowed.contains)
            let admittedOptionIDs = question.multiSelect ? optionIDs : Set(optionIDs.prefix(1))
            let other = question.allowOther
                && candidate.other.utf8.count <= ExtensionInteractionResponsePolicy.maximumOtherBytes
                ? candidate.other : ""
            let value = !question.multiSelect && !other.isEmpty
                ? ExtensionFormQuestionDraft(optionIDs: [], other: other)
                : ExtensionFormQuestionDraft(optionIDs: admittedOptionIDs, other: other)
            return (question.id, value)
        })
    }

    func value(for questionID: String) -> ExtensionFormQuestionDraft {
        values[questionID] ?? ExtensionFormQuestionDraft()
    }

    mutating func toggle(optionID: String, for question: ExtensionFormQuestion) {
        guard question.options.contains(where: { $0.id == optionID }) else { return }
        var value = self.value(for: question.id)
        if question.multiSelect {
            if value.optionIDs.contains(optionID) { value.optionIDs.remove(optionID) }
            else { value.optionIDs.insert(optionID) }
        } else {
            value.optionIDs = [optionID]
            value.other = ""
        }
        values[question.id] = value
    }

    mutating func activateOther(for question: ExtensionFormQuestion) {
        guard question.allowOther else { return }
        var value = self.value(for: question.id)
        if !question.multiSelect { value.optionIDs.removeAll() }
        values[question.id] = value
    }

    mutating func clearOther(for question: ExtensionFormQuestion) {
        var value = self.value(for: question.id)
        value.other = ""
        values[question.id] = value
    }

    @discardableResult
    mutating func setOther(_ text: String, for question: ExtensionFormQuestion) -> Bool {
        guard question.allowOther,
              text.utf8.count <= ExtensionInteractionResponsePolicy.maximumOtherBytes else { return false }
        var value = self.value(for: question.id)
        value.other = text
        if !question.multiSelect, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            value.optionIDs.removeAll()
        }
        values[question.id] = value
        return true
    }

    func isAnswered(_ question: ExtensionFormQuestion) -> Bool {
        let value = value(for: question.id)
        return !value.optionIDs.isEmpty || !value.other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func isComplete(_ form: ExtensionFormDescriptor) -> Bool {
        form.questions.allSatisfy(isAnswered)
    }

    func answer(for form: ExtensionFormDescriptor) -> ExtensionFormAnswer {
        ExtensionFormAnswer(
            version: 1,
            answers: form.questions.map { question in
                let value = value(for: question.id)
                let order = Dictionary(uniqueKeysWithValues: question.options.enumerated().map { ($0.element.id, $0.offset) })
                let optionIDs = value.optionIDs.sorted { (order[$0] ?? .max) < (order[$1] ?? .max) }
                let other = value.other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value.other
                return ExtensionFormQuestionAnswer(questionId: question.id, optionIds: optionIDs, other: other)
            }
        )
    }
}
