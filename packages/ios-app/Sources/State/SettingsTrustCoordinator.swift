import Foundation
import Observation

@MainActor
protocol SettingsTrustCoordinatorDelegate: AnyObject {
    func settingsTrustCoordinatorSurface(_ error: Error)
}

/// Owns disposable settings projections and settings/trust request admission.
/// Gateway settings and trust state remain canonical; this coordinator only
/// retains target-keyed settings reads for the active gateway profile.
@MainActor
@Observable
final class SettingsTrustCoordinator {
    private struct SettingsGetParams: Codable {
        let cwd: String?
        let scope: String
    }

    private struct SettingsUpdateParams: Codable {
        let patch: JSONValue
        let scope: String
        let cwd: String?
        let commandId: String
    }

    private struct TrustInspectParams: Codable {
        let cwd: String
    }

    private struct TrustSetParams: Encodable {
        let cwd: String
        let decision: Bool?
        let commandId: String

        private enum CodingKeys: String, CodingKey {
            case cwd
            case decision
            case commandId
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(cwd, forKey: .cwd)
            if let decision {
                try container.encode(decision, forKey: .decision)
            } else {
                try container.encodeNil(forKey: .decision)
            }
            try container.encode(commandId, forKey: .commandId)
        }
    }

    private struct SettingsLoadAdmission: Equatable {
        let profileGeneration: Int
        let target: SettingsTarget
        let targetGeneration: Int
    }

    private let client: GatewayClient
    private let mutationExecutor: ConfirmedMutationExecutor
    private let uuidSource: UUIDSource

    weak var delegate: (any SettingsTrustCoordinatorDelegate)?

    private var settingsByTarget: [SettingsTarget: JSONValue] = [:]
    private var settingsLoadGenerationByTarget: [SettingsTarget: Int] = [:]
    private var profileGeneration = 0

    private(set) var settingsInvalidationGeneration = 0
    private(set) var trustRevision = 0

    init(
        client: GatewayClient,
        mutationExecutor: ConfirmedMutationExecutor,
        uuidSource: UUIDSource
    ) {
        self.client = client
        self.mutationExecutor = mutationExecutor
        self.uuidSource = uuidSource
    }

    func settings(for target: SettingsTarget) -> JSONValue? {
        settingsByTarget[target]
    }

    func configuredDefaultModel(for target: SettingsTarget) -> ModelRef? {
        guard let model = settings(for: target)?.objectValue?["effective"]?.objectValue?["defaultModel"]?.objectValue,
              let provider = model["provider"]?.stringValue,
              let id = model["id"]?.stringValue else { return nil }
        return ModelRef(provider: provider, id: id)
    }

    @discardableResult
    func refreshSettings(target: SettingsTarget) async -> Bool {
        let admission = beginSettingsLoad(target: target)
        do {
            let value = try await client.requestValue(
                "settings.get",
                SettingsGetParams(cwd: target.cwd, scope: target.scope.rawValue)
            )
            guard admits(admission) else { return false }
            settingsByTarget[target] = value
            return true
        } catch {
            guard admits(admission) else { return false }
            delegate?.settingsTrustCoordinatorSurface(error)
            return false
        }
    }

    func updateSettings(_ patch: JSONValue, target: SettingsTarget) async throws {
        let admittedProfileGeneration = profileGeneration
        let commandID = uuidSource.next().uuidString
        let params = SettingsUpdateParams(
            patch: patch,
            scope: target.scope.rawValue,
            cwd: target.cwd,
            commandId: commandID
        )
        let _: JSONValue = try await mutationExecutor.performValue(
            method: "settings.update",
            commandID: commandID
        ) {
            try await client.requestValue("settings.update", params, timeout: .seconds(60))
        }
        try requireProfile(admittedProfileGeneration)
        _ = await refreshSettings(target: target)
        try requireProfile(admittedProfileGeneration)
    }

    func inspectTrust(target: TrustTarget) async throws -> JSONValue {
        let admittedProfileGeneration = profileGeneration
        let value = try await client.requestValue(
            "trust.inspect",
            TrustInspectParams(cwd: target.cwd)
        )
        try requireProfile(admittedProfileGeneration)
        return value
    }

    func setTrust(target: TrustTarget, decision: Bool?) async throws -> JSONValue {
        let admittedProfileGeneration = profileGeneration
        let commandID = uuidSource.next().uuidString
        let params = TrustSetParams(cwd: target.cwd, decision: decision, commandId: commandID)
        let value = try await mutationExecutor.performValue(method: "trust.set", commandID: commandID) {
            try await client.requestValue("trust.set", params)
        }
        try requireProfile(admittedProfileGeneration)
        return value
    }

    func noteSettingsChanged() {
        settingsInvalidationGeneration &+= 1
    }

    func noteTrustChanged() {
        trustRevision &+= 1
        settingsInvalidationGeneration &+= 1
    }

    /// Synchronously revokes every suspended operation owned by the retired
    /// profile and drops its disposable settings projections.
    func clearProfile() {
        profileGeneration &+= 1
        settingsLoadGenerationByTarget = settingsLoadGenerationByTarget.mapValues { $0 &+ 1 }
        settingsByTarget.removeAll()
    }

    private func beginSettingsLoad(target: SettingsTarget) -> SettingsLoadAdmission {
        let targetGeneration = (settingsLoadGenerationByTarget[target] ?? 0) &+ 1
        settingsLoadGenerationByTarget[target] = targetGeneration
        return SettingsLoadAdmission(
            profileGeneration: profileGeneration,
            target: target,
            targetGeneration: targetGeneration
        )
    }

    private func admits(_ admission: SettingsLoadAdmission) -> Bool {
        profileGeneration == admission.profileGeneration
            && settingsLoadGenerationByTarget[admission.target] == admission.targetGeneration
    }

    private func requireProfile(_ admittedProfileGeneration: Int) throws {
        guard profileGeneration == admittedProfileGeneration else { throw CancellationError() }
    }

    #if HOSTED_TEST
    func installHostedSettings(_ value: JSONValue?, for target: SettingsTarget) {
        settingsByTarget[target] = value
    }

    func setHostedInvalidationGenerations(settings: Int? = nil, trust: Int? = nil) {
        if let settings { settingsInvalidationGeneration = settings }
        if let trust { trustRevision = trust }
    }
    #endif
}
