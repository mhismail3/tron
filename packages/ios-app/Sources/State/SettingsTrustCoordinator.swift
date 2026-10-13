import Foundation
import Observation
import TronMobileCore

/// Owns settings and trust request admission. Gateway settings and trust state
/// remain canonical; settings are read and written through `settings.resolve` and
/// `settings.change`. The one projection kept here is each target's last served
/// resolution with its rows' options (`SettingsSnapshot`): every settings surface
/// for a target reads the same snapshot, so a sheet opened from another never
/// re-reads what its parent shows. It is bounded, dropped with the profile, and
/// replaced whenever a settings event or foregrounding makes it stale.
@MainActor
@Observable
final class SettingsTrustCoordinator {
    private struct TrustInspectParams: Codable {
        let cwd: String
    }

    private let client: GatewayClient
    private let mutationExecutor: ConfirmedMutationExecutor
    private let uuidSource: UUIDSource

    private var profileGeneration = 0
    private(set) var snapshots: [JSONValue: SettingsSnapshot] = [:]
    /// Most recently refreshed last, so the bound evicts the least recent target.
    private var snapshotOrder: [JSONValue] = []
    private var refreshes: [JSONValue: SnapshotRefresh] = [:]
    private static let snapshotLimit = 16

    private struct SnapshotRefresh {
        let id = UUID()
        let freshness: SettingsFreshness
        let task: Task<Void, Error>
    }

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
    /// Apply again (settings-model.md 5.6): the Gateway re-writes the value an outside
    /// change replaced, as an ordinary audited change; never automatic.
    func applySettingsChangeAgain(_ changeID: String) async throws {
        let admittedProfileGeneration = profileGeneration
        let commandID = uuidSource.next().uuidString
        let params = JSONValue.object(["commandId": .string(commandID), "changeId": .string(changeID)])
        let value = try await mutationExecutor.performValue(method: "settings.applyAgain", commandID: commandID) {
            try await client.requestValue("settings.applyAgain", params)
        }
        try requireProfile(admittedProfileGeneration)
        try value.decode(SettingsChangeResult.self).throwIfRefused()
        noteSettingsChanged()
    }

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

    /// Brings a target's snapshot up to `freshness`. A current snapshot is not read
    /// again, and concurrent callers for one target share one read.
    func refreshSnapshot(target: JSONValue, freshness: SettingsFreshness) async throws {
        if snapshots[target]?.freshness == freshness { return }
        if let running = refreshes[target], running.freshness == freshness { return try await running.task.value }
        let admittedProfileGeneration = profileGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let resolution = try await self.resolveForRenderer(target: target)
            let options = await self.options(for: resolution, target: target)
            try self.requireProfile(admittedProfileGeneration)
            self.snapshots[target] = SettingsSnapshot(resolution: resolution, options: options, freshness: freshness)
            self.snapshotOrder.removeAll { $0 == target }
            self.snapshotOrder.append(target)
            while self.snapshotOrder.count > Self.snapshotLimit { self.snapshots[self.snapshotOrder.removeFirst()] = nil }
        }
        let refresh = SnapshotRefresh(freshness: freshness, task: task)
        refreshes[target] = refresh
        defer { if refreshes[target]?.id == refresh.id { refreshes[target] = nil } }
        try await task.value
    }

    /// The options each editable control of a resolution needs, read with it. A
    /// source that cannot answer leaves its row read-only; other rows are unaffected.
    private func options(for resolution: SettingsResolution, target: JSONValue) async -> [String: SettingsOptionsResponse] {
        let sourced = resolution.keys.filter { setting in
            setting.presentation?.optionsSource != nil
                && [.choice, .number, .checklist].contains(SettingsRowControl(negotiated: setting.presentation?.control))
        }
        let client = client
        return await withTaskGroup(of: (String, SettingsOptionsResponse?).self) { group in
            for setting in sourced {
                let id = setting.id, key = setting.key, qualifiers = setting.qualifiers
                group.addTask { (id, try? await Self.readOptions(client: client, target: target, key: key, qualifiers: qualifiers)) }
            }
            var read: [String: SettingsOptionsResponse] = [:]
            for await (id, response) in group { if let response { read[id] = response } }
            return read
        }
    }

    private nonisolated static func readOptions(client: GatewayClient, target: JSONValue, key: String,
                                                qualifiers: [String: String]?) async throws -> SettingsOptionsResponse {
        var params: [String: JSONValue] = ["target": target, "key": .string(key)]
        if let qualifiers { params["qualifiers"] = .object(qualifiers.mapValues { JSONValue.string($0) }) }
        return try await client.requestValue("settings.options", JSONValue.object(params)).decode(SettingsOptionsResponse.self)
    }

    /// `settings.resolve` for the generic renderer: the controls it implements are
    /// named so the Gateway negotiates each key's control (docs/settings-model.md 7.5).
    func resolveForRenderer(target: JSONValue, keys: [String]? = nil) async throws -> SettingsResolution {
        let admittedProfileGeneration = profileGeneration
        var params: [String: JSONValue] = [
            "target": target,
            "renderer": .object([
                "version": .number(Double(SettingsRendererContract.version)),
                "controls": .array(SettingsRendererContract.controls.map { JSONValue.string($0) }),
            ]),
        ]
        if let keys { params["keys"] = .array(keys.map(JSONValue.string)) }
        let value = try await client.requestValue("settings.resolve", JSONValue.object(params))
        try requireProfile(admittedProfileGeneration)
        return try value.decode(SettingsResolution.self)
    }

    /// `settings.options`: one page of the choices a key's control offers.
    func settingsOptions(target: JSONValue, key: String, qualifiers: [String: String]?, cursor: String? = nil) async throws -> SettingsOptionsResponse {
        let admittedProfileGeneration = profileGeneration
        var params: [String: JSONValue] = ["target": target, "key": .string(key)]
        if let qualifiers { params["qualifiers"] = .object(qualifiers.mapValues { JSONValue.string($0) }) }
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

    /// Synchronously revokes every suspended operation owned by the retired profile.
    func clearProfile() {
        profileGeneration &+= 1
        snapshots = [:]
        snapshotOrder = []
        refreshes.values.forEach { $0.task.cancel() }
        refreshes = [:]
        settingsInvalidationGeneration &+= 1
        approvalsRevision &+= 1
    }

    private func requireProfile(_ admittedProfileGeneration: Int) throws {
        guard profileGeneration == admittedProfileGeneration else { throw CancellationError() }
    }
}

/// When a snapshot was read: the settings events and foregrounding it reflects.
struct SettingsFreshness: Hashable, Sendable {
    let invalidation: Int
    let foreground: Int
}

/// A target's resolution and the options its rows' controls offer, read together.
struct SettingsSnapshot {
    let resolution: SettingsResolution
    let options: [String: SettingsOptionsResponse]
    let freshness: SettingsFreshness
}
