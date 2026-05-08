import Foundation

/// Client for sandbox container management engine capabilities.
/// Handles listing, starting, stopping, killing, and removing containers.
final class SandboxClient: EngineDomainClient {

    /// List all tracked containers with live status
    func listContainers() async throws -> SandboxListResult {
        _ = try requireTransport().requireConnection()

        return try await invokeRead(
            "sandbox::list_containers",
            EmptyParams()
        )
    }

    /// Stop a running container
    func stopContainer(name: String, idempotencyKey: EngineIdempotencyKey) async throws -> ContainerActionResult {
        _ = try requireTransport().requireConnection()

        return try await invokeWrite(
            "sandbox::stop_container",
            ContainerActionParams(name: name),
            idempotencyKey: idempotencyKey
        )
    }

    /// Start a stopped container
    func startContainer(name: String, idempotencyKey: EngineIdempotencyKey) async throws -> ContainerActionResult {
        _ = try requireTransport().requireConnection()

        return try await invokeWrite(
            "sandbox::start_container",
            ContainerActionParams(name: name),
            idempotencyKey: idempotencyKey
        )
    }

    /// Kill a container (SIGKILL)
    func killContainer(name: String, idempotencyKey: EngineIdempotencyKey) async throws -> ContainerActionResult {
        _ = try requireTransport().requireConnection()

        return try await invokeWrite(
            "sandbox::kill_container",
            ContainerActionParams(name: name),
            idempotencyKey: idempotencyKey
        )
    }

    /// Remove a container and delete its metadata
    func removeContainer(name: String, idempotencyKey: EngineIdempotencyKey) async throws -> ContainerActionResult {
        _ = try requireTransport().requireConnection()

        return try await invokeWrite(
            "sandbox::remove_container",
            ContainerActionParams(name: name),
            idempotencyKey: idempotencyKey
        )
    }
}
