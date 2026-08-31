import Foundation
import Testing
@testable import TronMobile

struct ExtensionFormTests {
    private func descriptor(allowCancel: Bool = true) -> ExtensionFormDescriptor {
        ExtensionFormDescriptor(
            version: 1,
            title: "Questions",
            questions: [
                ExtensionFormQuestion(
                    id: "db", header: "DB", question: "Which database?", context: "Need transactions.",
                    options: [ExtensionFormOption(id: "postgres", label: "Postgres", description: "Server"), ExtensionFormOption(id: "sqlite", label: "SQLite")],
                    multiSelect: false, allowOther: true
                ),
                ExtensionFormQuestion(
                    id: "regions", header: "Regions", question: "Which regions?",
                    options: [ExtensionFormOption(id: "us", label: "US"), ExtensionFormOption(id: "eu", label: "EU"), ExtensionFormOption(id: "apac", label: "APAC")],
                    multiSelect: true, allowOther: true
                ),
            ],
            allowCancel: allowCancel
        )
    }

    private func interaction(form: ExtensionFormDescriptor? = nil) -> ExtensionInteraction {
        ExtensionInteraction(
            id: "interaction", hostEpoch: "epoch", presentationRevision: 1,
            method: form == nil ? .select : .form,
            title: form?.title ?? "Choose",
            options: form == nil ? ["One"] : nil,
            form: form
        )
    }

    private func state(_ interactions: [ExtensionInteraction]) -> ExtensionPresentationState {
        ExtensionPresentationState(
            version: 3, hostEpoch: "epoch", revision: 1, capabilities: ["semantic.form.v1"], diagnostics: [],
            semanticState: .init(statuses: [:], statusOwners: [:], working: .init(visible: true, indicator: .init(kind: .default, frames: [])), widgets: [], toolsExpanded: false, editorRevision: 0, editorText: ""),
            surfaces: [], pendingInteractions: interactions
        )
    }

    @Test func formRoundTripsAndIsAdmitted() throws {
        let value = interaction(form: descriptor())
        let data = try JSONEncoder.gateway.encode(value)
        let decoded = try JSONDecoder.gateway.decode(ExtensionInteraction.self, from: data)
        #expect(decoded == value)
        #expect(ExtensionPresentationPolicy.admit(state([value])))
    }

