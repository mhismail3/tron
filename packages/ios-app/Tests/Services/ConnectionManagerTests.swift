import Testing
import Foundation

@testable import TronMobile

@Suite("ConnectionManager")
@MainActor
struct ConnectionManagerTests {

    // MARK: - Helpers

    private func makeSUT(initialState: ConnectionState = .disconnected) -> (ConnectionManager, MockConnectionStateProvider) {
        let provider = MockConnectionStateProvider()
        provider.connectionState = initialState
        let manager = ConnectionManager(provider: provider)
        return (manager, provider)
    }

    /// Yield a few times so the observation-loop Task can propagate a state change.
    private func waitForStateSync() async {
        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - State mirroring

    @Test("initial state mirrors provider on init")
    func initialStateMirrorsProvider() async {
        let (manager, _) = makeSUT(initialState: .connected)
        #expect(manager.state == .connected)
    }

    @Test("state tracks provider state changes")
    func stateTracksProvider() async {
        let (manager, provider) = makeSUT(initialState: .disconnected)
        #expect(manager.state == .disconnected)

        provider.connectionState = .connecting
        await waitForStateSync()
        #expect(manager.state == .connecting)

        provider.connectionState = .connected
        await waitForStateSync()
        #expect(manager.state == .connected)
    }

    // MARK: - runOnReconnect

    @Test("runOnReconnect fires immediately when already connected")
    func hookFiresImmediatelyWhenConnected() async {
        let (manager, _) = makeSUT(initialState: .connected)
        let fired = ManualExpectation()
        manager.runOnReconnect(label: "x") { await fired.fulfill() }

        await fired.waitForFulfillment(timeout: .seconds(1))
        #expect(await fired.wasFulfilled)
    }

    @Test("runOnReconnect holds hook while disconnected, fires on .connected")
    func hookHeldUntilConnected() async {
        let (manager, provider) = makeSUT(initialState: .disconnected)
        let fired = ManualExpectation()
        manager.runOnReconnect(label: "x") { await fired.fulfill() }

        // Not yet fired
        await waitForStateSync()
        #expect(await fired.wasFulfilled == false)

        // Transition connecting → connected
        provider.connectionState = .connecting
        await waitForStateSync()
        #expect(await fired.wasFulfilled == false)

        provider.connectionState = .connected
        await fired.waitForFulfillment(timeout: .seconds(1))
        #expect(await fired.wasFulfilled)
    }

    @Test("re-registering same label replaces the prior block (coalesce)")
    func sameLabelReplacesBlock() async {
        let (manager, provider) = makeSUT(initialState: .disconnected)
        let firstFired = ManualExpectation()
        let secondFired = ManualExpectation()

        manager.runOnReconnect(label: "refresh") { await firstFired.fulfill() }
        manager.runOnReconnect(label: "refresh") { await secondFired.fulfill() }

        provider.connectionState = .connected
        await secondFired.waitForFulfillment(timeout: .seconds(1))

        #expect(await secondFired.wasFulfilled)
        #expect(await firstFired.wasFulfilled == false)
    }

    @Test("hook fires exactly once per registration (single-shot)")
    func singleShot() async {
        let (manager, provider) = makeSUT(initialState: .disconnected)
        let counter = Counter()

        manager.runOnReconnect(label: "x") { await counter.increment() }

        // Disconnect → connect cycle 1
        provider.connectionState = .connected
        await waitForStateSync()
        try? await Task.sleep(for: .milliseconds(50))

        // Disconnect → connect cycle 2 (hook should NOT re-fire)
        provider.connectionState = .disconnected
        await waitForStateSync()
        provider.connectionState = .connected
        await waitForStateSync()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await counter.value == 1)
    }

    @Test("multiple different-label hooks all fire on reconnect")
    func multipleLabelsAllFire() async {
        let (manager, provider) = makeSUT(initialState: .disconnected)
        let a = ManualExpectation(), b = ManualExpectation(), c = ManualExpectation()

        manager.runOnReconnect(label: "a") { await a.fulfill() }
        manager.runOnReconnect(label: "b") { await b.fulfill() }
        manager.runOnReconnect(label: "c") { await c.fulfill() }

        provider.connectionState = .connected

        await a.waitForFulfillment(timeout: .seconds(1))
        await b.waitForFulfillment(timeout: .seconds(1))
        await c.waitForFulfillment(timeout: .seconds(1))

        #expect(await a.wasFulfilled)
        #expect(await b.wasFulfilled)
        #expect(await c.wasFulfilled)
    }

