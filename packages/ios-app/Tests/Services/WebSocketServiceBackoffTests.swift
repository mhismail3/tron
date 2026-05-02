import Testing
import Foundation

@testable import TronMobile

/// Behavioral tests for `WebSocketService`'s backoff swap.
///
/// These tests exercise the backoff integration without doing real network I/O:
/// - Confirm the default policy maps to the 3-attempt / exponential schedule.
/// - Confirm foreground verification, idle heartbeat, and initial open checks use bounded timing.
/// - Confirm the failure message matches the new "tap to retry" user-facing copy.
///
/// True end-to-end reconnect timing tests would be slow (30s+) and brittle — those are
/// covered by manual verification + the unit-tested `BackoffPolicy` table.
@Suite("WebSocketService backoff integration")
@MainActor
struct WebSocketServiceBackoffTests {

    private func makeSUT() -> WebSocketService {
        WebSocketService(serverURL: URL(string: "ws://127.0.0.1:55555/nonexistent")!)
    }

    @Test("default policy: 3 attempts at 2s / 4s / 8s, no jitter")
    func policyConfigMatchesPlan() {
        let expected = BackoffPolicy()
        #expect(expected.maxAttempts == 3)
        #expect(expected.baseUnit == 2.0)
        #expect(expected.cap == 30.0)
        #expect(expected.jitterFraction == 0.0)
        #expect(expected.baseDelay(forAttempt: 1) == 2.0)
        #expect(expected.baseDelay(forAttempt: 2) == 4.0)
        #expect(expected.baseDelay(forAttempt: 3) == 8.0)
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

    @Test("initial websocket open timeout allows slower handshakes without using RPC timeout")
    func initialWebSocketOpenTimeoutIsBounded() {
        #expect(WebSocketService.connectionOpenTimeout == 10.0)
        #expect(WebSocketService.connectionOpenTimeout > WebSocketService.connectionVerificationTimeout)
        #expect(WebSocketService.connectionOpenTimeout < 30.0)
    }

    @Test("foreground heartbeat detects idle disconnects quickly")
    func foregroundHeartbeatDetectsIdleDisconnectsQuickly() {
        #expect(WebSocketService.heartbeatInterval == 5.0)
        #expect(WebSocketService.heartbeatInterval < 30.0)
        #expect(WebSocketService.connectionVerificationTimeout < WebSocketService.heartbeatInterval)
    }

    @Test(".failed reason after exhaustion uses tap-to-retry copy")
    func failedReasonCopy() {
        #expect(WebSocketService.failedAfterExhaustionReason == "Connection lost — tap to retry")
    }
}
