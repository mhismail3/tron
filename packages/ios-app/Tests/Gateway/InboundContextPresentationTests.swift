import Testing
@testable import TronMobile

@Suite("Inbound context presentation")
struct InboundContextPresentationTests {
    @Test("extension context uses pastel provenance while unknown remains neutral")
    func provenanceTones() {
        #expect(InboundProducerPresentationPolicy.tone(for: .extension) == .purple)
        #expect(InboundProducerPresentationPolicy.tone(for: .subagent) == .information)
        #expect(InboundProducerPresentationPolicy.tone(for: .unknown) == .neutral)
    }

    @Test("goal details surface objective status and usage without custom-type inference")
    func structuredGoalDetails() throws {
        let presentation = try #require(InboundContextGoalPresentation.project(.object([
            "goal": .object([
                "objective": .string("count to 20"),
                "status": .string("active"),
                "tokensUsed": .number(120),
                "tokenBudget": .number(1_000),
                "timeUsedSeconds": .number(3),
            ]),
        ])))

        #expect(presentation.objective == "count to 20")
        #expect(presentation.status == "Active")
        #expect(InboundContextCompactPresentationPolicy.status(details: .object([
            "goal": .object(["status": .string("active")]),
        ])) == "Active")
        #expect(presentation.metadata.map(\.title) == [
            "Objective", "Status", "Tokens used", "Token budget", "Time used",
        ])
    }

    @Test("compact labels never expose payload text or technical message types")
    func compactLabels() {
        let origin = ChatOrigin(kind: .extension, title: "Pi Goal", confidence: .receipt)
        #expect(InboundProducerPresentationPolicy.compactTitle(for: origin) == "Pi Goal · Context")
        #expect(InboundProducerPresentationPolicy.title(for: nil) == "Unknown source")
        #expect(InboundProducerPresentationPolicy.compactTitle(for: nil) == "Context")
        #expect(InboundProducerPresentationPolicy.messageType("pi-goal-event") == "Pi Goal Event")
        #expect(InboundContextCompactPresentationPolicy.status(details: nil) == "Received")
    }

    @Test("subagent supervisor progress and attention use friendly message categories without inventing provenance")
    func subagentSupervisorCategories() {
        let unknown = ChatOrigin(kind: .unknown, confidence: .unknown)
        for (reason, expected) in [
            ("progress_update", "Progress Update"),
            ("need_decision", "Needs Attention"),
            ("interview_request", "Needs Attention"),
        ] {
            let presentation = InboundContextMessagePresentation(
                origin: unknown,
                customType: "subagent_supervisor_request",
                details: .object([
                    "id": .string("request-1"), "reason": .string(reason),
                    "expectsReply": .bool(reason != "progress_update"),
                    "runId": .string("run-1"), "agent": .string("worker"), "childIndex": .number(0),
                ])
            )
            #expect(presentation.title == "Subagent")
            #expect(presentation.status == expected)
            #expect(presentation.tone == .purple)
            #expect(presentation.detailsTitle == "Subagent update")
            #expect(InboundProducerPresentationPolicy.title(for: unknown) == "Unknown source")
            #expect(unknown.confidence == .unknown)
        }
    }

    @Test("control notices use the event type, not their message or a nested execution status")
    func subagentControlCategories() {
        let presentation = InboundContextMessagePresentation(
            origin: ChatOrigin(kind: .subagent, title: "Pi Subagents", confidence: .receipt),
            customType: "subagent_control_notice",
            details: .object(["event": .object([
                "type": .string("needs_attention"), "state": .string("running"),
                "message": .string("Private progress description"),
            ])])
        )
        #expect(presentation.title == "Subagent")
        #expect(presentation.status == "Needs Attention")
        #expect(presentation.tone == .purple)
        #expect(InboundContextMessagePresentation(origin: nil, customType: "subagent_control_notice", details: .object([
            "event": .object(["type": .string("active_long_running")]),
        ])).status == "Still Working")
    }

    @Test("completion notices identify a received result without claiming successful completion")
    func subagentResultsAreNotSuccessClaims() {
        let presentation = InboundContextMessagePresentation(origin: nil, customType: "subagent-notify", details: nil)
        #expect(presentation.title == "Subagent")
        #expect(presentation.status == "Result Received")
        #expect(presentation.status != "Completed")
    }

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

    @Test("unrelated dynamic details do not manufacture a goal")
    func unrelatedDetails() {
        #expect(InboundContextGoalPresentation.project(.object([
            "status": .string("active"),
            "objective": .string("not nested goal data"),
        ])) == nil)
    }
}
