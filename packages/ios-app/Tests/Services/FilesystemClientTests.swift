import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("FilesystemClient Tests")
struct FilesystemClientTests {

    @Test("listDirectory throws when transport is nil")
    func listDirectoryNoTransport() async {
        let client: FilesystemClient = {
            let transport = MockRPCTransport()
            return FilesystemClient(transport: transport)
        }()

        await #expect(throws: RPCClientError.self) {
            _ = try await client.listDirectory(path: "/tmp")
        }
    }

    @Test("listDirectory throws when webSocket is nil")
    func listDirectoryNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = FilesystemClient(transport: transport)

        await #expect(throws: RPCClientError.self) {
            _ = try await client.listDirectory(path: "/tmp")
        }
    }

    @Test("getHome throws when transport is nil")
    func getHomeNoTransport() async {
        let client: FilesystemClient = {
            let transport = MockRPCTransport()
            return FilesystemClient(transport: transport)
        }()

        await #expect(throws: RPCClientError.self) {
            _ = try await client.getHome()
        }
    }

    @Test("createDirectory throws when transport is nil")
    func createDirectoryNoTransport() async {
        let client: FilesystemClient = {
            let transport = MockRPCTransport()
            return FilesystemClient(transport: transport)
        }()

        await #expect(throws: RPCClientError.self) {
            _ = try await client.createDirectory(path: "/tmp/test")
        }
    }

    @Test("readFile throws when transport is nil")
    func readFileNoTransport() async {
        let client: FilesystemClient = {
            let transport = MockRPCTransport()
            return FilesystemClient(transport: transport)
        }()

        await #expect(throws: RPCClientError.self) {
            _ = try await client.readFile(path: "/tmp/test.txt")
        }
    }

    @Test("cloneRepository throws when transport is nil")
    func cloneRepositoryNoTransport() async {
        let client: FilesystemClient = {
            let transport = MockRPCTransport()
            return FilesystemClient(transport: transport)
        }()

        await #expect(throws: RPCClientError.self) {
            _ = try await client.cloneRepository(url: "https://github.com/test/repo", targetPath: "/tmp/repo")
        }
    }
}
