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
        #expect(presentation.compactStatus == "Active · count to 20")
        #expect(presentation.metadata.map(\.title) == [
            "Objective", "Status", "Tokens used", "Token budget", "Time used",
        ])
    }

    @Test("unrelated dynamic details do not manufacture a goal")
    func unrelatedDetails() {
        #expect(InboundContextGoalPresentation.project(.object([
            "status": .string("active"),
            "objective": .string("not nested goal data"),
        ])) == nil)
    }
}