    @Test func malformedDescriptorsAndCrossMethodFieldsAreRejected() {
        let valid = descriptor()
        let duplicateQuestion = ExtensionFormDescriptor(version: 1, title: valid.title, questions: [valid.questions[0], valid.questions[0]], allowCancel: true)
        let duplicateOptions = ExtensionFormDescriptor(
            version: 1, title: "Question",
            questions: [ExtensionFormQuestion(id: "q", question: "Choose", options: [ExtensionFormOption(id: "same", label: "A"), ExtensionFormOption(id: "same", label: "B")], multiSelect: false, allowOther: true)],
            allowCancel: true
        )
        #expect(!ExtensionPresentationPolicy.admit(state([interaction(form: duplicateQuestion)])))
        #expect(!ExtensionPresentationPolicy.admit(state([interaction(form: duplicateOptions)])))
        #expect(!ExtensionPresentationPolicy.admit(state([
            ExtensionInteraction(id: "select", hostEpoch: "epoch", presentationRevision: 1, method: .select, title: "Select", options: ["One"], form: valid)
        ])))
        #expect(!ExtensionPresentationPolicy.admit(state([
            ExtensionInteraction(id: "form", hostEpoch: "epoch", presentationRevision: 1, method: .form, title: "Form", options: ["bad"], form: valid)
        ])))
    }

    @Test func nestedDecodingIsBoundedBeforeMaterialization() {
        let option = "{\"id\":\"o\",\"label\":\"x\"}"
        let options = Array(repeating: option, count: 5).joined(separator: ",")
        let json = "{\"version\":1,\"title\":\"Questions\",\"allowCancel\":true,\"questions\":[{\"id\":\"q\",\"question\":\"Pick\",\"options\":[\(options)],\"multiSelect\":false,\"allowOther\":true}]}"
        #expect(throws: Error.self) {
            _ = try JSONDecoder.gateway.decode(ExtensionFormDescriptor.self, from: Data(json.utf8))
        }
        let oversized = String(repeating: "q", count: 4 * 1_024 + 1)
        let oversizedJSON = "{\"version\":1,\"title\":\"Questions\",\"allowCancel\":true,\"questions\":[{\"id\":\"q\",\"question\":\"\(oversized)\",\"options\":[{\"id\":\"a\",\"label\":\"A\"},{\"id\":\"b\",\"label\":\"B\"}],\"multiSelect\":false,\"allowOther\":true}]}"
        #expect(throws: Error.self) {
            _ = try JSONDecoder.gateway.decode(ExtensionFormDescriptor.self, from: Data(oversizedJSON.utf8))
        }
    }

    @Test func draftUsesStableIDsPreservesNavigationStateAndBuildsCanonicalAnswer() {
        let form = descriptor()
        var draft = ExtensionFormDraft(form: form)
        draft.toggle(optionID: "sqlite", for: form.questions[0])
        draft.toggle(optionID: "apac", for: form.questions[1])
        draft.toggle(optionID: "us", for: form.questions[1])
        draft.setOther("LATAM", for: form.questions[1])
        #expect(draft.isComplete(form))
        #expect(draft.answer(for: form) == ExtensionFormAnswer(version: 1, answers: [
            ExtensionFormQuestionAnswer(questionId: "db", optionIds: ["sqlite"], other: nil),
            ExtensionFormQuestionAnswer(questionId: "regions", optionIds: ["us", "apac"], other: "LATAM"),
        ]))
    }

    @Test func singleChoiceOtherAndSelectionAreMutuallyExclusive() {
        let form = descriptor()
        var draft = ExtensionFormDraft(form: form)
        draft.toggle(optionID: "postgres", for: form.questions[0])
        draft.setOther("CockroachDB", for: form.questions[0])
        #expect(draft.value(for: "db").optionIDs.isEmpty)
        draft.toggle(optionID: "sqlite", for: form.questions[0])
        #expect(draft.value(for: "db").other.isEmpty)
    }

    @Test func draftActivatesOtherBeforeTypingAndRejectsOversizedTextWithoutDiscardingTheLastValue() {
        let form = descriptor()
        var draft = ExtensionFormDraft(form: form)
        draft.toggle(optionID: "postgres", for: form.questions[0])
        draft.activateOther(for: form.questions[0])
        #expect(draft.value(for: "db").optionIDs.isEmpty)
        let admitted = draft.setOther("valid", for: form.questions[1])
        let rejected = draft.setOther(String(repeating: "é", count: ExtensionInteractionResponsePolicy.maximumOtherBytes / 2 + 1), for: form.questions[1])
        #expect(admitted)
        #expect(!rejected)
        #expect(draft.value(for: "regions").other == "valid")
        draft.clearOther(for: form.questions[1])
        #expect(draft.value(for: "regions").other.isEmpty)
    }

    @Test func sheetRestoresIndependentSwipePagesWithFixedProgressAndDirectRows() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appending(path: "Sources/UI/Chat/ExtensionFormSheet.swift"),
            encoding: .utf8
        )
        #expect(source.contains("TabView(selection: $currentQuestionIndex)"))
        #expect(source.contains(".tabViewStyle(.page(indexDisplayMode: .never))"))
        #expect(source.contains("fixedQuestionStatus(form)"))
        #expect(source.contains("page == currentQuestionIndex"))
        #expect(source.contains("questionPage(question, index: index)"))
        #expect(source.contains("private func questionPage"))
        #expect(source.contains("ScrollView"))
        #expect(source.contains("activeOtherQuestionIDs"))
        #expect(source.contains("focused($focusedQuestionID, equals: question.id)"))
        #expect(source.contains("ToolbarItem(placement: .topBarTrailing)"))
        #expect(source.contains("Button(action: submit)"))
        #expect(!source.contains("reviewing"))
        #expect(!source.contains("Review your answers"))
        #expect(!source.contains("Button(\"Next\""))
        #expect(!source.contains("ProgressView(value:"))
    }

    @Test func responsePolicyRequiresExactCoverageAndBoundsOtherByUTF8Bytes() {
        let form = descriptor()
        let valid = ExtensionFormAnswer(version: 1, answers: [
            ExtensionFormQuestionAnswer(questionId: "db", optionIds: ["postgres"], other: nil),
            ExtensionFormQuestionAnswer(questionId: "regions", optionIds: ["us"], other: nil),
        ])
        #expect(ExtensionInteractionResponsePolicy.formError(valid, descriptor: form) == nil)
        #expect(ExtensionInteractionResponsePolicy.formError(
            ExtensionFormAnswer(version: 1, answers: [valid.answers[0]]), descriptor: form
        ) != nil)
        #expect(ExtensionInteractionResponsePolicy.formError(
            ExtensionFormAnswer(version: 1, answers: [
                ExtensionFormQuestionAnswer(questionId: "db", optionIds: ["postgres"], other: "  \n"),
                valid.answers[1],
            ]), descriptor: form
        ) != nil)
        let oversizedOther = String(repeating: "é", count: ExtensionInteractionResponsePolicy.maximumOtherBytes / 2 + 1)
        #expect(ExtensionInteractionResponsePolicy.formError(
            ExtensionFormAnswer(version: 1, answers: [
                ExtensionFormQuestionAnswer(questionId: "db", optionIds: [], other: oversizedOther),
                valid.answers[1],
            ]), descriptor: form
        ) != nil)
    }
}
