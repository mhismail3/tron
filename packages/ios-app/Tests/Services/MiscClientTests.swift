import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("MiscClient Tests")
struct MiscClientTests {

    @Test("ping throws when transport is nil")
    func pingNoTransport() async {
        let client: MiscClient = {
            let transport = MockRPCTransport()
            return MiscClient(transport: transport)
        }()

        await #expect(throws: RPCClientError.self) {
            try await client.ping()
        }
    }

    @Test("getSystemInfo throws when transport is nil")
    func getSystemInfoNoTransport() async {
        let client: MiscClient = {
            let transport = MockRPCTransport()
            return MiscClient(transport: transport)
        }()

        await #expect(throws: RPCClientError.self) {
            _ = try await client.getSystemInfo()
        }
    }

    @Test("getSystemInfo throws when webSocket is nil")
    func getSystemInfoNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = MiscClient(transport: transport)

        await #expect(throws: RPCClientError.self) {
            _ = try await client.getSystemInfo()
        }
    }

    @Test("listSkills throws when transport is nil")
    func listSkillsNoTransport() async {
        let client: MiscClient = {
            let transport = MockRPCTransport()
            return MiscClient(transport: transport)
        }()

        await #expect(throws: RPCClientError.self) {
            _ = try await client.listSkills()
        }
    }

    @Test("searchMemory throws when transport is nil")
    func searchMemoryNoTransport() async {
        let client: MiscClient = {
            let transport = MockRPCTransport()
            return MiscClient(transport: transport)
        }()

        await #expect(throws: RPCClientError.self) {
            _ = try await client.searchMemory(query: "test")
        }
    }

    @Test("listContainers throws when transport is nil")
    func listContainersNoTransport() async {
        let client: MiscClient = {
            let transport = MockRPCTransport()
            return MiscClient(transport: transport)
        }()

        await #expect(throws: RPCClientError.self) {
            _ = try await client.listContainers()
        }
    }

    @Test("listTasks throws when transport is nil")
    func listTasksNoTransport() async {
        let client: MiscClient = {
            let transport = MockRPCTransport()
            return MiscClient(transport: transport)
        }()

        await #expect(throws: RPCClientError.self) {
            _ = try await client.listTasks()
        }
    }

    @Test("exportLogs throws when transport is nil")
    func exportLogsNoTransport() async {
        let client: MiscClient = {
            let transport = MockRPCTransport()
            return MiscClient(transport: transport)
        }()

        await #expect(throws: RPCClientError.self) {
            _ = try await client.exportLogs(content: "test log content")
        }
    }
}
