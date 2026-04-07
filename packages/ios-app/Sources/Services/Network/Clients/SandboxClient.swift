import Foundation

/// Client for sandbox container management RPC methods.
/// Handles listing, starting, stopping, killing, and removing containers.
final class SandboxClient: RPCDomainClient {

    /// List all tracked containers with live status
    func listContainers() async throws -> SandboxListResult {
        let ws = try requireTransport().requireConnection()

        return try await ws.send(
            method: "sandbox.listContainers",
            params: EmptyParams()
        )
    }

    /// Stop a running container
    func stopContainer(name: String) async throws -> ContainerActionResult {
        let ws = try requireTransport().requireConnection()

        return try await ws.send(
            method: "sandbox.stopContainer",
            params: ContainerActionParams(name: name)
        )
    }

    /// Start a stopped container
    func startContainer(name: String) async throws -> ContainerActionResult {
        let ws = try requireTransport().requireConnection()

        return try await ws.send(
            method: "sandbox.startContainer",
            params: ContainerActionParams(name: name)
        )
    }

    /// Kill a container (SIGKILL)
    func killContainer(name: String) async throws -> ContainerActionResult {
        let ws = try requireTransport().requireConnection()

        return try await ws.send(
            method: "sandbox.killContainer",
            params: ContainerActionParams(name: name)
        )
    }

    /// Remove a container and delete its metadata
    func removeContainer(name: String) async throws -> ContainerActionResult {
        let ws = try requireTransport().requireConnection()

        return try await ws.send(
            method: "sandbox.removeContainer",
            params: ContainerActionParams(name: name)
        )
    }
}
