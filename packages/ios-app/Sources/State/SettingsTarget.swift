import Foundation
import TronMobileCore

enum SettingsScope: String, Hashable, Sendable {
    case global
    case project
}

enum SettingsTarget: Hashable, Sendable {
    case global
    case project(cwd: String)

    init?(scope: SettingsScope, projectCWD: String?) {
        switch scope {
        case .global:
            self = .global
        case .project:
            guard let projectCWD, !projectCWD.isEmpty else { return nil }
            self = .project(cwd: projectCWD)
        }
    }

    var scope: SettingsScope {
        switch self {
        case .global: .global
        case .project: .project
        }
    }

    var cwd: String? {
        switch self {
        case .global: nil
        case let .project(cwd): cwd
        }
    }
}

extension SettingsTarget {
    /// The layer a write to this target lands in: Mac for global, Project for a project.
    var writeLayer: String { scope == .global ? "mac" : "project" }

    /// One chat's `settings.resolve`/`settings.change` target. Every surface names a
    /// target the same way, so they share one snapshot.
    static func sessionGatewayTarget(_ sessionID: String) -> JSONValue {
        .object(["kind": .string("session"), "sessionId": .string(sessionID)])
    }

    /// The `target` of `settings.resolve` and `settings.change` (docs/settings-model.md 3.1).
    var gatewayTarget: JSONValue {
        switch self {
        case .global: .object(["kind": .string("mac")])
        case let .project(cwd): .object(["kind": .string("project"), "cwd": .string(cwd)])
        }
    }

    /// One `settings.change` entry that sets, or with nil unsets, a schema key at
    /// this target's own layer: Mac for global, Project for a project.
    func keyChange(_ key: String, value: JSONValue?) -> JSONValue {
        var change: [String: JSONValue] = ["key": .string(key), "layer": .string(writeLayer)]
        if let value {
            change["op"] = .string("set")
            change["value"] = value
        } else {
            change["op"] = .string("unset")
        }
        return .object(change)
    }
}

struct ScopedSettingsDraftStore<Draft: Equatable> {
    private struct Entry {
        var baseline: Draft
        var current: Draft
        var isDirty: Bool
        var revision: Int
        var hasBaseline: Bool
    }

    private var entries: [SettingsTarget: Entry] = [:]
    private(set) var scopeGeneration = 0

    func draft(for target: SettingsTarget) -> Draft? {
        entries[target]?.current
    }

    func baseline(for target: SettingsTarget) -> Draft? {
        guard entries[target]?.hasBaseline == true else { return nil }
        return entries[target]?.baseline
    }

    func isDirty(_ target: SettingsTarget) -> Bool {
        entries[target]?.isDirty == true
    }

    /// Compares the value currently presented by the sheet directly with the
    /// installed baseline. This deliberately does not depend on a later
    /// SwiftUI `onChange` callback having copied the value into the store.
    func hasChanges(_ presented: Draft, for target: SettingsTarget) -> Bool {
        guard let entry = entries[target] else { return false }
        return !entry.hasBaseline || presented != entry.baseline
    }

    func revision(for target: SettingsTarget) -> Int? {
        entries[target]?.revision
    }

    mutating func update(_ draft: Draft, for target: SettingsTarget) {
        if var entry = entries[target] {
            entry.current = draft
            entry.isDirty = !entry.hasBaseline || draft != entry.baseline
            entry.revision &+= 1
            entries[target] = entry
        } else {
            entries[target] = Entry(
                baseline: draft,
                current: draft,
                isDirty: true,
                revision: 1,
                hasBaseline: false
            )
        }
    }

    @discardableResult
    mutating func install(_ draft: Draft, for target: SettingsTarget) -> Bool {
        guard entries[target]?.isDirty != true else { return false }
        replaceWithInstalled(draft, for: target)
        return true
    }

    /// Seeds the disabled initial state exactly once. A later refresh must not
    /// redefine a currently presented edit as the baseline merely because its
    /// `onChange` callback has not run yet.
    @discardableResult
    mutating func seedBaselineIfMissing(_ draft: Draft, for target: SettingsTarget) -> Bool {
        guard entries[target] == nil else { return false }
        replaceWithInstalled(draft, for: target)
        return true
    }

    /// Installs an asynchronous projection only when the value still visible
    /// in the sheet matches its baseline. This closes the render/onChange gap
    /// without allowing a late response to erase an edit.
    @discardableResult
    mutating func install(
        _ draft: Draft,
        for target: SettingsTarget,
        ifCurrent presented: Draft
    ) -> Bool {
        guard !hasChanges(presented, for: target) else { return false }
        replaceWithInstalled(draft, for: target)
        return true
    }

    @discardableResult
    mutating func markSaved(
        _ draft: Draft,
        for target: SettingsTarget,
        expectedRevision: Int
    ) -> Bool {
        markSaved(
            submitted: draft,
            resulting: draft,
            for: target,
            expectedRevision: expectedRevision
        )
    }

    private mutating func replaceWithInstalled(_ draft: Draft, for target: SettingsTarget) {
        let revision = (entries[target]?.revision ?? 0) &+ 1
        entries[target] = Entry(
            baseline: draft,
            current: draft,
            isDirty: false,
            revision: revision,
            hasBaseline: true
        )
    }

    @discardableResult
    mutating func markSaved(
        submitted: Draft,
        resulting: Draft,
        for target: SettingsTarget,
        expectedRevision: Int
    ) -> Bool {
        guard let entry = entries[target],
              entry.revision == expectedRevision,
              entry.current == submitted else { return false }
        entries[target] = Entry(
            baseline: resulting,
            current: resulting,
            isDirty: false,
            revision: entry.revision &+ 1,
            hasBaseline: true
        )
        return true
    }
}

struct SettingsLoadID: Hashable {
    let target: SettingsTarget?
    let invalidationGeneration: Int
    let foregroundGeneration: Int
}
