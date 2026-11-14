import Foundation
import Observation
import TronMobileCore

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

    init(
        client: GatewayClient,
        mutationExecutor: ConfirmedMutationExecutor,
        uuidSource: UUIDSource
    ) {
        self.client = client
        self.mutationExecutor = mutationExecutor
        self.uuidSource = uuidSource
    }

    func listProjects() async throws -> ProjectLifecycleListing {
        let admission = profileGeneration
        var cursor: String?, rows: [ProjectLifecycleRow] = []
        for _ in 0..<20 {
            var params: [String: JSONValue] = ["limit": .number(50)]
            if let cursor { params["after"] = .string(cursor) }
            let value = try await client.requestValue("projects.list", JSONValue.object(params))
            try requireProfile(admission)
            try Task.checkCancellation()
            let page = try value.decode(ProjectLifecycleListing.self)
            rows.append(contentsOf: page.projects)
            guard let next = page.nextCursor else {
                return ProjectLifecycleListing(workspace: page.workspace, projects: rows, nextCursor: nil)
            }
            cursor = next
        }
        throw GatewayFailure(code: "invalid_response", message: "The project listing exceeded its bounded window.", retryable: false, details: nil)
    }

    func inspectProject(path: String) async throws -> ProjectLifecycleRow {
        let admission = profileGeneration
        let value = try await client.requestValue("projects.inspect", JSONValue.object(["cwd": .string(path)]))
        try requireProfile(admission)
        return try value.decode(ProjectLifecycleRow.self)
    }

    func reviewProject(_ operation: ProjectLifecycleOperation, name: String) async throws -> ProjectLifecycleReview {
        let admission = profileGeneration
        let params: [String: JSONValue] = ["action": .string(operation.rawValue), "name": .string(name),
            "reason": .string("Requested \(operation.rawValue) from iPhone Trusted Projects")]
        let value = try await projectChange(params)
        try requireProfile(admission)
        let planned = try value.decode(ProjectLifecycleReviewResult.self)
        guard planned.status == "review", planned.review.requiresTap, !planned.review.digest.isEmpty else {
            throw GatewayFailure(code: "invalid_response", message: "No exact project review was proven. Inspect the project and Changes before retrying.", retryable: false, details: nil)
        }
        return ProjectLifecycleReview(params: params, review: planned.review, intent: planned.intent)
    }

    func confirmProject(_ reviewed: ProjectLifecycleReview) async throws {
        let admission = profileGeneration
        var params = reviewed.params
        params["confirmation"] = .object(["digest": .string(reviewed.review.digest), "intent": reviewed.intent])
        let value = try await projectChange(params)
        try requireProfile(admission)
        noteSettingsChanged()
        noteTrustChanged()
        try value.decode(SettingsChangeResult.self).throwIfRefused()
    }

    private func projectChange(_ fields: [String: JSONValue]) async throws -> JSONValue {
        let commandID = uuidSource.next().uuidString
        var params = fields
        params["commandId"] = .string(commandID)
        return try await mutationExecutor.performValue(method: "projects.change", commandID: commandID) {
            try await client.requestValue("projects.change", JSONValue.object(params))
        }
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
        var change: [String: JSONValue] = [
            "key": .string("permissions.projectTrust"), "layer": .string("global"),
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
        try value.decode(SettingsChangeResult.self).throwIfRefused()
        guard let inspection = value.objectValue?["changes"]?.arrayValue?.first?.objectValue?["result"] else {
            throw GatewayFailure(code: "invalid_response", message: "The trust change returned no trust inspection.", retryable: false, details: nil)
        }
        return inspection
    }

    func macTerminalStatus() async throws -> MacTerminalStatus {
        let admittedProfileGeneration = profileGeneration
        let value = try await client.requestValue("macTerminal.status", JSONValue.object([:]))
        try requireProfile(admittedProfileGeneration)
        return try value.decode(MacTerminalStatus.self)
    }

    func setMacTerminalKey(device: String, publicKey: String?) async throws {
        let admittedProfileGeneration = profileGeneration
        let commandID = uuidSource.next().uuidString
        var change: [String: JSONValue] = [
            "key": .string("permissions.macTerminalKey"), "layer": .string("global"),
            "qualifiers": .object(["device": .string(device)]),
        ]
        if let publicKey { change["op"] = .string("set"); change["value"] = .string(publicKey) } else { change["op"] = .string("unset") }
        let params: JSONValue = .object([
            "commandId": .string(commandID),
            "target": .object(["kind": .string("global")]),
            "changes": .array([.object(change)]),
        ])
        let value = try await mutationExecutor.performValue(method: "settings.change", commandID: commandID) {
            try await client.requestValue("settings.change", params)
        }
        try requireProfile(admittedProfileGeneration)
        guard value.objectValue?["status"]?.stringValue == "applied" else {
            throw GatewayFailure(code: "conflict", message: "The Mac did not apply the Mac Terminal key change.", retryable: false, details: nil)
        }
    }

    func noteSettingsChanged() {
        settingsInvalidationGeneration &+= 1
    }

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

    private func options(for resolution: SettingsResolution, target: JSONValue) async -> [String: SettingsOptionsResponse] {
        let sourced = resolution.keys.filter { setting in
            setting.presentation.optionsSource != nil
                && [.choice, .checklist].contains(SettingsRowControl(negotiated: setting.presentation.control))
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

    func settingsOptions(target: JSONValue, key: String, qualifiers: [String: String]?, cursor: String? = nil) async throws -> SettingsOptionsResponse {
        let admittedProfileGeneration = profileGeneration
        var params: [String: JSONValue] = ["target": target, "key": .string(key)]
        if let qualifiers { params["qualifiers"] = .object(qualifiers.mapValues { JSONValue.string($0) }) }
        if let cursor { params["cursor"] = .string(cursor) }
        let value = try await client.requestValue("settings.options", JSONValue.object(params))
        try requireProfile(admittedProfileGeneration)
        return try value.decode(SettingsOptionsResponse.self)
    }

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

    func change(target: JSONValue, change: JSONValue, fence: JSONValue? = nil, confirmationDigest: String? = nil, admitSend: (() -> Bool)? = nil) async throws {
        let admittedProfileGeneration = profileGeneration
        let commandID = uuidSource.next().uuidString
        var fields: [String: JSONValue] = [
            "commandId": .string(commandID), "target": target, "changes": .array([change]),
        ]
        if let fence { fields["fence"] = fence }
        if let confirmationDigest { fields["confirmationDigest"] = .string(confirmationDigest) }
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

    func clearProfile() {
        profileGeneration &+= 1
        snapshots = [:]
        snapshotOrder = []
        refreshes.values.forEach { $0.task.cancel() }
        refreshes = [:]
        settingsInvalidationGeneration &+= 1
    }

    private func requireProfile(_ admittedProfileGeneration: Int) throws {
        guard profileGeneration == admittedProfileGeneration else { throw CancellationError() }
    }
}

struct SettingsFreshness: Hashable, Sendable {
    let invalidation: Int
    let foreground: Int
}

struct SettingsSnapshot {
    let resolution: SettingsResolution
    let options: [String: SettingsOptionsResponse]
    let freshness: SettingsFreshness
}
