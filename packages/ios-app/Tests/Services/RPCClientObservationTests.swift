import Testing
import Foundation
@testable import TronMobile

// MARK: - RPCClient Observation Tests

@Suite("RPCClient Observation")
@MainActor
struct RPCClientObservationTests {

    @Test("Initial connection state is disconnected")
    func testInitialState() {
        let rpc = RPCClient(serverURL: URL(string: "ws://localhost:8080/ws")!)
        #expect(rpc.connectionState == .disconnected)
    }

    @Test("Disconnect cancels observation and resets state")
    func testDisconnectResetsState() async {
        let rpc = RPCClient(serverURL: URL(string: "ws://localhost:8080/ws")!)
        await rpc.disconnect()
        #expect(rpc.connectionState == .disconnected)
    }

    @Test("RPCClient can be deallocated without crash")
    func testDeallocationSafety() async {
        var rpc: RPCClient? = RPCClient(serverURL: URL(string: "ws://localhost:8080/ws")!)
        #expect(rpc != nil)
        rpc = nil
        #expect(rpc == nil)
    }

    @Test("Multiple disconnect calls are safe")
    func testMultipleDisconnects() async {
        let rpc = RPCClient(serverURL: URL(string: "ws://localhost:8080/ws")!)
        await rpc.disconnect()
        await rpc.disconnect()
        #expect(rpc.connectionState == .disconnected)
    }
}
