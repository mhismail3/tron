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
}
