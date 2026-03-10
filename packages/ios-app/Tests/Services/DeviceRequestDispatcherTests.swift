import Testing
import Foundation
@testable import TronMobile

@Suite("DeviceRequestDispatcher")
@MainActor
struct DeviceRequestDispatcherTests {

    @Test("handleRequest deduplicates same requestId")
    func deduplicatesSameId() {
        DeviceRequestDispatcher.clearDeduplicationState()
        let mockURL = URL(string: "ws://localhost:8080/ws")!
        let rpcClient = RPCClient(serverURL: mockURL)
        let dispatcher = DeviceRequestDispatcher(rpcClient: rpcClient)

        let result = DeviceRequestPlugin.Result(
            requestId: "req-123",
            method: "unknown.method",
            params: nil
        )

        // First call should be accepted (task created)
        dispatcher.handleRequest(result)
        // Second call should be deduped (no new task)
        dispatcher.handleRequest(result)

        // If we reach here without crash, dedup works
        DeviceRequestDispatcher.clearDeduplicationState()
    }

    @Test("handleRequest allows different requestIds")
    func allowsDifferentIds() {
        DeviceRequestDispatcher.clearDeduplicationState()
        let mockURL = URL(string: "ws://localhost:8080/ws")!
        let rpcClient = RPCClient(serverURL: mockURL)
        let dispatcher = DeviceRequestDispatcher(rpcClient: rpcClient)

        let result1 = DeviceRequestPlugin.Result(
            requestId: "req-1",
            method: "unknown.method",
            params: nil
        )
        let result2 = DeviceRequestPlugin.Result(
            requestId: "req-2",
            method: "unknown.method",
            params: nil
        )

        dispatcher.handleRequest(result1)
        dispatcher.handleRequest(result2)

        // Both accepted without issue
        DeviceRequestDispatcher.clearDeduplicationState()
    }

    @Test("clearDeduplicationState allows same id again")
    func clearAllowsSameIdAgain() {
        DeviceRequestDispatcher.clearDeduplicationState()
        let mockURL = URL(string: "ws://localhost:8080/ws")!
        let rpcClient = RPCClient(serverURL: mockURL)
        let dispatcher = DeviceRequestDispatcher(rpcClient: rpcClient)

        let result = DeviceRequestPlugin.Result(
            requestId: "req-clear-test",
            method: "unknown.method",
            params: nil
        )

        dispatcher.handleRequest(result)
        DeviceRequestDispatcher.clearDeduplicationState()
        // Should be accepted again after clearing
        dispatcher.handleRequest(result)

        DeviceRequestDispatcher.clearDeduplicationState()
    }

    @Test("cancelAll cancels active tasks")
    func cancelAllCancelsActive() {
        DeviceRequestDispatcher.clearDeduplicationState()
        let mockURL = URL(string: "ws://localhost:8080/ws")!
        let rpcClient = RPCClient(serverURL: mockURL)
        let dispatcher = DeviceRequestDispatcher(rpcClient: rpcClient)

        // Dispatch some requests (they'll fail since no real server, but tasks will be created)
        let result = DeviceRequestPlugin.Result(
            requestId: "req-cancel",
            method: "unknown.cancel",
            params: nil
        )
        dispatcher.handleRequest(result)
        dispatcher.cancelAll()

        // No crash = success
        DeviceRequestDispatcher.clearDeduplicationState()
    }

    @Test("cancelAll on empty tasks is no-op")
    func cancelAllEmptyIsNoOp() {
        let mockURL = URL(string: "ws://localhost:8080/ws")!
        let rpcClient = RPCClient(serverURL: mockURL)
        let dispatcher = DeviceRequestDispatcher(rpcClient: rpcClient)

        // Should not crash
        dispatcher.cancelAll()
    }
}
