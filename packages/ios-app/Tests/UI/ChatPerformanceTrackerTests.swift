import Testing
@testable import TronMobile

@MainActor
@Suite("Chat performance interval ownership")
struct ChatPerformanceTrackerTests {
    @Test("replacement scroll commands discard only their owned interval")
    func scrollReplacement() {
        let signposts = RecordingPerformanceSignposts()
        let tracker = ChatPerformanceTracker(signposts: signposts)

        tracker.beginScrollCommand()
        tracker.beginScrollCommand()
        tracker.settleScroll()
        tracker.settleScroll()

        #expect(signposts.events() == [
            .begin(.scrollCommandSettle),
            .end(.scrollCommandSettle, .discarded, .none),
            .begin(.scrollCommandSettle),
            .end(.scrollCommandSettle, .success, .none),
        ])
    }

    @Test("stale prepend completion cannot close its replacement")
    func prependReplacement() {
        let signposts = RecordingPerformanceSignposts()
        let tracker = ChatPerformanceTracker(signposts: signposts)

        let stale = tracker.beginPrepend()
        let current = tracker.beginPrepend()
        tracker.endPrepend(generation: stale, result: .success)
        tracker.endPrepend(generation: current, result: .success)

        #expect(signposts.events() == [
            .begin(.prependSettle),
            .end(.prependSettle, .discarded, .none),
            .begin(.prependSettle),
            .end(.prependSettle, .success, .none),
        ])
    }

    @Test("prepend success requires a presented frame within one point")
    func prependPhysicalSettlement() async {
        let counter = FrameCounter()
        let scheduler = DisplayFrameScheduler { counter.value += 1 }

        let success = await ChatPrependSettlement.result(
            after: scheduler,
            requestedOffsetY: 120,
            isCurrent: { true },
            observedOffsetY: { 120.75 }
        )
        let failure = await ChatPrependSettlement.result(
            after: scheduler,
            requestedOffsetY: 120,
            isCurrent: { true },
            observedOffsetY: { 121.25 }
        )
        let discarded = await ChatPrependSettlement.result(
            after: scheduler,
            requestedOffsetY: 120,
            isCurrent: { false },
            observedOffsetY: { 120 }
        )

        #expect(success == .success)
        #expect(failure == .failure)
        #expect(discarded == .discarded)
        #expect(counter.value == 3)
    }

    @Test("paging restart clears the cancelled task and rejects stale finish")
    func pagingRestart() {
        let owner = ChatPagingOwner()
        let staleGeneration = owner.begin()
        owner.install(Task {}, generation: staleGeneration)
        #expect(owner.hasTask)

        let currentGeneration = owner.begin()

        #expect(!owner.hasTask)
        #expect(currentGeneration != staleGeneration)
        #expect(!owner.finish(generation: staleGeneration))
        owner.install(Task {}, generation: currentGeneration)
        #expect(owner.finish(generation: currentGeneration))
        #expect(!owner.hasTask)
    }

    @Test("teardown cancels each live interval once")
    func teardown() {
        let signposts = RecordingPerformanceSignposts()
        let tracker = ChatPerformanceTracker(signposts: signposts)

        tracker.beginScrollCommand()
        _ = tracker.beginPrepend()
        tracker.cancelAll()
        tracker.cancelAll()

        #expect(signposts.events() == [
            .begin(.scrollCommandSettle),
            .begin(.prependSettle),
            .end(.scrollCommandSettle, .cancelled, .none),
            .end(.prependSettle, .cancelled, .none),
        ])
    }

    private final class FrameCounter {
        var value = 0
    }
}
