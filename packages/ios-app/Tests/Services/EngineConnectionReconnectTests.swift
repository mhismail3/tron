import Testing
import Foundation

@testable import TronMobile

/// Behavioral tests for `EngineConnection`'s normal reconnect probe.
///
/// These tests avoid real network I/O and lock down the timing contract:
/// normal reconnect uses one short automatic probe, while the initial open
/// timeout remains longer for first connect/manual setup paths.
@Suite("EngineConnection reconnect integration")
@MainActor
struct EngineConnectionReconnectTests {

    private func makeSUT() -> EngineConnection {
        EngineConnection(serverURL: URL(string: "ws://127.0.0.1:55555/nonexistent")!)
    }

    @Test("normal reconnect policy uses one two-second probe")
    func normalReconnectPolicyMatchesPlan() {
        let expected = ReconnectProbePolicy()
        #expect(expected.maxAutomaticAttempts == 1)
        #expect(expected.probeTimeout == 2.0)
        #expect(EngineConnection.automaticReconnectProbeTimeout == expected.probeTimeout)
    }

    @Test("default initial state is .disconnected")
    func initialStateDisconnected() {
        let ws = makeSUT()
        #expect(ws.connectionState == .disconnected)
    }

    @Test("foreground verification ping is bounded")
    func foregroundVerificationPingIsBounded() {
        #expect(EngineConnection.connectionVerificationTimeout == 3.0)
        #expect(EngineConnection.connectionVerificationTimeout < 30.0)
    }

    @Test("initial websocket open timeout remains longer than reconnect probe")
    func initialWebSocketOpenTimeoutIsBounded() {
        #expect(EngineConnection.connectionOpenTimeout == 10.0)
        #expect(EngineConnection.connectionOpenTimeout > EngineConnection.automaticReconnectProbeTimeout)
        #expect(EngineConnection.connectionOpenTimeout < 30.0)
    }

    @Test("manual retry uses the full open timeout")
    func manualRetryUsesFullOpenTimeout() {
        #expect(EngineConnection.manualRetryOpenTimeout == EngineConnection.connectionOpenTimeout)
        #expect(EngineConnection.manualRetryOpenTimeout > EngineConnection.automaticReconnectProbeTimeout)
    }

    @Test("foreground heartbeat detects idle disconnects quickly")
    func foregroundHeartbeatDetectsIdleDisconnectsQuickly() {
        #expect(EngineConnection.heartbeatInterval == 5.0)
        #expect(EngineConnection.heartbeatInterval < 30.0)
        #expect(EngineConnection.connectionVerificationTimeout < EngineConnection.heartbeatInterval)
    }

    @Test(".failed reason after probe failure uses tap-to-retry copy")
    func failedReasonCopy() {
        #expect(EngineConnection.failedAfterExhaustionReason == "Connection lost — tap to retry")
    }
}
