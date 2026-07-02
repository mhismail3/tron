import Testing
@testable import TronMobile

@Suite("Chat Message Visibility Policy Tests")
struct ChatMessageVisibilityPolicyTests {
    @Test("Reconstructed transcript is visible when view-local load flag is stale")
    func reconstructedTranscriptFailsOpenAfterStaleInitialLoadFlag() {
        #expect(ChatMessageVisibilityPolicy.isVisible(
            index: 0,
            total: 12,
            initialLoadComplete: false,
            hasReconstructedState: true,
            isCascading: false,
            cascadeAllowsVisibility: false
        ))
    }

    @Test("First load can still defer rows during initial cascade")
    func firstLoadUsesCascadeVisibility() {
        #expect(!ChatMessageVisibilityPolicy.isVisible(
            index: 0,
            total: 12,
            initialLoadComplete: false,
            hasReconstructedState: false,
            isCascading: false,
            cascadeAllowsVisibility: false
        ))
    }

    @Test("Active cascade keeps using cascade visibility")
    func activeCascadeControlsVisibility() {
        #expect(!ChatMessageVisibilityPolicy.isVisible(
            index: 0,
            total: 12,
            initialLoadComplete: true,
            hasReconstructedState: true,
            isCascading: true,
            cascadeAllowsVisibility: false
        ))
    }
}
