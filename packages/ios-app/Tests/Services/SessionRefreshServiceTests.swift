import Testing
import Foundation

@testable import TronMobile

@Suite("SessionRefreshService coalescing")
@MainActor
struct SessionRefreshServiceTests {

    // MARK: - Fixture

    @MainActor
    private final class RefreshCounter {
        var calls: Int = 0
        var delay: Duration = .zero

        /// Called by the service. Records the call and optionally sleeps to simulate inflight.
        func perform() async {
            calls += 1
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
        }
    }

    @MainActor
    private final class StateHolder {
        var isConnected: Bool
        init(_ isConnected: Bool) { self.isConnected = isConnected }
    }

    private func makeSUT(isConnected: Bool = true,
                         foregroundDebounce: Duration = .milliseconds(50),
                         clock: MockAsyncClock? = nil)
        -> (SessionRefreshService, RefreshCounter, StateHolder, MockAsyncClock) {
        let counter = RefreshCounter()
        let state = StateHolder(isConnected)
        let mockClock = clock ?? MockAsyncClock(mode: .instant)
        let service = SessionRefreshService(
            performRefresh: { await counter.perform() },
            isConnected: { state.isConnected },
            clock: mockClock,
            foregroundDebounce: foregroundDebounce
        )
        return (service, counter, state, mockClock)
    }

    private func yieldAsync(_ count: Int = 5) async {
        for _ in 0..<count {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Connected + idle

    @Test("connected + idle: request fires one refresh")
    func connectedIdleFires() async {
        let (service, counter, _, _) = makeSUT(isConnected: true)
        service.request(reason: .connectionEstablished)
        await yieldAsync()
        #expect(counter.calls == 1)
    }

    // MARK: - Coalescing

    @Test("connected + inflight: two concurrent requests → 1 inflight + 1 pending = 2 total")
    func coalescesToTwo() async {
        let (service, counter, _, _) = makeSUT(isConnected: true)
        counter.delay = .milliseconds(100)

        service.request(reason: .connectionEstablished)
        service.request(reason: .connectionEstablished)

        await yieldAsync(15)  // long enough to complete both inflight + pending
        #expect(counter.calls == 2)
    }

    @Test("connected + inflight: 5 concurrent requests → still 2 total (pending is flag, not counter)")
    func pendingIsNotACounter() async {
        let (service, counter, _, _) = makeSUT(isConnected: true)
        counter.delay = .milliseconds(100)

        for _ in 0..<5 {
            service.request(reason: .connectionEstablished)
        }

        await yieldAsync(15)
        #expect(counter.calls == 2)
    }

    // MARK: - Disconnected

    @Test("disconnected: request does NOT call performRefresh")
    func disconnectedDoesNothing() async {
        let (service, counter, _, _) = makeSUT(isConnected: false)
        service.request(reason: .foreground)
        service.request(reason: .settingsChanged)
        await yieldAsync()
        #expect(counter.calls == 0)
    }

    @Test("disconnected: request registers hook, fires on connection-manager reconnect")
    func disconnectedRegistersReconnectHook() async {
        let counter = RefreshCounter()
        let state = StateHolder(false)
        let provider = MockConnectionStateProvider()
        provider.connectionState = .disconnected
        let connectionManager = ConnectionManager(provider: provider)
        let service = SessionRefreshService(
            performRefresh: { await counter.perform() },
            isConnected: { state.isConnected },
            clock: MockAsyncClock(mode: .instant),
            foregroundDebounce: .milliseconds(50),
            connectionManager: connectionManager
        )

        service.request(reason: .foreground)
        await yieldAsync()
        #expect(counter.calls == 0)

        // Simulate reconnect: state transitions to connected and the hook should fire.
        state.isConnected = true
        provider.connectionState = .connected
        await yieldAsync(10)
        #expect(counter.calls == 1)
    }

    @Test("multiple disconnected requests coalesce into a single reconnect hook")
    func hookCoalesced() async {
        let counter = RefreshCounter()
        let state = StateHolder(false)
        let provider = MockConnectionStateProvider()
        provider.connectionState = .disconnected
        let connectionManager = ConnectionManager(provider: provider)
        let service = SessionRefreshService(
            performRefresh: { await counter.perform() },
            isConnected: { state.isConnected },
            clock: MockAsyncClock(mode: .instant),
            foregroundDebounce: .milliseconds(50),
            connectionManager: connectionManager
        )

        service.request(reason: .foreground)
        service.request(reason: .settingsChanged)
        service.request(reason: .unknownSession)

        state.isConnected = true
        provider.connectionState = .connected
        await yieldAsync(10)
        #expect(counter.calls == 1)
    }

    // MARK: - Foreground debounce

    @Test("5 .foreground requests within debounce window collapse into 1 refresh")
    func foregroundDebounce() async {
        let clock = MockAsyncClock(mode: .manual)
        let (service, counter, _, _) = makeSUT(isConnected: true,
                                                foregroundDebounce: .milliseconds(500),
                                                clock: clock)

        for _ in 0..<5 {
            service.request(reason: .foreground)
        }
        await yieldAsync()
        #expect(counter.calls == 0, "still debouncing")

        clock.advance(by: .milliseconds(500))
        await yieldAsync()
        #expect(counter.calls == 1)
    }

    @Test("non-foreground reasons are NOT debounced")
    func nonForegroundNotDebounced() async {
        let clock = MockAsyncClock(mode: .manual)
        let (service, counter, _, _) = makeSUT(isConnected: true,
                                                foregroundDebounce: .seconds(5),
                                                clock: clock)

        service.request(reason: .connectionEstablished)
        await yieldAsync()
        #expect(counter.calls == 1)

        service.request(reason: .settingsChanged)
        await yieldAsync()
        #expect(counter.calls == 2, "settingsChanged is not debounced")
    }

    @Test("foreground debounce is cancelled if a non-foreground request arrives")
    func nonForegroundCancelsForegroundDebounce() async {
        let clock = MockAsyncClock(mode: .manual)
        let (service, counter, _, _) = makeSUT(isConnected: true,
                                                foregroundDebounce: .seconds(5),
                                                clock: clock)

        service.request(reason: .foreground)  // would fire after debounce
        service.request(reason: .settingsChanged)  // fires immediately
        await yieldAsync()
        #expect(counter.calls == 1)

        // Advancing past the foreground debounce should NOT fire a second refresh,
        // since the non-foreground request already took the slot.
        clock.advance(by: .seconds(5))
        await yieldAsync()
        #expect(counter.calls == 1)
    }
}
