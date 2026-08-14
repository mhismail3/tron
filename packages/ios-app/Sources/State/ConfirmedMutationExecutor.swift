import Foundation

/// Resolves one command mutation against the exact gateway lifecycle generation
/// that admitted it. A possibly-sent command is replayed only after the Gateway
/// authoritatively reports that the stable command ID is missing.
@MainActor
final class ConfirmedMutationExecutor {
    private struct CommandStatusParams: Codable { let method, commandId: String }
    private struct CommandStatusResponse: Decodable { let status: String; let result: JSONValue? }

    private let client: GatewayClient
    private let lifecycle: GatewayLifecycleCoordinator
    private let clock: MonotonicClock
    private let performanceSignposts: any PerformanceSignposting

    init(
        client: GatewayClient,
        lifecycle: GatewayLifecycleCoordinator,
        clock: MonotonicClock,
        performanceSignposts: any PerformanceSignposting
    ) {
        self.client = client
        self.lifecycle = lifecycle
        self.clock = clock
        self.performanceSignposts = performanceSignposts
    }

    func perform<Response: Codable>(
        method: String,
        commandID: String,
        send: () async throws -> Response
    ) async throws -> Response {
        let value = try await performValue(method: method, commandID: commandID) {
            try JSONValue.encode(try await send())
        }
        return try value.decode(Response.self)
    }

    func performValue(
        method: String,
        commandID: String,
        send: () async throws -> JSONValue
    ) async throws -> JSONValue {
        guard let admission = lifecycle.generationAdmission else { throw CancellationError() }
        try lifecycle.require(admission)
        do {
            let value = try await send()
            try lifecycle.require(admission)
            return value
        } catch let uncertain as GatewayPossiblySentError {
            let original = uncertain.failure
            if Task.isCancelled || !lifecycle.admits(admission) {
                throw Self.uncertainMutationOutcome(
                    method: method,
                    commandID: commandID,
                    lastFailure: original
                )
            }
            let interval = performanceSignposts.begin(.receiptResolution)
            var result = PerformanceResult.failure
            defer {
                if Task.isCancelled { result = .cancelled }
                performanceSignposts.end(interval, result: result, metrics: .none)
            }
            let deadline = clock.now() + .seconds(90)
            var lastFailure: GatewayFailure = original
            while clock.now() < deadline {
                if Task.isCancelled || !lifecycle.admits(admission) {
                    result = .cancelled
                    throw Self.uncertainMutationOutcome(
                        method: method,
                        commandID: commandID,
                        lastFailure: lastFailure
                    )
                }
                guard await lifecycle.waitForConnected(
                    until: deadline,
                    admission: admission
                ) else { break }
                do {
                    let status: CommandStatusResponse = try await client.request(
                        "command.status",
                        CommandStatusParams(method: method, commandId: commandID),
                        timeout: .seconds(10)
                    )
                    try lifecycle.require(admission)
                    switch status.status {
                    case "completed":
                        guard let resolved = status.result else {
                            throw GatewayFailure(
                                code: "invalid_response",
                                message: "The completed command did not include a result.",
                                retryable: false,
                                details: nil
                            )
                        }
                        result = .success
                        return resolved
                    case "missing":
                        do {
                            guard lifecycle.admits(admission),
                                  Self.admitsReplay(taskIsCancelled: Task.isCancelled) else {
                                throw Self.uncertainMutationOutcome(
                                    method: method,
                                    commandID: commandID,
                                    lastFailure: lastFailure
                                )
                            }
                            let resolved = try await send()
                            try lifecycle.require(admission)
                            result = .success
                            return resolved
                        } catch let retry as GatewayPossiblySentError {
                            lastFailure = retry.failure
                        }
                    case "pending":
                        break
                    default:
                        throw GatewayFailure(
                            code: "invalid_response",
                            message: "Tron returned an unknown command status.",
                            retryable: false,
                            details: nil
                        )
                    }
                } catch let failure as GatewayPossiblySentError {
                    lastFailure = failure.failure
                }
                do { try await clock.sleep(.milliseconds(250)) }
                catch { break }
            }
            if Task.isCancelled { result = .cancelled }
            throw Self.uncertainMutationOutcome(
                method: method,
                commandID: commandID,
                lastFailure: lastFailure
            )
        }
    }

    static func admitsReplay(taskIsCancelled: Bool) -> Bool {
        !taskIsCancelled
    }

    private static func uncertainMutationOutcome(
        method: String,
        commandID: String,
        lastFailure: GatewayFailure
    ) -> GatewayFailure {
        GatewayFailure(
            code: "outcome_unknown",
            message: "Tron may have accepted this command. Verify the authoritative state before trying again.",
            retryable: false,
            details: .object([
                "commandId": .string(commandID),
                "method": .string(method),
                "lastFailure": .string(lastFailure.message),
            ])
        )
    }
}
