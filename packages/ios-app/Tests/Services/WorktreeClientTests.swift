import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("WorktreeClient Tests")
struct WorktreeClientTests {

    @Test("getStatus throws when webSocket is nil")
    func getStatusNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = WorktreeClient(transport: transport)

        await #expect(throws: RPCClientError.self) {
            _ = try await client.getStatus(sessionId: "test-session")
        }
    }

    @Test("commit throws when webSocket is nil")
    func commitNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = WorktreeClient(transport: transport)

        await #expect(throws: RPCClientError.self) {
            _ = try await client.commit(sessionId: "test-session", message: "test commit")
        }
    }

    @Test("listSessionBranches throws when webSocket is nil")
    func listSessionBranchesNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = WorktreeClient(transport: transport)

        await #expect(throws: RPCClientError.self) {
            _ = try await client.listSessionBranches(sessionId: "test-session")
        }
    }

    @Test("deleteBranch throws when webSocket is nil")
    func deleteBranchNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = WorktreeClient(transport: transport)

        await #expect(throws: RPCClientError.self) {
            _ = try await client.deleteBranch(sessionId: "test-session", branch: "feature/test")
        }
    }

    @Test("pruneBranches throws when webSocket is nil")
    func pruneBranchesNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = WorktreeClient(transport: transport)

        await #expect(throws: RPCClientError.self) {
            _ = try await client.pruneBranches(sessionId: "test-session")
        }
    }

    @Test("getCommittedDiff throws when webSocket is nil")
    func getCommittedDiffNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = WorktreeClient(transport: transport)

        await #expect(throws: RPCClientError.self) {
            _ = try await client.getCommittedDiff(sessionId: "test-session")
        }
    }

    @Test("getWorkingDirectoryDiff throws when webSocket is nil")
    func getWorkingDirectoryDiffNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = WorktreeClient(transport: transport)

        await #expect(throws: RPCClientError.self) {
            _ = try await client.getWorkingDirectoryDiff(sessionId: "test-session")
        }
    }
}
