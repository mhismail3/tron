import Foundation
import Testing
@testable import TronMobile

@Suite("Inbound context presentation")
struct InboundContextPresentationTests {

    @Test("unknown and malformed message details cannot invent attention or leak arbitrary payloads")
    func subagentCategoryAdmission() {
        for customType in ["other-extension", "subagent_supervisor_request_spoof", "subagent-notify-extra"] {
            let presentation = InboundContextMessagePresentation(origin: nil, customType: customType, details: .object([
                "reason": .string("progress_update"),
                "event": .object(["type": .string("needs_attention")]),
            ]))
            #expect(presentation.title == "Context")
            #expect(presentation.status == "Received")
            #expect(presentation.tone == .neutral)
        }
        for details: JSONValue? in [nil, .string("needs_attention"), .object(["reason": .string("Private arbitrary text")])] {
            let presentation = InboundContextMessagePresentation(origin: nil, customType: "subagent_supervisor_request", details: details)
            #expect(presentation.status == "Update")
        }
        let goal = InboundContextMessagePresentation(
            origin: ChatOrigin(kind: .extension, title: "Goal", confidence: .receipt),
            customType: "goal", details: .object(["goal": .object(["status": .string("active")])])
        )
        #expect(goal.title == "Goal · Context")
        #expect(goal.status == "Active")
    }
}
