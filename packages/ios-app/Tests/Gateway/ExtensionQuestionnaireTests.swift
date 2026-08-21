import Foundation
import Testing
@testable import TronMobile

struct ExtensionQuestionnaireTests {
    private func interaction(
        questionnaire: ExtensionQuestionnaireDescriptor? = nil,
        options: [String]? = ["1. One"]
    ) -> ExtensionInteraction {
        ExtensionInteraction(
            id: "interaction", hostEpoch: "epoch", presentationRevision: 1,
            method: .select, title: "Question\nwith context", options: options,
            questionnaire: questionnaire
        )
    }

    @Test func structuredDescriptorRoundTripsAndIsAdmitted() throws {
        let descriptor = ExtensionQuestionnaireDescriptor(
            version: 1, question: "Choose", context: "Why?",
            options: [ExtensionQuestionnaireOption(label: "One", description: "First", preview: "**one**")],
            allowMultiple: false, allowFreeform: true
        )
        let value = interaction(questionnaire: descriptor, options: ["1. One", "2. Type a response…"])
        let data = try JSONEncoder.gateway.encode(value)
        let decoded = try JSONDecoder.gateway.decode(ExtensionInteraction.self, from: data)
        #expect(decoded == value)
        let state = ExtensionPresentationState(
            version: 2, hostEpoch: "epoch", revision: 1, capabilities: ["semantic.questionnaire.v1"], diagnostics: [],
            semanticState: .init(statuses: [:], statusOwners: [:], working: .init(visible: true, indicator: .init(kind: .default, frames: [])), widgets: [], toolsExpanded: false, editorRevision: 0, editorText: ""),
            surfaces: [], pendingInteractions: [value]
        )
        #expect(ExtensionPresentationPolicy.admit(state))
    }

