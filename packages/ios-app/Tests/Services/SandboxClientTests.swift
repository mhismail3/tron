import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("SandboxClient Tests")
struct SandboxClientTests {

    @Test("listContainers throws when engineConnection is nil")
    func listContainersNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = SandboxClient(transport: transport)

        await #expect(throws: EngineClientError.self) {
            _ = try await client.listContainers()
        }
    }

    @Test("stopContainer throws when engineConnection is nil")
    func stopContainerNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = SandboxClient(transport: transport)

        await #expect(throws: EngineClientError.self) {
            _ = try await client.stopContainer(
                name: "test-container",
                idempotencyKey: .userAction("sandbox.stop.test")
            )
        }
    }

    @Test("startContainer throws when engineConnection is nil")
    func startContainerNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = SandboxClient(transport: transport)

        await #expect(throws: EngineClientError.self) {
            _ = try await client.startContainer(
                name: "test-container",
                idempotencyKey: .userAction("sandbox.start.test")
            )
        }
    }

    @Test("killContainer throws when engineConnection is nil")
    func killContainerNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = SandboxClient(transport: transport)

        await #expect(throws: EngineClientError.self) {
            _ = try await client.killContainer(
                name: "test-container",
                idempotencyKey: .userAction("sandbox.kill.test")
            )
        }
    }

    @Test("removeContainer throws when engineConnection is nil")
    func removeContainerNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = SandboxClient(transport: transport)

        await #expect(throws: EngineClientError.self) {
            _ = try await client.removeContainer(
                name: "test-container",
                idempotencyKey: .userAction("sandbox.remove.test")
            )
        }
    }
}
