import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("SandboxClient Tests")
struct SandboxClientTests {

    @Test("listContainers throws when webSocket is nil")
    func listContainersNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = SandboxClient(transport: transport)

        await #expect(throws: RPCClientError.self) {
            _ = try await client.listContainers()
        }
    }

    @Test("stopContainer throws when webSocket is nil")
    func stopContainerNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = SandboxClient(transport: transport)

        await #expect(throws: RPCClientError.self) {
            _ = try await client.stopContainer(name: "test-container")
        }
    }

    @Test("startContainer throws when webSocket is nil")
    func startContainerNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = SandboxClient(transport: transport)

        await #expect(throws: RPCClientError.self) {
            _ = try await client.startContainer(name: "test-container")
        }
    }

    @Test("killContainer throws when webSocket is nil")
    func killContainerNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = SandboxClient(transport: transport)

        await #expect(throws: RPCClientError.self) {
            _ = try await client.killContainer(name: "test-container")
        }
    }

    @Test("removeContainer throws when webSocket is nil")
    func removeContainerNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = SandboxClient(transport: transport)

        await #expect(throws: RPCClientError.self) {
            _ = try await client.removeContainer(name: "test-container")
        }
    }
}
