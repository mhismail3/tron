import Foundation
import Observation
import TronMobileCore

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

    private struct TrustInspectParams: Codable {
        let cwd: String
    }

    private struct SettingsLoadToken {
        let profileGeneration: Int
        let target: SettingsTarget
        let targetGeneration: Int
    }

    private struct SettingsLoadAdmission: Equatable {
        let profileGeneration: Int
        let target: SettingsTarget
        let targetGeneration: Int
        let connection: GatewayConnectionAdmission
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
    /// Advances on `settings.approvalsChanged` and on profile change, so a
    /// surface showing pending changes re-reads `settings.approvals`.
    private(set) var approvalsRevision = 0

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
        guard !Task.isCancelled else { return false }
        // Claim this target before awaiting the client actor so a newer read
        // cannot be ordered behind an older read that is still capturing its epoch.
        let token = beginSettingsLoad(target: target)
        let connection = await client.activeConnectionAdmission()
        let admission = SettingsLoadAdmission(
            profileGeneration: token.profileGeneration,
            target: token.target,
            targetGeneration: token.targetGeneration,
            connection: connection
        )
        do {
            let value = try await client.requestValue(
                "settings.get",
                SettingsGetParams(cwd: target.cwd, scope: target.scope.rawValue),
                expectedConnection: connection
            )
            guard await admits(admission) else { return false }
            settingsByTarget[target] = value
            return true
        } catch {
            guard await admits(admission) else { return false }
            delegate?.settingsTrustCoordinatorSurface(error)
            return false
        }
    }

    /// Writes a settings screen's patch through the one change path,
    /// `settings.change` (gateway docs/settings-model.md 5.2).
    func updateSettings(_ patch: JSONValue, target: SettingsTarget) async throws {
        let admittedProfileGeneration = profileGeneration
        let commandID = uuidSource.next().uuidString
        let params = try SettingsPatchChanges.params(patch: patch, target: target, commandID: commandID)
        if params.objectValue?["changes"]?.arrayValue?.isEmpty == false {
            let _: JSONValue = try await mutationExecutor.performValue(
                method: "settings.change",
                commandID: commandID
            ) {
                try await client.requestValue("settings.change", params)
            }
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

    /// Trust for one project is the Mac-layer key `permissions.projectTrust`
    /// qualified by that project; it changes through `settings.change`, whose
    /// outcome carries the resulting trust inspection.
    func setTrust(target: TrustTarget, decision: Bool?) async throws -> JSONValue {
        let admittedProfileGeneration = profileGeneration
        let commandID = uuidSource.next().uuidString
        var change: [String: JSONValue] = [
            "key": .string("permissions.projectTrust"), "layer": .string("mac"),
        ]
        if let decision { change["op"] = .string("set"); change["value"] = .bool(decision) } else { change["op"] = .string("unset") }
        let params: JSONValue = .object([
            "commandId": .string(commandID),
            "target": .object(["kind": .string("project"), "cwd": .string(target.cwd)]),
            "changes": .array([.object(change)]),
        ])
        let value = try await mutationExecutor.performValue(method: "settings.change", commandID: commandID) {
            try await client.requestValue("settings.change", params)
        }
        try requireProfile(admittedProfileGeneration)
        guard let inspection = value.objectValue?["changes"]?.arrayValue?.first?.objectValue?["result"] else {
            throw GatewayFailure(code: "invalid_response", message: "The trust change returned no trust inspection.", retryable: false, details: nil)
        }
        return inspection
    }

    func noteSettingsChanged() {
        settingsInvalidationGeneration &+= 1
    }

    func noteApprovalsChanged() {
        approvalsRevision &+= 1
    }

    /// The open pending changes (docs/settings-model.md 5.5). A disposable read:
    /// the surface fences publication with its own presentation activity.
    func pendingApprovals() async throws -> [SettingsApprovalRequest] {
        let admittedProfileGeneration = profileGeneration
        let value = try await client.requestValue("settings.approvals", JSONValue.object([:]))
        try requireProfile(admittedProfileGeneration)
        return try value.decode(SettingsApprovalsResponse.self).requests
    }

    /// One bounded audit page. Empty pages may still carry a cursor; callers
    /// advance until it is absent rather than treating an empty page as EOF.
    func settingsHistory(cursor: String?, actor: String?, layer: String?, section: String?, key: String?, status: String?) async throws -> SettingsChangeHistoryPage {
        let admittedProfileGeneration = profileGeneration
        var params: [String: JSONValue] = ["limit": .number(100)]
        if let cursor { params["cursor"] = .string(cursor) }
        if let actor { params["actor"] = .string(actor) }
        if let layer { params["layer"] = .string(layer) }
        if let section { params["section"] = .string(section) }
        if let key { params["key"] = .string(key) }
        if let status { params["status"] = .string(status) }
        let value = try await client.requestValue("settings.history", JSONValue.object(params))
        try requireProfile(admittedProfileGeneration)
        return try value.decode(SettingsChangeHistoryPage.self)
    }

    /// Undo is an accepted domain mutation and must use the shared receipt owner.
    func undoSettingsChange(_ changeID: String, fence: JSONValue?, admitSend: (() -> Bool)? = nil) async throws {
        let admittedProfileGeneration = profileGeneration
        let commandID = uuidSource.next().uuidString
        var fields: [String: JSONValue] = ["commandId": .string(commandID), "changeId": .string(changeID)]
        if let fence { fields["fence"] = fence }
        let params = JSONValue.object(fields)
        let value = try await mutationExecutor.performValue(method: "settings.undo", commandID: commandID) {
            if let admitSend, !admitSend() { throw CancellationError() }
            return try await client.requestValue("settings.undo", params)
        }
        try requireProfile(admittedProfileGeneration)
        try value.decode(SettingsChangeResult.self).throwIfRefused()
        noteSettingsChanged()
    }

    /// The maintainer's decision on one pending change, bound to the exact diff
    /// he saw by its digest. A Chat-layer change carries the chat's fence.
    func decideApproval(_ request: SettingsApprovalRequest, approved: Bool, fence: JSONValue?) async throws {
        let admittedProfileGeneration = profileGeneration
        let commandID = uuidSource.next().uuidString
        var params: [String: JSONValue] = [
            "commandId": .string(commandID), "requestId": .string(request.requestId),
            "digest": .string(request.digest), "approved": .bool(approved),
        ]
        if let fence { params["fence"] = fence }
        _ = try await mutationExecutor.performValue(method: "settings.decide", commandID: commandID) {
            try await client.requestValue("settings.decide", JSONValue.object(params))
        }
        try requireProfile(admittedProfileGeneration)
        approvalsRevision &+= 1
    }

    /// `settings.resolve` for the generic renderer: the controls it implements are
    /// named so the Gateway negotiates each key's control (docs/settings-model.md 7.5).
    func resolveForRenderer(target: JSONValue) async throws -> SettingsResolution {
        let admittedProfileGeneration = profileGeneration
        let value = try await client.requestValue("settings.resolve", JSONValue.object([
            "target": target,
            "renderer": .object([
                "version": .number(Double(SettingsRendererContract.version)),
                "controls": .array(SettingsRendererContract.controls.map { JSONValue.string($0) }),
            ]),
        ]))
        try requireProfile(admittedProfileGeneration)
        return try value.decode(SettingsResolution.self)
    }

    /// `settings.options`: the choices a key's control offers, filtered by `query`.
    func settingsOptions(target: JSONValue, key: String, qualifiers: [String: String]?, query: String?, cursor: String? = nil) async throws -> SettingsOptionsResponse {
        let admittedProfileGeneration = profileGeneration
        var params: [String: JSONValue] = ["target": target, "key": .string(key)]
        if let qualifiers { params["qualifiers"] = .object(qualifiers.mapValues { JSONValue.string($0) }) }
        if let query { params["query"] = .string(query) }
        if let cursor { params["cursor"] = .string(cursor) }
        let value = try await client.requestValue("settings.options", JSONValue.object(params))
        try requireProfile(admittedProfileGeneration)
        return try value.decode(SettingsOptionsResponse.self)
    }

    /// A dry run of one change to a target: its tier, any `confirm` text, and any
    /// refusal. Nothing is applied; the caller decides what a refusal shows.
    func previewChange(target: JSONValue, change: JSONValue, fence: JSONValue? = nil) async throws -> SettingsChangeResult {
        let admittedProfileGeneration = profileGeneration
        var params: [String: JSONValue] = [
            "commandId": .string(uuidSource.next().uuidString), "target": target,
            "changes": .array([change]), "dryRun": .bool(true),
        ]
        if let fence { params["fence"] = fence }
        let value = try await client.requestValue("settings.change", JSONValue.object(params))
        try requireProfile(admittedProfileGeneration)
        return try value.decode(SettingsChangeResult.self)
    }

    /// One change to a target through the confirmed mutation path. A refusal the
    /// Gateway returns in its outcome is thrown, so nothing reads as applied.
    func change(target: JSONValue, change: JSONValue, fence: JSONValue? = nil, admitSend: (() -> Bool)? = nil) async throws {
        let admittedProfileGeneration = profileGeneration
        let commandID = uuidSource.next().uuidString
        var fields: [String: JSONValue] = [
            "commandId": .string(commandID), "target": target, "changes": .array([change]),
        ]
        if let fence { fields["fence"] = fence }
        let params = JSONValue.object(fields)
        let value = try await mutationExecutor.performValue(method: "settings.change", commandID: commandID) {
            if let admitSend, !admitSend() { throw CancellationError() }
            return try await client.requestValue("settings.change", params)
        }
        try requireProfile(admittedProfileGeneration)
        try value.decode(SettingsChangeResult.self).throwIfRefused()
    }

    func noteTrustChanged() {
        trustRevision &+= 1
        settingsInvalidationGeneration &+= 1
    }

    /// Synchronously revokes every suspended operation owned by the retired
    /// profile and drops its disposable settings projections.
    func clearProfile() {
        profileGeneration &+= 1
        settingsInvalidationGeneration &+= 1
        approvalsRevision &+= 1
        settingsLoadGenerationByTarget = settingsLoadGenerationByTarget.mapValues { $0 &+ 1 }
        settingsByTarget.removeAll()
    }

    private func beginSettingsLoad(target: SettingsTarget) -> SettingsLoadToken {
        let targetGeneration = (settingsLoadGenerationByTarget[target] ?? 0) &+ 1
        settingsLoadGenerationByTarget[target] = targetGeneration
        return SettingsLoadToken(
            profileGeneration: profileGeneration,
            target: target,
            targetGeneration: targetGeneration
        )
    }

    private func admits(_ admission: SettingsLoadAdmission) async -> Bool {
        guard !Task.isCancelled,
              profileGeneration == admission.profileGeneration,
              settingsLoadGenerationByTarget[admission.target] == admission.targetGeneration else {
            return false
        }
        let currentConnection = await client.activeConnectionAdmission()
        guard !Task.isCancelled,
              profileGeneration == admission.profileGeneration,
              settingsLoadGenerationByTarget[admission.target] == admission.targetGeneration else {
            return false
        }
        return currentConnection == admission.connection
    }

    private func requireProfile(_ admittedProfileGeneration: Int) throws {
        guard profileGeneration == admittedProfileGeneration else { throw CancellationError() }
    }

    #if HOSTED_TEST
    func installHostedSettings(_ value: JSONValue?, for target: SettingsTarget) {
        settingsByTarget[target] = value
    }

    #endif
}
