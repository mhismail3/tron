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

    @Test("protocol hello is bounded independently of ordinary requests")
    func protocolHelloIsBounded() {
        #expect(EngineConnection.protocolHandshakeTimeout == 10.0)
        #expect(EngineConnection.protocolHandshakeTimeout < 30.0)
    }

    @Test("open transport is not public connection readiness before hello")
    func protocolHelloOwnsConnectedState() {
        let connection = makeSUT()
        connection.connectionState = .connecting
        connection.isConnectedFlag = true

        #expect(!connection.connectionState.isConnected)

        connection.markProtocolReady(maxMessageSize: 1_024)

        #expect(connection.connectionState == .connected)
        #expect(connection.negotiatedMaxMessageSize == 1_024)
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

    @Test("backgrounding retires the current WebSocket epoch")
    func backgroundRetiresCurrentTransport() {
        let connection = makeSUT()
        let task = URLSession.shared.webSocketTask(
            with: URL(string: "ws://127.0.0.1:55555/nonexistent")!
        )
        defer { task.cancel() }
        _ = connection.installTransportOwnership(task)
        connection.isConnectedFlag = true
        connection.connectionState = .connected
        connection.pingTask = Task { try? await Task.sleep(for: .seconds(60)) }
        connection.receiveTask = Task { try? await Task.sleep(for: .seconds(60)) }

        connection.setBackgroundState(true)

        #expect(connection.isInBackground)
        #expect(connection.connectionState == .disconnected)
        #expect(connection.engineConnectionTask == nil)
        #expect(connection.pingTask == nil)
        #expect(connection.receiveTask == nil)
        #expect(!connection.isConnectedFlag)
    }

    @Test("backgrounding preserves parked authorization failure")
    func backgroundPreservesUnauthorizedState() {
        let connection = makeSUT()
        connection.markUnauthorized(reason: "Re-pair required")

        connection.setBackgroundState(true)

        #expect(connection.isInBackground)
        #expect(connection.connectionState == .unauthorized(reason: "Re-pair required"))
    }

    @Test("heartbeat owns long-lived websocket liveness")
    func heartbeatOwnsLongLivedWebSocketLiveness() {
        let configuration = EngineConnection.makeSessionConfiguration()

        #expect(configuration.timeoutIntervalForRequest == 30.0)
        #expect(configuration.timeoutIntervalForResource.isInfinite)
    }

    @Test("concurrent disconnect signals share one reconnect owner")
    func reconnectOwnershipIsSingleFlight() async {
        let connection = EngineConnection(
            serverURL: URL(string: "ws://127.0.0.1:55555/nonexistent")!,
            sessionAttemptDirective: { _ in .handledFailure }
        )

        connection.startReconnectOwnership(deployRestart: false)
        connection.startReconnectOwnership(deployRestart: false)
        await Task.yield()

        #expect(connection.reconnectTaskGeneration == 1)
        #expect(connection.reconnectLoopActive)
        connection.cancelReconnectOwnership()
        #expect(!connection.reconnectLoopActive)
        #expect(connection.reconnectTask == nil)
    }

    @Test("manual retry rejoins the generation-owned reconnect loop")
    func manualRetryUsesReconnectOwner() async {
        let connection = EngineConnection(
            serverURL: URL(string: "ws://127.0.0.1:55555/nonexistent")!,
            sessionAttemptDirective: { _ in .handledFailure }
        )

        await connection.manualRetry()
        await Task.yield()

        #expect(connection.reconnectLoopActive)
        #expect(connection.reconnectTask != nil)
        #expect(connection.reconnectTaskGeneration > 0)

        connection.cancelReconnectOwnership()
        #expect(!connection.reconnectLoopActive)
        #expect(connection.reconnectTask == nil)
    }

    @Test(".failed reason after capped probe exhaustion uses tap-to-retry copy")
    func failedReasonCopy() {
        #expect(EngineConnection.failedAfterExhaustionReason == "Connection lost — tap to retry")
    }
}
