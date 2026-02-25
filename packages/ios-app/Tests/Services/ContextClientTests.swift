import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("ContextClient Tests")
struct ContextClientTests {

    @Test("getSnapshot throws when transport is nil")
    func getSnapshotNoTransport() async {
        let client: ContextClient = {
            let transport = MockRPCTransport()
            return ContextClient(transport: transport)
            // transport is deallocated here (weak reference)
        }()

        await #expect(throws: RPCClientError.self) {
            _ = try await client.getSnapshot(sessionId: "test-session")
        }
    }

    @Test("getSnapshot throws when webSocket is nil")
    func getSnapshotNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = ContextClient(transport: transport)

        await #expect(throws: RPCClientError.self) {
            _ = try await client.getSnapshot(sessionId: "test-session")
        }
    }

    @Test("getDetailedSnapshot throws when transport is nil")
    func getDetailedSnapshotNoTransport() async {
        let client: ContextClient = {
            let transport = MockRPCTransport()
            return ContextClient(transport: transport)
        }()

        await #expect(throws: RPCClientError.self) {
            _ = try await client.getDetailedSnapshot(sessionId: "test-session")
        }
    }

    @Test("clear throws when transport is nil")
    func clearNoTransport() async {
        let client: ContextClient = {
            let transport = MockRPCTransport()
            return ContextClient(transport: transport)
        }()

        await #expect(throws: RPCClientError.self) {
            _ = try await client.clear(sessionId: "test-session")
        }
    }

    @Test("compact throws when transport is nil")
    func compactNoTransport() async {
        let client: ContextClient = {
            let transport = MockRPCTransport()
            return ContextClient(transport: transport)
        }()

        await #expect(throws: RPCClientError.self) {
            _ = try await client.compact(sessionId: "test-session")
        }
    }
}