    @Test func invalidQuestionnaireAndEmptyDuplicatePrimitiveOptionsAreRejected() {
        let descriptor = ExtensionQuestionnaireDescriptor(
            version: 1, question: "Choose", context: nil,
            options: [ExtensionQuestionnaireOption(label: "Same", description: nil, preview: nil), ExtensionQuestionnaireOption(label: "Same", description: nil, preview: nil)],
            allowMultiple: false, allowFreeform: false
        )
        #expect(!ExtensionPresentationPolicy.admit(ExtensionPresentationState(
            version: 2, hostEpoch: "epoch", revision: 1, capabilities: [], diagnostics: [],
            semanticState: .init(statuses: [:], statusOwners: [:], working: .init(visible: true, indicator: .init(kind: .default, frames: [])), widgets: [], toolsExpanded: false, editorRevision: 0, editorText: ""),
            surfaces: [], pendingInteractions: [interaction(questionnaire: descriptor, options: ["1. Same", "2. Same"])]
        )))
        #expect(!ExtensionPresentationPolicy.admit(ExtensionPresentationState(
            version: 2, hostEpoch: "epoch", revision: 1, capabilities: [], diagnostics: [],
            semanticState: .init(statuses: [:], statusOwners: [:], working: .init(visible: true, indicator: .init(kind: .default, frames: [])), widgets: [], toolsExpanded: false, editorRevision: 0, editorText: ""),
            surfaces: [], pendingInteractions: [interaction(options: [])]
        )))
    }

    @Test func crossMethodFieldsAreRejectedBeforePresentation() {
        let base = { (value: ExtensionInteraction) in
            ExtensionPresentationState(
                version: 2, hostEpoch: "epoch", revision: 1, capabilities: [], diagnostics: [],
                semanticState: .init(statuses: [:], statusOwners: [:], working: .init(visible: true, indicator: .init(kind: .default, frames: [])), widgets: [], toolsExpanded: false, editorRevision: 0, editorText: ""),
                surfaces: [], pendingInteractions: [value]
            )
        }
        #expect(!ExtensionPresentationPolicy.admit(base(ExtensionInteraction(id: "confirm", hostEpoch: "epoch", presentationRevision: 1, method: .confirm, title: "Confirm", options: ["bad"]))))
        #expect(!ExtensionPresentationPolicy.admit(base(ExtensionInteraction(id: "input", hostEpoch: "epoch", presentationRevision: 1, method: .input, title: "Input", options: ["bad"]))))
        #expect(!ExtensionPresentationPolicy.admit(base(ExtensionInteraction(id: "editor", hostEpoch: "epoch", presentationRevision: 1, method: .editor, title: "Editor", questionnaire: ExtensionQuestionnaireDescriptor(version: 1, question: "q", context: nil, options: [ExtensionQuestionnaireOption(label: "one", description: nil, preview: nil)], allowMultiple: false, allowFreeform: false)))))
    }

    @Test func nestedOptionDecodingIsBoundedAndUnknownFieldsRemainCompatible() throws {
        let options = String(repeating: "{\"label\":\"x\"},", count: 65).dropLast()
        let json = "{\"version\":1,\"question\":\"Pick\",\"options\":[\(options)],\"allowMultiple\":false,\"allowFreeform\":false,\"future\":true}"
        #expect(throws: Error.self) {
            _ = try JSONDecoder.gateway.decode(ExtensionQuestionnaireDescriptor.self, from: Data(json.utf8))
        }
        let valid = "{\"version\":1,\"question\":\"Pick\",\"options\":[{\"label\":\"One\"}],\"allowMultiple\":false,\"allowFreeform\":false,\"future\":true}"
        let decoded = try JSONDecoder.gateway.decode(ExtensionQuestionnaireDescriptor.self, from: Data(valid.utf8))
        #expect(decoded.options.count == 1)

        let oversizedQuestion = String(repeating: "q", count: 32 * 1_024 + 1)
        let oversizedQuestionJSON = "{\"version\":1,\"question\":\"\(oversizedQuestion)\",\"options\":[{\"label\":\"One\"}],\"allowMultiple\":false,\"allowFreeform\":false}"
        #expect(throws: Error.self) {
            _ = try JSONDecoder.gateway.decode(ExtensionQuestionnaireDescriptor.self, from: Data(oversizedQuestionJSON.utf8))
        }

        let oversizedLabel = String(repeating: "x", count: 2 * 1_024 + 1)
        let oversizedLabelJSON = "{\"version\":1,\"question\":\"Pick\",\"options\":[{\"label\":\"\(oversizedLabel)\"}],\"allowMultiple\":false,\"allowFreeform\":false}"
        #expect(throws: Error.self) {
            _ = try JSONDecoder.gateway.decode(ExtensionQuestionnaireDescriptor.self, from: Data(oversizedLabelJSON.utf8))
        }
    }

    @Test func responseBoundsUseUTF8BytesWithoutTruncation() {
        let exact = String(repeating: "é", count: ExtensionInteractionResponsePolicy.maximumResponseBytes / 2)
        let over = exact + "é"
        #expect(ExtensionInteractionResponsePolicy.primitiveTextError(exact) == nil)
        #expect(ExtensionInteractionResponsePolicy.primitiveTextError(over) != nil)
        let comment = ExtensionQuestionnaireAnswer(selections: [ExtensionQuestionnaireSelection(option: 0, comment: String(repeating: "x", count: ExtensionInteractionResponsePolicy.maximumCommentBytes + 1))], freeform: nil)
        #expect(ExtensionInteractionResponsePolicy.questionnaireError(comment) != nil)
    }

    @Test func structuredAnswerUsesBoundedCodableShape() throws {
        let answer = ExtensionQuestionnaireAnswer(
            selections: [ExtensionQuestionnaireSelection(option: 0, comment: "Useful")],
            freeform: "Additional context"
        )
        let data = try JSONEncoder.gateway.encode(answer)
        let decoded = try JSONDecoder.gateway.decode(JSONValue.self, from: data)
        #expect(decoded.objectValue?["freeform"]?.stringValue == "Additional context")
        #expect(decoded.objectValue?["selections"]?.arrayValue?.count == 1)
    }
}
