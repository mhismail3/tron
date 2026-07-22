import Testing
@testable import TronMobile

@Suite("Session Context Presentation Tests")
struct SessionContextPresentationTests {
    @Test("Context progress is bounded before rendering")
    func contextProgressIsBounded() {
        #expect(SessionContextPresentation.boundedPercentage(-4) == 0)
        #expect(SessionContextPresentation.boundedPercentage(42) == 42)
        #expect(SessionContextPresentation.boundedPercentage(140) == 100)
        #expect(SessionContextPresentation.progressFraction(42) == 0.42)
    }

    @Test("Context pressure changes only at the visible warning thresholds")
    func contextPressureThresholds() {
        #expect(SessionContextPresentation.pressure(for: 79) == .normal)
        #expect(SessionContextPresentation.pressure(for: 80) == .elevated)
        #expect(SessionContextPresentation.pressure(for: 94) == .elevated)
        #expect(SessionContextPresentation.pressure(for: 95) == .critical)
    }

    @Test("Session mutations require an idle protocol-ready session")
    func sessionMutationPolicy() {
        #expect(SessionContextPresentation.canMutate(
            isConnected: true,
            isAgentActive: false,
            isCompacting: false,
            isBusy: false
        ))
        #expect(!SessionContextPresentation.canMutate(
            isConnected: false,
            isAgentActive: false,
            isCompacting: false,
            isBusy: false
        ))
        #expect(!SessionContextPresentation.canMutate(
            isConnected: true,
            isAgentActive: true,
            isCompacting: false,
            isBusy: false
        ))
        #expect(!SessionContextPresentation.canMutate(
            isConnected: true,
            isAgentActive: false,
            isCompacting: true,
            isBusy: false
        ))
        #expect(!SessionContextPresentation.canMutate(
            isConnected: true,
            isAgentActive: false,
            isCompacting: false,
            isBusy: true
        ))
    }

    @Test("Session usage appears only when the engine has reported usage")
    func sessionUsageVisibility() {
        #expect(!SessionContextPresentation.hasSessionUsage(
            inputTokens: 0,
            outputTokens: 0,
            cost: 0
        ))
        #expect(SessionContextPresentation.hasSessionUsage(
            inputTokens: 1,
            outputTokens: 0,
            cost: 0
        ))
        #expect(SessionContextPresentation.hasSessionUsage(
            inputTokens: 0,
            outputTokens: 0,
            cost: 0.01
        ))
    }

    @Test("Remaining context avoids a false zero while the model window loads")
    func remainingContextText() {
        #expect(SessionContextPresentation.remainingContextText(
            currentContextWindow: 0,
            tokensRemaining: 0
        ) == "Window loading")
        #expect(SessionContextPresentation.remainingContextText(
            currentContextWindow: 100_000,
            tokensRemaining: 75_000
        ) == "75.0K tokens left")
    }
}
