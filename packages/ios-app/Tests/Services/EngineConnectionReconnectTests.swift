import Testing
import Foundation

@testable import TronMobile

/// Behavioral tests for `EngineConnection`'s normal reconnect loop.
///
/// These tests avoid real network I/O and lock down the timing contract:
/// normal reconnect uses short foreground probes at a bounded cadence, while
/// the initial open timeout remains longer for first connect/manual setup paths.
@Suite("EngineConnection reconnect integration")
@MainActor
struct EngineConnectionReconnectTests {

    private func makeSUT() -> EngineConnection {
        EngineConnection(serverURL: URL(string: "ws://127.0.0.1:55555/nonexistent")!)
    }

    @Test("normal reconnect policy uses foreground retries")
    func normalReconnectPolicyMatchesPlan() {
        let expected = ReconnectProbePolicy()
        #expect(expected.maxAutomaticAttempts == nil)
        #expect(expected.probeTimeout == 2.0)
        #expect(expected.retryDelay == 3.0)
        #expect(EngineConnection.automaticReconnectProbeTimeout == expected.probeTimeout)
        #expect(EngineConnection.automaticReconnectRetryDelay == expected.retryDelay)
    }

    @Test("default initial state is .disconnected")
    func initialStateDisconnected() {
        let ws = makeSUT()
        #expect(ws.connectionState == .disconnected)
    }

    @Test("foreground verification ping allows local engine warm-up")
    func foregroundVerificationPingIsBounded() {
        #expect(EngineConnection.connectionVerificationTimeout == 10.0)
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
        #expect(EngineConnection.connectionVerificationTimeout >= EngineConnection.heartbeatInterval)
        #expect(EngineConnection.connectionVerificationTimeout < 30.0)
    }

    @Test(".failed reason after capped probe exhaustion uses tap-to-retry copy")
    func failedReasonCopy() {
        #expect(EngineConnection.failedAfterExhaustionReason == "Connection lost — tap to retry")
    }
}
