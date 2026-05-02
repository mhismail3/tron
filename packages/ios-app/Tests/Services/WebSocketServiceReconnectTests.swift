import Testing
import Foundation

@testable import TronMobile

/// Behavioral tests for `WebSocketService`'s normal reconnect probe.
///
/// These tests avoid real network I/O and lock down the timing contract:
/// normal reconnect uses one short automatic probe, while the initial open
/// timeout remains longer for first connect/manual setup paths.
@Suite("WebSocketService reconnect integration")
@MainActor
struct WebSocketServiceReconnectTests {

    private func makeSUT() -> WebSocketService {
        WebSocketService(serverURL: URL(string: "ws://127.0.0.1:55555/nonexistent")!)
    }

    @Test("normal reconnect policy uses one two-second probe")
    func normalReconnectPolicyMatchesPlan() {
        let expected = ReconnectProbePolicy()
        #expect(expected.maxAutomaticAttempts == 1)
        #expect(expected.probeTimeout == 2.0)
        #expect(WebSocketService.automaticReconnectProbeTimeout == expected.probeTimeout)
    }

    @Test("default initial state is .disconnected")
    func initialStateDisconnected() {
        let ws = makeSUT()
        #expect(ws.connectionState == .disconnected)
    }

    @Test("foreground verification ping is bounded")
    func foregroundVerificationPingIsBounded() {
        #expect(WebSocketService.connectionVerificationTimeout == 3.0)
        #expect(WebSocketService.connectionVerificationTimeout < 30.0)
    }

    @Test("initial websocket open timeout remains longer than reconnect probe")
    func initialWebSocketOpenTimeoutIsBounded() {
        #expect(WebSocketService.connectionOpenTimeout == 10.0)
        #expect(WebSocketService.connectionOpenTimeout > WebSocketService.automaticReconnectProbeTimeout)
        #expect(WebSocketService.connectionOpenTimeout < 30.0)
    }

    @Test("foreground heartbeat detects idle disconnects quickly")
    func foregroundHeartbeatDetectsIdleDisconnectsQuickly() {
        #expect(WebSocketService.heartbeatInterval == 5.0)
        #expect(WebSocketService.heartbeatInterval < 30.0)
        #expect(WebSocketService.connectionVerificationTimeout < WebSocketService.heartbeatInterval)
    }

    @Test(".failed reason after probe failure uses tap-to-retry copy")
    func failedReasonCopy() {
        #expect(WebSocketService.failedAfterExhaustionReason == "Connection lost — tap to retry")
    }
}
