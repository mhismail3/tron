import Foundation
import Observation

enum PackageMutationAction: String, Sendable {
    case install
    case update
    case remove
}

@MainActor
protocol PackageConfigurationCoordinatorDelegate: AnyObject {
    func packageConfigurationCoordinatorSurface(_ error: Error)
}

/// Owns disposable package inventory/update projections and exact-target
/// package request admission. Gateway package state remains canonical.
@MainActor
@Observable
final class PackageConfigurationCoordinator {
    static let listTimeout: Duration = .seconds(120)
    static let checkUpdatesTimeout: Duration = .seconds(180)
    static let mutationTimeout: Duration = .seconds(300)

    private struct TargetParams: Codable {
        let cwd: String?
    }

    private struct UpdateResponse: Decodable {
        let updates: [PackageUpdate]
    }

    private struct MutationParams: Codable {
        let source: String?
        let local: Bool
        let cwd: String?
        let commandId: String
    }

    private struct TargetAdmission: Equatable {
        let profileGeneration: Int
        let target: PackageConfigurationTarget
        let targetGeneration: Int
    }

    private let client: GatewayClient
    private let mutationExecutor: ConfirmedMutationExecutor
    private let uuidSource: UUIDSource

    weak var delegate: (any PackageConfigurationCoordinatorDelegate)?

    private var inventoryByTarget: [PackageConfigurationTarget: PackageInventory] = [:]
    private var updatesByTarget: [PackageConfigurationTarget: [PackageUpdate]] = [:]
    private var loadGenerationByTarget: [PackageConfigurationTarget: Int] = [:]
    private var updateGenerationByTarget: [PackageConfigurationTarget: Int] = [:]
    private var mutationGenerationByTarget: [PackageConfigurationTarget: Int] = [:]
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

    func inventory(for target: PackageConfigurationTarget) -> PackageInventory? {
        inventoryByTarget[target]
    }

    func updates(for target: PackageConfigurationTarget) -> [PackageUpdate] {
        updatesByTarget[target] ?? []
    }

    @discardableResult
    func load(target: PackageConfigurationTarget) async -> Bool {
        await load(target: target, requiring: nil)
    }

    private func load(
        target: PackageConfigurationTarget,
        requiring mutationAdmission: TargetAdmission?
    ) async -> Bool {
        let admission = beginAdmission(target: target, generations: &loadGenerationByTarget)
        do {
            let inventory: PackageInventory = try await client.request(
                "packages.list",
                TargetParams(cwd: target.cwd),
                timeout: Self.listTimeout
            )
            guard admits(admission, generations: loadGenerationByTarget),
                  mutationAdmission.map({ admits($0, generations: mutationGenerationByTarget) }) ?? true else {
                return false
            }
            let admitted = try PackageCatalogPolicy.admit(inventory)
            inventoryByTarget[target] = admitted
            return true
        } catch {
            guard admits(admission, generations: loadGenerationByTarget),
                  mutationAdmission.map({ admits($0, generations: mutationGenerationByTarget) }) ?? true else {
                return false
            }
            delegate?.packageConfigurationCoordinatorSurface(error)
            return false
        }
    }

    @discardableResult
    func checkUpdates(target: PackageConfigurationTarget) async -> Bool {
        let admission = beginAdmission(target: target, generations: &updateGenerationByTarget)
        do {
            let response: UpdateResponse = try await client.request(
                "packages.checkUpdates",
                TargetParams(cwd: target.cwd),
                timeout: Self.checkUpdatesTimeout
            )
            guard admits(admission, generations: updateGenerationByTarget) else { return false }
            let admitted = try PackageCatalogPolicy.admit(response.updates)
            updatesByTarget[target] = admitted
            return true
        } catch {
            guard admits(admission, generations: updateGenerationByTarget) else { return false }
            delegate?.packageConfigurationCoordinatorSurface(error)
            return false
        }
    }

    func mutate(
        _ action: PackageMutationAction,
        source: String?,
        local: Bool,
        target: PackageConfigurationTarget
    ) async throws {
        let admission = beginAdmission(target: target, generations: &mutationGenerationByTarget)
        let method = "packages.\(action.rawValue)"
        let commandID = uuidSource.next().uuidString
        let params = MutationParams(
            source: source,
            local: local,
            cwd: target.cwd,
            commandId: commandID
        )
        do {
            _ = try await mutationExecutor.performValue(method: method, commandID: commandID) {
                try await client.requestValue(method, params, timeout: Self.mutationTimeout)
            }
        } catch {
            guard admits(admission, generations: mutationGenerationByTarget) else {
                throw CancellationError()
            }
            throw error
        }
        try require(admission, generations: mutationGenerationByTarget)

        switch (action, source) {
        case (.update, nil):
            updatesByTarget[target] = []
        case (.update, .some(let source)), (.remove, .some(let source)):
            let scope: PackageSummary.Scope = local ? .project : .user
            updatesByTarget[target]?.removeAll { $0.source == source && $0.scope == scope }
        default:
            break
        }

        _ = await load(target: target, requiring: admission)
        try require(admission, generations: mutationGenerationByTarget)
    }

    func notePackagesChanged() {
        invalidationGeneration &+= 1
    }

    /// Synchronously revokes all suspended work and drops disposable package
    /// projections for the retired profile.
    func clearProfile() {
        profileGeneration &+= 1
        loadGenerationByTarget = loadGenerationByTarget.mapValues { $0 &+ 1 }
        updateGenerationByTarget = updateGenerationByTarget.mapValues { $0 &+ 1 }
        mutationGenerationByTarget = mutationGenerationByTarget.mapValues { $0 &+ 1 }
        inventoryByTarget.removeAll()
        updatesByTarget.removeAll()
    }

    private func beginAdmission(
        target: PackageConfigurationTarget,
        generations: inout [PackageConfigurationTarget: Int]
    ) -> TargetAdmission {
        let targetGeneration = (generations[target] ?? 0) &+ 1
        generations[target] = targetGeneration
        return TargetAdmission(
            profileGeneration: profileGeneration,
            target: target,
            targetGeneration: targetGeneration
        )
    }

    private func admits(
        _ admission: TargetAdmission,
        generations: [PackageConfigurationTarget: Int]
    ) -> Bool {
        profileGeneration == admission.profileGeneration
            && generations[admission.target] == admission.targetGeneration
    }

    private func require(
        _ admission: TargetAdmission,
        generations: [PackageConfigurationTarget: Int]
    ) throws {
        try Task.checkCancellation()
        guard admits(admission, generations: generations) else { throw CancellationError() }
    }

    #if HOSTED_TEST
    func installHostedInventory(_ inventory: PackageInventory?, for target: PackageConfigurationTarget) {
        inventoryByTarget[target] = inventory
    }

    func installHostedUpdates(_ updates: [PackageUpdate], for target: PackageConfigurationTarget) {
        updatesByTarget[target] = updates
    }

    func setHostedInvalidationGeneration(_ generation: Int) {
        invalidationGeneration = generation
    }
    #endif
}
