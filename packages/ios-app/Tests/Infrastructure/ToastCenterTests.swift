import Testing
import Foundation

@testable import TronMobile

@Suite("ToastCenter")
@MainActor
struct ToastCenterTests {

    // MARK: - Helpers

    private func makeSUT(maxVisible: Int = 3) -> (ToastCenter, MockAsyncClock) {
        let clock = MockAsyncClock(mode: .manual)
        let center = ToastCenter(clock: clock, maxVisible: maxVisible)
        return (center, clock)
    }

    private func yieldForAsync() async {
        for _ in 0..<3 {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Basic push / dismiss

    @Test("push adds toast to the queue")
    func pushAdds() async {
        let (sut, _) = makeSUT()
        sut.push("hello")
        #expect(sut.toasts.count == 1)
        #expect(sut.toasts[0].message == "hello")
        #expect(sut.toasts[0].severity == .error)
    }

    @Test("push with explicit severity stores severity")
    func pushSeverity() async {
        let (sut, _) = makeSUT()
        sut.push("warn", severity: .warning)
        sut.push("info", severity: .info)
        #expect(sut.toasts[0].severity == .warning)
        #expect(sut.toasts[1].severity == .info)
    }

    @Test("dismiss removes specific toast")
    func dismissRemoves() async {
        let (sut, _) = makeSUT()
        sut.push("a")
        sut.push("b")
        let firstId = sut.toasts[0].id
        sut.dismiss(firstId)
        #expect(sut.toasts.count == 1)
        #expect(sut.toasts[0].message == "b")
    }

    @Test("dismiss by dedupKey removes matching toasts")
    func dismissByDedupKeyRemovesMatches() async {
        let (sut, _) = makeSUT()
        sut.push("a", dedupKey: "connection")
        sut.push("b", dedupKey: "other")
        sut.dismiss(dedupKey: "connection")
        #expect(sut.toasts.count == 1)
        #expect(sut.toasts[0].message == "b")
    }

    @Test("dismissAll empties the queue")
    func dismissAllEmpties() async {
        let (sut, _) = makeSUT()
        sut.push("a")
        sut.push("b")
        sut.push("c")
        sut.dismissAll()
        #expect(sut.toasts.isEmpty)
    }

    // MARK: - Deduplication

    @Test("push with same dedupKey twice → only one toast")
    func dedupSuppressesDuplicate() async {
        let (sut, _) = makeSUT()
        sut.push("msg A", dedupKey: "k1")
        sut.push("msg B", dedupKey: "k1")
        #expect(sut.toasts.count == 1)
        #expect(sut.toasts[0].message == "msg A")
    }

    @Test("push without dedupKey allows duplicates")
    func noDedupKeyAllowsDuplicates() async {
        let (sut, _) = makeSUT()
        sut.push("same")
        sut.push("same")
        #expect(sut.toasts.count == 2)
    }

    @Test("dedup allows re-push after key's toast is dismissed")
    func dedupReenablesAfterDismiss() async {
        let (sut, _) = makeSUT()
        sut.push("msg A", dedupKey: "k1")
        let id = sut.toasts[0].id
        sut.dismiss(id)
        sut.push("msg B", dedupKey: "k1")
        #expect(sut.toasts.count == 1)
        #expect(sut.toasts[0].message == "msg B")
    }

    // MARK: - Overflow

    @Test("overflow drops oldest non-retry toast when maxVisible exceeded")
    func overflowDropsOldest() async {
        let (sut, _) = makeSUT(maxVisible: 3)
        sut.push("a")
        sut.push("b")
        sut.push("c")
        sut.push("d")  // exceeds max
        #expect(sut.toasts.count == 3)
        // Oldest ("a") dropped, "b/c/d" remain
        #expect(sut.toasts.map(\.message) == ["b", "c", "d"])
    }

    @Test("overflow preserves retry toasts when possible")
    func overflowPreservesRetry() async {
        let (sut, _) = makeSUT(maxVisible: 3)
        sut.push("retry-toast", retryHandler: {})
        sut.push("b")
        sut.push("c")
        sut.push("d")  // overflow
        #expect(sut.toasts.count == 3)
        #expect(sut.toasts.contains(where: { $0.message == "retry-toast" }))
        #expect(sut.toasts.contains(where: { $0.message == "d" }))
    }

    // MARK: - Auto-dismiss

    @Test(".after(duration) dismisses toast after the duration")
    func autoDismissTriggers() async {
        let (sut, clock) = makeSUT()
        sut.push("temp", autoDismiss: .after(.seconds(2)))
        #expect(sut.toasts.count == 1)

        await yieldForAsync()  // let the auto-dismiss Task register its sleep
        clock.advance(by: .seconds(2))
        await yieldForAsync()
        #expect(sut.toasts.isEmpty)
    }

    @Test(".sticky means no auto-dismiss regardless of time")
    func stickyToastNotDismissed() async {
        let (sut, clock) = makeSUT()
        sut.push("sticky", autoDismiss: .sticky)
        await yieldForAsync()
        clock.advance(by: .seconds(60))
        await yieldForAsync()
        #expect(sut.toasts.count == 1)
    }

    @Test("default auto-dismiss: info 2s, warning 3s, error 4s")
    func defaultAutoDismissDurationsBySeverity() async {
        let (sut, clock) = makeSUT()
        sut.push("info", severity: .info)
        sut.push("warn", severity: .warning)
        sut.push("err", severity: .error)
        await yieldForAsync()

        clock.advance(by: .seconds(2))
        await yieldForAsync()
        #expect(sut.toasts.contains(where: { $0.message == "info" }) == false)
        #expect(sut.toasts.contains(where: { $0.message == "warn" }))
        #expect(sut.toasts.contains(where: { $0.message == "err" }))

        clock.advance(by: .seconds(1))
        await yieldForAsync()
        #expect(sut.toasts.contains(where: { $0.message == "warn" }) == false)
        #expect(sut.toasts.contains(where: { $0.message == "err" }))

        clock.advance(by: .seconds(1))
        await yieldForAsync()
        #expect(sut.toasts.isEmpty)
    }

    @Test("retry toast has no default auto-dismiss")
    func retryToastSticky() async {
        let (sut, clock) = makeSUT()
        sut.push("retry", retryHandler: {})
        await yieldForAsync()
        clock.advance(by: .seconds(10))
        await yieldForAsync()
        #expect(sut.toasts.count == 1)
    }

    // MARK: - Tests helper

    @Test("clearForTesting empties state")
    func clearForTestingEmpties() async {
        let (sut, _) = makeSUT()
        sut.push("a")
        sut.push("b")
        sut.clearForTesting()
        #expect(sut.toasts.isEmpty)
    }

    @Test("dismiss cancels the auto-dismiss timer")
    func dismissCancelsAutoTimer() async {
        let (sut, clock) = makeSUT()
        sut.push("temp", autoDismiss: .after(.seconds(5)))
        await yieldForAsync()
        let id = sut.toasts[0].id
        sut.dismiss(id)
        #expect(sut.toasts.isEmpty)
        // Advancing the clock shouldn't crash or fire anything.
        clock.advance(by: .seconds(10))
        await yieldForAsync()
        #expect(sut.toasts.isEmpty)
    }
}
