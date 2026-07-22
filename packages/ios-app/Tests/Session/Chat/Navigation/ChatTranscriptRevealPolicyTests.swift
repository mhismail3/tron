import Testing
import CoreGraphics
@testable import TronMobile

@Suite("Chat Transcript Reveal Policy Tests")
struct ChatTranscriptRevealPolicyTests {
    @Test("Initial reconstruction hides transcript while composer owns loading status")
    func initialReconstructionHidesTranscript() {
        #expect(ChatTranscriptRevealPolicy.contentOpacity(initialLoadComplete: false) == 0)
    }

    @Test("Completed initial load reveals transcript")
    func completedInitialLoadRevealsTranscript() {
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

    @Test("Initial reveal follows the bottom target instead of padded content residue")
    func initialRevealUsesBottomTarget() {
        let paddedContentDistance = ChatTranscriptRevealPolicy.bottomDistance(
            contentHeight: 2_000,
            contentOffsetY: 1_118,
            containerHeight: 800,
            bottomInset: 33
        )
        let settledAnchorDistance = ChatTranscriptRevealPolicy.bottomAnchorDistance(
            viewportHeight: 800,
            anchorMaxY: 800
        )

        #expect(paddedContentDistance == 49)
        #expect(settledAnchorDistance == 0)
        #expect(ChatTranscriptRevealPolicy.bottomAnchorDistance(
            viewportHeight: 800,
            anchorMaxY: 780
        ) == 0)
        #expect(ChatTranscriptRevealPolicy.isReadyToReveal(
            hasScrollProxy: true,
            consecutiveBottomSamples: 2,
            distanceFromBottom: settledAnchorDistance
        ))
        #expect(!ChatTranscriptRevealPolicy.isReadyToReveal(
            hasScrollProxy: true,
            consecutiveBottomSamples: 2,
            distanceFromBottom: ChatTranscriptRevealPolicy.bottomAnchorDistance(
                viewportHeight: 800,
                anchorMaxY: 988
            )
        ))
    }

    @Test("Initial reveal waits for proxy, consecutive samples, and real bottom")
    func initialRevealWaitsForBottomConvergence() {
        #expect(!ChatTranscriptRevealPolicy.isReadyToReveal(
            hasScrollProxy: false,
            consecutiveBottomSamples: 2,
            distanceFromBottom: 0
        ))

        #expect(!ChatTranscriptRevealPolicy.isReadyToReveal(
            hasScrollProxy: true,
            consecutiveBottomSamples: 1,
            distanceFromBottom: 0
        ))

        #expect(!ChatTranscriptRevealPolicy.isReadyToReveal(
            hasScrollProxy: true,
            consecutiveBottomSamples: 2,
            distanceFromBottom: ChatTranscriptRevealPolicy.initialBottomTolerance + 1
        ))

        #expect(ChatTranscriptRevealPolicy.isReadyToReveal(
            hasScrollProxy: true,
            consecutiveBottomSamples: 2,
            distanceFromBottom: ChatTranscriptRevealPolicy.initialBottomTolerance
        ))
    }

    @Test("Autoscroll near-bottom threshold uses measured distance")
    func autoscrollNearBottomUsesMeasuredDistance() {
        #expect(ChatTranscriptRevealPolicy.isNearBottomForAutoscroll(distanceFromBottom: 99))
        #expect(!ChatTranscriptRevealPolicy.isNearBottomForAutoscroll(distanceFromBottom: 100))
    }

    @Test("Undersized transcripts reveal at top and reject bottom positioning")
    func undersizedTranscriptStaysTopAligned() {
        let hasOverflow = ChatTranscriptRevealPolicy.hasScrollableOverflow(
            contentHeight: 700,
            viewportHeight: 1_200,
            bottomInset: 80
        )

        #expect(!hasOverflow)
        #expect(ChatTranscriptRevealPolicy.shouldRevealAtTop(
            hasScrollGeometry: true,
            hasScrollableOverflow: hasOverflow
        ))
        #expect(!ChatTranscriptRevealPolicy.shouldRequestBottomPosition(
            hasScrollGeometry: true,
            hasScrollableOverflow: hasOverflow
        ))
    }

    @Test("Overflowing transcripts retain bottom-follow behavior")
    func overflowingTranscriptFollowsBottom() {
        let hasOverflow = ChatTranscriptRevealPolicy.hasScrollableOverflow(
            contentHeight: 2_000,
            viewportHeight: 800,
            bottomInset: 80
        )

        #expect(hasOverflow)
        #expect(!ChatTranscriptRevealPolicy.shouldRevealAtTop(
            hasScrollGeometry: true,
            hasScrollableOverflow: hasOverflow
        ))
        #expect(ChatTranscriptRevealPolicy.shouldRequestBottomPosition(
            hasScrollGeometry: true,
            hasScrollableOverflow: hasOverflow
        ))
    }

    @Test("Unmeasured transcripts preserve conservative bottom eligibility")
    func unmeasuredTranscriptPreservesBottomEligibility() {
        #expect(!ChatTranscriptRevealPolicy.shouldRevealAtTop(
            hasScrollGeometry: false,
            hasScrollableOverflow: false
        ))
        #expect(ChatTranscriptRevealPolicy.shouldRequestBottomPosition(
            hasScrollGeometry: false,
            hasScrollableOverflow: false
        ))
    }
}
