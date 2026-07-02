import Testing
import CoreGraphics
@testable import TronMobile

@Suite("Chat Transcript Reveal Policy Tests")
struct ChatTranscriptRevealPolicyTests {
    @Test("Initial reconstruction hides transcript behind loader")
    func initialReconstructionShowsLoaderAndHidesTranscript() {
        #expect(ChatTranscriptRevealPolicy.loadingOverlayVisible(initialLoadComplete: false))
        #expect(ChatTranscriptRevealPolicy.contentOpacity(initialLoadComplete: false) == 0)
    }

    @Test("Completed initial load reveals transcript and removes loader")
    func completedInitialLoadRevealsTranscript() {
        #expect(!ChatTranscriptRevealPolicy.loadingOverlayVisible(initialLoadComplete: true))
        #expect(ChatTranscriptRevealPolicy.contentOpacity(initialLoadComplete: true) == 1)
    }

    @Test("Bottom distance uses settled content offset and clamps overscroll")
    func bottomDistanceUsesSettledContentOffset() {
        #expect(ChatTranscriptRevealPolicy.bottomDistance(
            contentHeight: 2_000,
            contentOffsetY: 1_300,
            containerHeight: 600,
            bottomInset: 80
        ) == 20)

        #expect(ChatTranscriptRevealPolicy.bottomDistance(
            contentHeight: 2_000,
            contentOffsetY: 1_400,
            containerHeight: 600,
            bottomInset: 80
        ) == 0)

        #expect(ChatTranscriptRevealPolicy.bottomDistance(
            contentHeight: 2_000,
            contentOffsetY: 1_480,
            containerHeight: 600,
            bottomInset: 80
        ) == 0)
    }

    @Test("Initial reveal waits for proxy, stable height, and real bottom")
    func initialRevealWaitsForBottomConvergence() {
        #expect(!ChatTranscriptRevealPolicy.isReadyToReveal(
            hasScrollProxy: false,
            contentHeightStable: true,
            distanceFromBottom: 0
        ))

        #expect(!ChatTranscriptRevealPolicy.isReadyToReveal(
            hasScrollProxy: true,
            contentHeightStable: false,
            distanceFromBottom: 0
        ))

        #expect(!ChatTranscriptRevealPolicy.isReadyToReveal(
            hasScrollProxy: true,
            contentHeightStable: true,
            distanceFromBottom: ChatTranscriptRevealPolicy.initialBottomTolerance + 1
        ))

        #expect(ChatTranscriptRevealPolicy.isReadyToReveal(
            hasScrollProxy: true,
            contentHeightStable: true,
            distanceFromBottom: ChatTranscriptRevealPolicy.initialBottomTolerance
        ))
    }

    @Test("Autoscroll near-bottom threshold uses measured distance")
    func autoscrollNearBottomUsesMeasuredDistance() {
        #expect(ChatTranscriptRevealPolicy.isNearBottomForAutoscroll(distanceFromBottom: 99))
        #expect(!ChatTranscriptRevealPolicy.isNearBottomForAutoscroll(distanceFromBottom: 100))
    }
}
