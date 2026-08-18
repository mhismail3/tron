import Foundation
import Observation

@MainActor
protocol CustomModelConfigurationCoordinatorDelegate: AnyObject {
    func customModelConfigurationCoordinatorSurface(_ error: Error)
}

/// Owns disposable custom-model projections and validate-before-put mutation
/// admission. Gateway custom-model state remains canonical.
@MainActor
@Observable
final class CustomModelConfigurationCoordinator {
    static let requestTimeout: Duration = .seconds(30)

    private struct ValidateParams: Codable {
        let document: JSONValue
    }

    private struct PutParams: Codable {
        let document: JSONValue
        let commandId: String
    }

    private struct LoadAdmission: Equatable {
        let profileGeneration: Int
        let target: CustomModelTarget
        let targetGeneration: Int
    }

    private let client: GatewayClient
    private let mutationExecutor: ConfirmedMutationExecutor
    private let uuidSource: UUIDSource

    weak var delegate: (any CustomModelConfigurationCoordinatorDelegate)?

    private var modelsByTarget: [CustomModelTarget: JSONValue] = [:]
    private var loadGenerationByTarget: [CustomModelTarget: Int] = [:]
    private var mutationGenerationByTarget: [CustomModelTarget: Int] = [:]
    private var profileGeneration = 0

    private(set) var invalidationGeneration = 0

    init(
        client: GatewayClient,
        mutationExecutor: ConfirmedMutationExecutor,
        uuidSource: UUIDSource
    ) {
        self.client = client
        self.mutationExecutor = mutationExecutor
        self.uuidSource = uuidSource
    }

    func models(for target: CustomModelTarget) -> JSONValue? {
        modelsByTarget[target]
    }

    @discardableResult
    func load(target: CustomModelTarget) async -> Bool {
        let admission = beginLoad(target: target)
        do {
            let value = try await client.requestValue(
                "models.custom.get",
                EmptyParams(),
                timeout: Self.requestTimeout
            )
            guard admits(admission) else { return false }
            modelsByTarget[target] = value
            return true
        } catch {
            guard admits(admission) else { return false }
            delegate?.customModelConfigurationCoordinatorSurface(error)
            return false
        }
    }

    func replace(_ document: JSONValue, target: CustomModelTarget) async throws {
        let admittedProfileGeneration = profileGeneration
        let targetGeneration = (mutationGenerationByTarget[target] ?? 0) &+ 1
        mutationGenerationByTarget[target] = targetGeneration

        do {
            _ = try await client.requestValue(
                "models.custom.validate",
                ValidateParams(document: document),
                timeout: Self.requestTimeout
            )
        } catch {
            guard admitsMutation(
                profileGeneration: admittedProfileGeneration,
                target: target,
                targetGeneration: targetGeneration
            ) else { throw CancellationError() }
            throw error
        }
        try requireMutation(
            profileGeneration: admittedProfileGeneration,
            target: target,
            targetGeneration: targetGeneration
        )

        let commandID = uuidSource.next().uuidString
        let params = PutParams(document: document, commandId: commandID)
        do {
            _ = try await mutationExecutor.performValue(
                method: "models.custom.put",
                commandID: commandID
            ) {
                try await client.requestValue("models.custom.put", params, timeout: Self.requestTimeout)
            }
        } catch {
            guard admitsMutation(
                profileGeneration: admittedProfileGeneration,
                target: target,
                targetGeneration: targetGeneration
            ) else { throw CancellationError() }
            throw error
        }
        try requireMutation(
            profileGeneration: admittedProfileGeneration,
            target: target,
            targetGeneration: targetGeneration
        )
    }

    func noteCustomModelsChanged() {
        invalidationGeneration &+= 1
    }

    /// Synchronously rejects validate/put/load completions from the retired
    /// profile, including an A → B → A selection cycle.
    func clearProfile() {
        profileGeneration &+= 1
        loadGenerationByTarget = loadGenerationByTarget.mapValues { $0 &+ 1 }
        mutationGenerationByTarget = mutationGenerationByTarget.mapValues { $0 &+ 1 }
        modelsByTarget.removeAll()
    }

    private func beginLoad(target: CustomModelTarget) -> LoadAdmission {
        let targetGeneration = (loadGenerationByTarget[target] ?? 0) &+ 1
        loadGenerationByTarget[target] = targetGeneration
        return LoadAdmission(
            profileGeneration: profileGeneration,
            target: target,
            targetGeneration: targetGeneration
        )
    }

    private func admits(_ admission: LoadAdmission) -> Bool {
        profileGeneration == admission.profileGeneration
            && loadGenerationByTarget[admission.target] == admission.targetGeneration
    }

    private func admitsMutation(
        profileGeneration admittedProfileGeneration: Int,
        target: CustomModelTarget,
        targetGeneration: Int
    ) -> Bool {
        profileGeneration == admittedProfileGeneration
            && mutationGenerationByTarget[target] == targetGeneration
    }

    private func requireMutation(
        profileGeneration admittedProfileGeneration: Int,
        target: CustomModelTarget,
        targetGeneration: Int
    ) throws {
        try Task.checkCancellation()
        guard admitsMutation(
            profileGeneration: admittedProfileGeneration,
            target: target,
            targetGeneration: targetGeneration
        ) else { throw CancellationError() }
    }

    #if HOSTED_TEST
    func installHostedModels(_ value: JSONValue?, for target: CustomModelTarget) {
        modelsByTarget[target] = value
    }

    func setHostedInvalidationGeneration(_ generation: Int) {
        invalidationGeneration = generation
    }
    #endif
}
