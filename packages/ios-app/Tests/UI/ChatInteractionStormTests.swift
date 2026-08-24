import CoreGraphics
import Testing
@testable import TronMobile

@MainActor
@Suite("Chat interaction storm")
struct ChatInteractionStormTests {
    @Test("all overlapping send participants share one generation")
    func overlappingParticipantsJoin() {
        let transaction = ChatLayoutTransaction()
        let generation = transaction.join(.submission)
        #expect(transaction.join(.keyboard) == generation)
        #expect(transaction.join(.transcriptGrowth) == generation)
        #expect(transaction.join(.catchUp) == generation)
        #expect(transaction.join(.morphFlight) == generation)
        #expect(transaction.generation?.joined.count == 5)
    }

    @Test("composer height installs atomically outside the motion generation")
    func composerHeightIsNotAMotionParticipant() {
        #expect(ChatComposerStructuralTransitionPolicy.admitsHeightChange(
            current: 44,
            measured: 88
        ))
        #expect(!ChatComposerStructuralTransitionPolicy.admitsHeightChange(
            current: 44,
            measured: 44.2
        ))

        let transaction = ChatLayoutTransaction()
        let generation = transaction.join(.submission)
        transaction.settle(generation, source: .submission)
        #expect(transaction.generation == nil)
    }

    @Test("direct interaction abandons every presentation-only participant")
    func directInteractionAbandons() {
        let transaction = ChatLayoutTransaction()
        _ = transaction.join(.submission)
        transaction.abandon()
        #expect(transaction.generation == nil)
    }

    @Test("detached mode never writes for keyboard or transcript growth")
    func detachedModePreservesAnchor() {
        var mode = ChatViewportMode.anchored
        mode.reduce(.submitted)
        mode.reduce(.prependBegan)
        mode.reduce(.prependEnded)
        #expect(mode == .anchored)
        #expect(!mode.sizeChangeAnchorIsBottom)
    }

    @Test("background suspension cancels disposable work but preserves the admitted send boundary")
    func backgroundSuspendsDisposableWork() {
        let presentation = ChatSessionPresentation(sessionID: "storm")
        presentation.suspendForBackground()
        #expect(presentation.openingTask == nil)
        #expect(presentation.photoImportTask == nil)
        #expect(presentation.attachmentPresentationTask == nil)
        #expect(presentation.attachmentDestination == nil)
        #expect(presentation.sessionID == "storm")
    }

    @Test("Reduce Motion resolves the storm to an immediate clock")
    func reduceMotion() {
        let clock = ChatLayoutClock.resolve(
            joined: [.submission, .keyboard, .morphFlight],
            keyboard: ChatKeyboardTransition(
                targetHeight: 300,
                duration: 0.32,
                curve: .easeInOut
            ),
            reduceMotion: true
        )
        #expect(clock.animation == nil)
        #expect(clock.duration == 0)
    }

    #if HOSTED_TEST
    @Test("geometry trace is bounded and coalesces identical presented samples")
    func geometryTraceBounds() {
        let probe = ChatHostedProbe()
        let geometry = ChatTranscriptGeometry(
            offsetY: 10,
            contentHeight: 100,
            containerHeight: 90,
            bottomInset: 8
        )
        for _ in 0..<500 {
            probe.updateGeometry(geometry)
            probe.recordComposerHeight(44)
        }
        #expect(probe.observation.geometryTrace.count == 2)
        #expect(probe.observation.hasMonotonicOffsetY)
    }
    #endif
}