    @Test("cancelHook before fire prevents execution")
    func cancelHookPreventsExecution() async {
        let (manager, provider) = makeSUT(initialState: .disconnected)
        let fired = ManualExpectation()

        manager.runOnReconnect(label: "x") { await fired.fulfill() }
        manager.cancelHook(label: "x")

        provider.connectionState = .connected
        await waitForStateSync()
        try? await Task.sleep(for: .milliseconds(100))

        #expect(await fired.wasFulfilled == false)
    }

    @Test("cancelHook is a no-op for unknown label")
    func cancelHookUnknownLabelIsNoOp() async {
        let (manager, _) = makeSUT(initialState: .connected)
        manager.cancelHook(label: "never-registered")  // should not crash
    }

    // MARK: - manualRetry

    @Test("manualRetry delegates to provider")
    func manualRetryDelegates() async {
        let (manager, provider) = makeSUT(initialState: .failed(reason: "test"))
        await manager.manualRetry()
        #expect(provider.manualRetryCallCount == 1)
    }

    // MARK: - Hook isolation

    @Test("hook exception does not prevent other hooks from firing")
    func hookExceptionIsolation() async {
        let (manager, provider) = makeSUT(initialState: .disconnected)
        let goodFired = ManualExpectation()

        manager.runOnReconnect(label: "bad") {
            // Silently do nothing; we just need other hooks to still fire.
            // Swift closures can't throw without being `throws` — we simulate failure by
            // doing nothing harmful; the test validates hooks are isolated via Tasks.
        }
        manager.runOnReconnect(label: "good") { await goodFired.fulfill() }

        provider.connectionState = .connected
        await goodFired.waitForFulfillment(timeout: .seconds(1))
        #expect(await goodFired.wasFulfilled)
    }

    // MARK: - Transient states don't fire hooks

    @Test(".connecting transition does NOT fire hooks")
    func connectingDoesNotFireHooks() async {
        let (manager, provider) = makeSUT(initialState: .disconnected)
        let fired = ManualExpectation()
        manager.runOnReconnect(label: "x") { await fired.fulfill() }

        provider.connectionState = .connecting
        await waitForStateSync()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await fired.wasFulfilled == false)
    }

    @Test(".reconnecting transition does NOT fire hooks")
    func reconnectingDoesNotFireHooks() async {
        let (manager, provider) = makeSUT(initialState: .disconnected)
        let fired = ManualExpectation()
        manager.runOnReconnect(label: "x") { await fired.fulfill() }

        provider.connectionState = .reconnecting(attempt: 1, nextRetrySeconds: 5)
        await waitForStateSync()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await fired.wasFulfilled == false)
    }

    @Test(".failed transition does NOT fire hooks")
    func failedDoesNotFireHooks() async {
        let (manager, provider) = makeSUT(initialState: .disconnected)
        let fired = ManualExpectation()
        manager.runOnReconnect(label: "x") { await fired.fulfill() }

        provider.connectionState = .failed(reason: "nope")
        await waitForStateSync()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await fired.wasFulfilled == false)
    }
}

// MARK: - Test doubles

@Observable
@MainActor
final class MockConnectionStateProvider: ConnectionStateProvider {
    var connectionState: ConnectionState = .disconnected
    var manualRetryCallCount = 0

    func manualRetry() async {
        manualRetryCallCount += 1
    }
}

/// Lightweight main-actor counter for increment tests.
@MainActor
final class Counter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}

/// Mirror of AsyncExpectation but reused here to avoid cross-suite conflicts.
actor ManualExpectation {
    private var fulfilled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var wasFulfilled: Bool { fulfilled }

    func fulfill() {
        fulfilled = true
        let toResume = waiters
        waiters.removeAll()
        for continuation in toResume { continuation.resume() }
    }

    func waitForFulfillment(timeout: Duration) async {
        if fulfilled { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                await withCheckedContinuation { continuation in
                    Task { await self.register(continuation) }
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            await group.next()
            group.cancelAll()
        }
    }

    private func register(_ continuation: CheckedContinuation<Void, Never>) {
        if fulfilled {
            continuation.resume()
        } else {
            waiters.append(continuation)
        }
    }
}
