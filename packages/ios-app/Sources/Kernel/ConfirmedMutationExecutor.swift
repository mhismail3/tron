import Foundation
import TronMobileCore

enum ConfirmedMutationConnectionPolicy {
    static let initialConnectionDeadline: Duration = .seconds(8)
}

@MainActor
final class ConfirmedMutationExecutor {
    private static let receiptResolutionDeadline: Duration = .seconds(90)
    private static let receiptStatusPollInterval: Duration = .milliseconds(250)

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
        replayAdmission: @escaping @MainActor () -> Bool = { true },
        send: () async throws -> Response
    ) async throws -> Response {
        let value = try await performValue(
            method: method,
            commandID: commandID,
            replayAdmission: replayAdmission
        ) {
            try JSONValue.encode(try await send())
        }
        return try value.decode(Response.self)
    }

    func performValue(
        method: String,
        commandID: String,
        replayAdmission: @escaping @MainActor () -> Bool = { true },
        replayMissingReceipt: Bool = true,
        send: () async throws -> JSONValue
    ) async throws -> JSONValue {
        guard let admission = lifecycle.generationAdmission else { throw CancellationError() }
        let profileID = lifecycle.selectedProfileID
        try lifecycle.require(admission)
        guard await lifecycle.waitForConnected(
            until: clock.now() + ConfirmedMutationConnectionPolicy.initialConnectionDeadline,
            admission: admission
        ) else {
            throw GatewayDefinitelyNotSentError(failure: GatewayFailure(
                code: "disconnected",
                message: "The Mac gateway is still reconnecting. Your change was not sent.",
                retryable: true,
                details: nil
            ))
        }

        var retriedBeforeTransmission = false
        while true {
            do {
                return try await send()
            } catch let definitelyNotSent as GatewayDefinitelyNotSentError where
                !retriedBeforeTransmission {
                retriedBeforeTransmission = true
                guard await lifecycle.waitForConnected(
                    until: clock.now() + ConfirmedMutationConnectionPolicy.initialConnectionDeadline,
                    admission: admission
                ) else { throw definitelyNotSent.failure }
                continue
            } catch let failure as GatewayFailure where failure.code == "response_too_large" {
                throw Self.uncertainMutationOutcome(method: method, commandID: commandID, lastFailure: failure)
            } catch let uncertain as GatewayPossiblySentError {
            let original = uncertain.failure
            if Task.isCancelled || lifecycle.currentLifecycleGeneration != admission.generation || lifecycle.selectedProfileID != profileID {
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
            let deadline = clock.now() + Self.receiptResolutionDeadline
            var lastFailure: GatewayFailure = original
            while clock.now() < deadline {
                if Task.isCancelled || lifecycle.currentLifecycleGeneration != admission.generation || lifecycle.selectedProfileID != profileID {
                    result = .cancelled
                    throw Self.uncertainMutationOutcome(
                        method: method,
                        commandID: commandID,
                        lastFailure: lastFailure
                    )
                }
                guard lifecycle.admits(admission) else {
                    do { try await clock.sleep(Self.receiptStatusPollInterval) }
                    catch { break }
                    continue
                }
                guard await lifecycle.waitForConnected(until: deadline, admission: admission) else {
                    if !Task.isCancelled, !lifecycle.admits(admission),
                       lifecycle.currentLifecycleGeneration == admission.generation,
                       lifecycle.selectedProfileID == profileID { continue }
                    break
                }
                guard let statusAdmission = lifecycle.admission else { continue }
                do {
                    let status: CommandStatusResponse
                    do {
                        status = try await client.request("command.status", CommandStatusParams(method: method, commandId: commandID))
                        try lifecycle.require(statusAdmission)
                    } catch is CancellationError {
                        guard !Task.isCancelled,
                              lifecycle.currentLifecycleGeneration == admission.generation,
                              lifecycle.selectedProfileID == profileID else {
                            throw Self.uncertainMutationOutcome(method: method, commandID: commandID, lastFailure: lastFailure)
                        }
                        continue
                    }
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
                            guard replayMissingReceipt else {
                                throw Self.uncertainMutationOutcome(
                                    method: method,
                                    commandID: commandID,
                                    lastFailure: GatewayFailure(code: "receipt_missing", message: "The original command has no receipt. Do not submit a replacement.", retryable: false, details: nil)
                                )
                            }
                            guard replayAdmission() else {
                                result = .cancelled
                                throw CancellationError()
                            }
                            let resolved = try await send()
                            try Task.checkCancellation()
                            guard lifecycle.currentLifecycleGeneration == admission.generation,
                                  lifecycle.selectedProfileID == profileID else { throw CancellationError() }
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
                } catch let failure as GatewayDefinitelyNotSentError {
                    lastFailure = failure.failure
                } catch let failure as GatewayFailure where failure.code == "response_too_large" {
                    throw Self.uncertainMutationOutcome(method: method, commandID: commandID, lastFailure: failure)
                }
                do { try await clock.sleep(Self.receiptStatusPollInterval) }
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
    }

    enum ReceiptResolution: Equatable {
        case completed(JSONValue)
        case missing
    }

    func resolveReceipt(method: String, commandID: String) async throws -> ReceiptResolution {
        let unavailable = GatewayFailure(code: "disconnected", message: "Reconnect to the original Mac to check this command.", retryable: true, details: nil)
        guard let admission = lifecycle.generationAdmission,
              await lifecycle.waitForConnected(until: clock.now() + ConfirmedMutationConnectionPolicy.initialConnectionDeadline, admission: admission),
              let statusAdmission = lifecycle.admission else {
            throw Self.uncertainMutationOutcome(method: method, commandID: commandID, lastFailure: unavailable)
        }
        do {
            let status: CommandStatusResponse = try await client.request("command.status", CommandStatusParams(method: method, commandId: commandID))
            try lifecycle.require(statusAdmission)
            switch status.status {
            case "completed":
                guard let result = status.result else {
                    throw Self.uncertainMutationOutcome(method: method, commandID: commandID,
                        lastFailure: Self.noCompletedReceipt)
                }
                return .completed(result)
            case "missing":
                return .missing
            default:
                throw Self.uncertainMutationOutcome(method: method, commandID: commandID,
                    lastFailure: Self.noCompletedReceipt)
            }
        } catch let failure as GatewayPossiblySentError {
            throw Self.uncertainMutationOutcome(method: method, commandID: commandID, lastFailure: failure.failure)
        } catch is CancellationError {
            throw Self.uncertainMutationOutcome(method: method, commandID: commandID, lastFailure: unavailable)
        }
    }

    private static let noCompletedReceipt = GatewayFailure(
        code: "receipt_unavailable",
        message: "The original command has no completed receipt. Do not submit a replacement.",
        retryable: false,
        details: nil
    )

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
