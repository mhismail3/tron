import Foundation
import Observation
import TronMobileCore

struct HomeDesignationReceipt: Codable, Equatable, Sendable {
    let homeId: String
    let sessionId: String
    let generation: Int
}

/// Owns Home's one accepted profile mutation and resolves its Gateway receipt.
@MainActor
@Observable
final class HomeDesignationCoordinator {
    private struct Params: Codable { let commandId: String }

    private(set) var isDesignating = false
    private(set) var hasUnresolvedCommand = false
    @ObservationIgnored private var unresolvedCommand: (profileID: String, commandID: String)?
    @ObservationIgnored private var operationGeneration: UInt64 = 0
    @ObservationIgnored private let client: GatewayClient
    @ObservationIgnored private let lifecycle: GatewayLifecycleCoordinator
    @ObservationIgnored private let mutationExecutor: ConfirmedMutationExecutor
    @ObservationIgnored private let uuidSource: UUIDSource

    init(
        client: GatewayClient,
        lifecycle: GatewayLifecycleCoordinator,
        mutationExecutor: ConfirmedMutationExecutor,
        uuidSource: UUIDSource
    ) {
        self.client = client
        self.lifecycle = lifecycle
        self.mutationExecutor = mutationExecutor
        self.uuidSource = uuidSource
    }

    func ownsUnresolvedCommand(profileID: String) -> Bool {
        unresolvedCommand?.profileID == profileID
    }

    func designate(profileID: String) async throws -> HomeDesignationReceipt {
        guard !isDesignating else {
            throw GatewayFailure(
                code: "conflict",
                message: "Home designation is already in progress.",
                retryable: false,
                details: nil
            )
        }
        guard lifecycle.selectedProfileID == profileID,
              let admission = lifecycle.generationAdmission,
              lifecycle.gatewayInfo?.capabilities.contains("home.v1") == true else {
            throw CancellationError()
        }
        if let unresolvedCommand {
            guard unresolvedCommand.profileID == profileID else {
                throw GatewayFailure(code: "outcome_unknown", message: "Resolve the pending Home command on its original Gateway before starting another.", retryable: false, details: nil)
            }
            operationGeneration &+= 1
            let operation = operationGeneration
            isDesignating = true
            defer { if operationGeneration == operation { isDesignating = false } }
            let value = try await mutationExecutor.resolveValue(method: "home.designate", commandID: unresolvedCommand.commandID)
            let receipt = try value.decode(HomeDesignationReceipt.self)
            guard lifecycle.selectedProfileID == profileID,
                  lifecycle.currentLifecycleGeneration == admission.generation else { throw CancellationError() }
            self.unresolvedCommand = nil
            hasUnresolvedCommand = false
            return receipt
        }
        operationGeneration &+= 1
        let operation = operationGeneration
        isDesignating = true
        defer {
            if operationGeneration == operation { isDesignating = false }
        }

        let commandID = uuidSource.next().uuidString
        let receipt: HomeDesignationReceipt
        do {
            receipt = try await mutationExecutor.perform(
                method: "home.designate",
                commandID: commandID,
                replayAdmission: { [weak self] in
                    guard let self else { return false }
                    return self.lifecycle.selectedProfileID == profileID
                        && self.lifecycle.currentLifecycleGeneration == admission.generation
                        && self.lifecycle.gatewayInfo?.capabilities.contains("home.v1") == true
                },
                replayMissingReceipt: false
            ) {
                try await client.request("home.designate", Params(commandId: commandID))
            }
        } catch let failure as GatewayFailure where failure.code == "outcome_unknown" {
            unresolvedCommand = (profileID, commandID)
            hasUnresolvedCommand = true
            throw failure
        } catch let definitelyNotSent as GatewayDefinitelyNotSentError {
            // The executor retains local transmission provenance; a new explicit
            // attempt is safe because this command never reached the Gateway.
            throw definitelyNotSent.failure
        }
        guard lifecycle.selectedProfileID == profileID,
              lifecycle.currentLifecycleGeneration == admission.generation else {
            throw CancellationError()
        }
        return receipt
    }
}
