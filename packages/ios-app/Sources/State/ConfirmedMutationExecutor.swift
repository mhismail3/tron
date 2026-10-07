import Foundation
import TronMobileCore

enum ConfirmedMutationConnectionPolicy {
    /// Pre-transmission waiting preserves single-send ownership during a short
    /// transport handoff.
    static let initialConnectionDeadline: Duration = .seconds(8)
}

/// Admits a command on one gateway lifecycle generation. A terminal response
/// owns completion; uncertain outcomes resolve through the stable command ID.
@MainActor
final class ConfirmedMutationExecutor {
    // Keep accepted-but-uncertain commands resolvable without polling forever.
    private static let receiptResolutionDeadline: Duration = .seconds(90)
    // Pending receipts need bounded status polling without a request storm.
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
        replayMissingReceipt: Bool = true,
        send: () async throws -> Response
    ) async throws -> Response {
        let value = try await performValue(
            method: method,
            commandID: commandID,
            replayAdmission: replayAdmission,
            replayMissingReceipt: replayMissingReceipt
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
            } catch is CancellationError {
                // Once send is invoked the request may have left the client even
                // if cancellation wins before its response is observed.
                throw Self.uncertainMutationOutcome(
                    method: method,
                    commandID: commandID,
                    lastFailure: GatewayFailure(code: "cancelled_after_send", message: "The mutation response was cancelled after transmission may have started.", retryable: true, details: nil)
                )
            } catch let definitelyNotSent as GatewayDefinitelyNotSentError where
                !retriedBeforeTransmission {
                // Local non-Codable provenance proves that no request byte left
                // the queued client state. A wire GatewayFailure with the same
                // code can never authorize this retry.
                retriedBeforeTransmission = true
                guard await lifecycle.waitForConnected(
                    until: clock.now() + ConfirmedMutationConnectionPolicy.initialConnectionDeadline,
                    admission: admission
                ) else { throw definitelyNotSent.failure }
                continue
            } catch let failure as GatewayFailure where failure.code == "response_too_large" {
                // Projection rejection is not command rejection: execution may
                // already have settled in its receipt owner. Never restore a
                // send as definitely failed or replay an unrepresentable result.
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
                // Suspension retires the socket, not an accepted receipt. Wait
                // inside this owner's existing bound; never transmit in background.
                guard lifecycle.admits(admission) else {
                    do { try await clock.sleep(Self.receiptStatusPollInterval) }
                    catch { break }
                    continue
                }
                guard await lifecycle.waitForConnected(until: deadline, admission: admission) else {
                    // A background handoff may resume in this same destination;
                    // an active unauthorized/unpaired stop cannot make progress.
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
                        // Only the exact receipt read is disposable. Cancellation
                        // from replay refusal below must retain its terminal meaning.
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
                            // Definite success is no longer a disposable read:
                            // same-authority suspension can retire its socket,
                            // but cancellation or authority replacement cannot
                            // publish it into a successor command namespace.
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
                    // Socket retirement can also win before this disposable read
                    // is emitted. It says nothing about the accepted command.
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

    /// Explicit reconciliation of an already dispatched command. This path
    /// only queries its receipt; missing/pending never authorizes a new send.
    func resolveValue(method: String, commandID: String) async throws -> JSONValue {
        let unavailable = GatewayFailure(code: "disconnected", message: "Reconnect to the original Mac to check this command.", retryable: true, details: nil)
        guard let admission = lifecycle.generationAdmission,
              await lifecycle.waitForConnected(until: clock.now() + ConfirmedMutationConnectionPolicy.initialConnectionDeadline, admission: admission),
              let statusAdmission = lifecycle.admission else {
            throw Self.uncertainMutationOutcome(method: method, commandID: commandID, lastFailure: unavailable)
        }
        do {
            let status: CommandStatusResponse = try await client.request("command.status", CommandStatusParams(method: method, commandId: commandID))
            try lifecycle.require(statusAdmission)
            guard status.status == "completed", let result = status.result else {
                throw Self.uncertainMutationOutcome(method: method, commandID: commandID,
                    lastFailure: GatewayFailure(code: "receipt_unavailable", message: "The original command has no completed receipt. Do not submit a replacement.", retryable: false, details: nil))
            }
            return result
        } catch let failure as GatewayPossiblySentError {
            throw Self.uncertainMutationOutcome(method: method, commandID: commandID, lastFailure: failure.failure)
        } catch is CancellationError {
            throw Self.uncertainMutationOutcome(method: method, commandID: commandID, lastFailure: unavailable)
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
