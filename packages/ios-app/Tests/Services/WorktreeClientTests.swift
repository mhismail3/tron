import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("WorktreeClient Tests")
struct WorktreeClientTests {

    @Test("getStatus throws when engineConnection is nil")
    func getStatusNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = WorktreeClient(transport: transport)

        await #expect(throws: EngineClientError.self) {
            _ = try await client.getStatus(sessionId: "test-session")
        }
    }

    @Test("commit throws when engineConnection is nil")
    func commitNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = WorktreeClient(transport: transport)

        await #expect(throws: EngineClientError.self) {
            _ = try await client.commit(
                sessionId: "test-session",
                message: "test commit",
                stageAll: true,
                idempotencyKey: .userAction("worktree.commit.test")
            )
        }
    }

    @Test("listSessionBranches throws when engineConnection is nil")
    func listSessionBranchesNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = WorktreeClient(transport: transport)

        await #expect(throws: EngineClientError.self) {
            _ = try await client.listSessionBranches(sessionId: "test-session")
        }
    }

    @Test("deleteBranch throws when engineConnection is nil")
    func deleteBranchNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = WorktreeClient(transport: transport)

        await #expect(throws: EngineClientError.self) {
            _ = try await client.deleteBranch(
                sessionId: "test-session",
                branch: "feature/test",
                idempotencyKey: .userAction("worktree.deleteBranch.test")
            )
        }
    }

    @Test("pruneBranches throws when engineConnection is nil")
    func pruneBranchesNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = WorktreeClient(transport: transport)

        await #expect(throws: EngineClientError.self) {
            _ = try await client.pruneBranches(
                sessionId: "test-session",
                idempotencyKey: .userAction("worktree.pruneBranches.test")
            )
        }
    }

    @Test("getCommittedDiff throws when engineConnection is nil")
    func getCommittedDiffNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = WorktreeClient(transport: transport)

        await #expect(throws: EngineClientError.self) {
            _ = try await client.getCommittedDiff(sessionId: "test-session")
        }
    }

    @Test("getWorkingDirectoryDiff throws when engineConnection is nil")
    func getWorkingDirectoryDiffNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = WorktreeClient(transport: transport)

        await #expect(throws: EngineClientError.self) {
            _ = try await client.getWorkingDirectoryDiff(sessionId: "test-session")
        }
    }
}
