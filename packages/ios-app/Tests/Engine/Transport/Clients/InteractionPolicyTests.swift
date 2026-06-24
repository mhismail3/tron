import Testing
import Foundation

@testable import TronMobile

@Suite("InteractionPolicy")
@MainActor
struct InteractionPolicyTests {

    // MARK: - Helpers

    private struct Fixture {
        let provider: MockConnectionStateProvider
        let connection: ConnectionManager
        let clock: MockAsyncClock
        let policy: InteractionPolicy
    }

    private func makeFixture(initial: ConnectionState = .disconnected,
                             debounce: Duration = .milliseconds(500)) -> Fixture {
        let provider = MockConnectionStateProvider()
        provider.connectionState = initial
        let connection = ConnectionManager(provider: provider)
        let clock = MockAsyncClock(mode: .manual)
        let policy = InteractionPolicy(connection: connection, clock: clock, debounceDuration: debounce)
        return Fixture(provider: provider, connection: connection, clock: clock, policy: policy)
    }

    /// Yield so observation propagation can catch up.
    private func yieldForObservation() async {
        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Basic state derivation

    @Test("initial disconnected → isReadOnly true, isConnected false")
    func initialDisconnected() async {
        let f = makeFixture(initial: .disconnected)
        #expect(f.policy.isReadOnly)
        #expect(f.policy.isConnected == false)
        #expect(f.policy.canSendMessage == false)
        #expect(f.policy.canCreateSession == false)
        #expect(f.policy.canMutateSession == false)
        #expect(f.policy.canLoadServerData == false)
    }

    @Test("initial connected → isConnected true, all canX true immediately")
    func initialConnected() async {
        let f = makeFixture(initial: .connected)
        // Initial state bypass — no debounce on startup connected state.
        #expect(f.policy.isConnected)
        #expect(f.policy.isReadOnly == false)
        #expect(f.policy.canSendMessage)
        #expect(f.policy.canCreateSession)
        #expect(f.policy.canMutateSession)
        #expect(f.policy.canLoadServerData)
    }

    // MARK: - isReconnecting / isFailed

    @Test(".reconnecting → isReconnecting true, read-only")
    func reconnectingFlag() async {
        let f = makeFixture(initial: .reconnecting(attempt: 1, nextRetrySeconds: 5))
        #expect(f.policy.isReconnecting)
        #expect(f.policy.isReadOnly)
    }

    @Test(".connecting → isReconnecting true, read-only")
    func connectingFlag() async {
        let f = makeFixture(initial: .connecting)
        #expect(f.policy.isReconnecting)
        #expect(f.policy.isReadOnly)
    }

    @Test(".deployRestarting → isReconnecting true, read-only")
    func deployRestartingFlag() async {
        let f = makeFixture(initial: .deployRestarting(remainingSeconds: 10))
        #expect(f.policy.isReconnecting)
        #expect(f.policy.isReadOnly)
    }

    @Test(".failed → isFailed true, read-only")
    func failedFlag() async {
        let f = makeFixture(initial: .failed(reason: "boom"))
        #expect(f.policy.isFailed)
        #expect(f.policy.isReadOnly)
    }

    // MARK: - readOnlyReason

    @Test("readOnlyReason is nil when connected")
    func readOnlyReasonNilWhenConnected() async {
        let f = makeFixture(initial: .connected)
        #expect(f.policy.readOnlyReason == nil)
    }

    @Test("readOnlyReason returns localized text for each non-connected state")
    func readOnlyReasonNonNilForEachState() async {
        let cases: [ConnectionState] = [
            .disconnected,
            .connecting,
            .reconnecting(attempt: 3, nextRetrySeconds: 5),
            .deployRestarting(remainingSeconds: 10),
            .failed(reason: "network died")
        ]
        for state in cases {
            let f = makeFixture(initial: state)
            #expect(f.policy.readOnlyReason != nil)
            #expect(f.policy.readOnlyReason?.isEmpty == false)
        }
    }

    @Test("readOnlyReason for .failed includes the reason")
    func readOnlyReasonFailedReason() async {
        let f = makeFixture(initial: .failed(reason: "Connection lost"))
        #expect(f.policy.readOnlyReason?.contains("Connection lost") == true)
    }

    @Test("readOnlyReason for .reconnecting includes attempt number")
    func readOnlyReasonReconnectingAttempt() async {
        let f = makeFixture(initial: .reconnecting(attempt: 7, nextRetrySeconds: 0))
        #expect(f.policy.readOnlyReason?.contains("7") == true)
    }

    // MARK: - Debounce behavior

    @Test("disconnected → connected flip is debounced by 500ms")
    func debouncedConnectFlip() async {
        let f = makeFixture(initial: .disconnected, debounce: .milliseconds(500))

        f.provider.connectionState = .connected
        await yieldForObservation()

        // Policy should still be read-only until clock advances past debounce window.
        #expect(f.policy.isConnected == false, "debounce not yet elapsed")

        f.clock.advance(by: .milliseconds(500))
        await yieldForObservation()
        #expect(f.policy.isConnected)
    }

    @Test("rapid flap within debounce window does NOT flip to writable")
    func rapidFlapStaysReadOnly() async {
        let f = makeFixture(initial: .disconnected, debounce: .milliseconds(500))

        f.provider.connectionState = .connected
        await yieldForObservation()

        f.clock.advance(by: .milliseconds(200))
        await yieldForObservation()

        f.provider.connectionState = .disconnected
        await yieldForObservation()

        // Even if we advance the full window after the disconnect, it should remain read-only.
        f.clock.advance(by: .milliseconds(500))
        await yieldForObservation()

        #expect(f.policy.isConnected == false)
    }

    @Test("disconnect transition bypasses debounce (immediate read-only)")
    func disconnectImmediate() async {
        let f = makeFixture(initial: .connected)
        #expect(f.policy.isConnected)

        f.provider.connectionState = .disconnected
        await yieldForObservation()

        // No clock advancement needed — disconnect is immediate.
        #expect(f.policy.isConnected == false)
    }

    @Test("reconnect after disconnect applies debounce again")
    func reconnectAppliesDebounce() async {
        let f = makeFixture(initial: .connected)
        #expect(f.policy.isConnected)

        f.provider.connectionState = .disconnected
        await yieldForObservation()
        #expect(f.policy.isConnected == false)

        f.provider.connectionState = .connecting
        await yieldForObservation()

        f.provider.connectionState = .connected
        await yieldForObservation()

        // Still debouncing.
        #expect(f.policy.isConnected == false)

        f.clock.advance(by: .milliseconds(500))
        await yieldForObservation()
        #expect(f.policy.isConnected)
    }

    @Test("state passthrough matches connection.state")
    func statePassthrough() async {
        let f = makeFixture(initial: .connected)
        #expect(f.policy.state == .connected)

        f.provider.connectionState = .reconnecting(attempt: 2, nextRetrySeconds: 3)
        await yieldForObservation()
        #expect(f.policy.state == .reconnecting(attempt: 2, nextRetrySeconds: 3))
    }
}
