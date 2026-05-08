import Testing
import Foundation
@testable import TronMobile

// MARK: - EngineClient Observation Tests

@Suite("EngineClient Observation")
@MainActor
struct EngineClientObservationTests {

    @Test("Initial connection state is disconnected")
    func testInitialState() {
        let rpc = EngineClient(serverURL: URL(string: "ws://localhost:8080/engine")!)
        #expect(rpc.connectionState == .disconnected)
    }

    @Test("Disconnect cancels observation and resets state")
    func testDisconnectResetsState() async {
        let rpc = EngineClient(serverURL: URL(string: "ws://localhost:8080/engine")!)
        await rpc.disconnect()
        #expect(rpc.connectionState == .disconnected)
    }

    @Test("EngineClient can be deallocated without crash")
    func testDeallocationSafety() async {
        var rpc: EngineClient? = EngineClient(serverURL: URL(string: "ws://localhost:8080/engine")!)
        #expect(rpc != nil)
        rpc = nil
        #expect(rpc == nil)
    }

    @Test("Multiple disconnect calls are safe")
    func testMultipleDisconnects() async {
        let rpc = EngineClient(serverURL: URL(string: "ws://localhost:8080/engine")!)
        await rpc.disconnect()
        await rpc.disconnect()
        #expect(rpc.connectionState == .disconnected)
    }

    @Test("Connect policy discards stale disconnected transports")
    func testConnectPolicyDiscardsStaleDisconnectedTransport() {
        #expect(EngineClientConnectionPolicy.shouldSkipConnect(state: .disconnected) == false)
        #expect(EngineClientConnectionPolicy.shouldDiscardExistingTransport(
            hasTransport: true,
            state: .disconnected
        ))
    }

    @Test("Connect policy preserves active in-flight transports")
    func testConnectPolicyPreservesActiveTransport() {
        #expect(EngineClientConnectionPolicy.shouldSkipConnect(state: .connected))
        #expect(EngineClientConnectionPolicy.shouldSkipConnect(state: .connecting))
        #expect(EngineClientConnectionPolicy.shouldSkipConnect(state: .reconnecting(attempt: 1, nextRetrySeconds: 2)))
        #expect(EngineClientConnectionPolicy.shouldSkipConnect(state: .deployRestarting(remainingSeconds: 3)))
        #expect(EngineClientConnectionPolicy.shouldDiscardExistingTransport(
            hasTransport: true,
            state: .connected
        ) == false)
    }
}
