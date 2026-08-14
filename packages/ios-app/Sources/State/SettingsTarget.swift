import Foundation

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

struct ScopedSettingsDraftStore<Draft: Equatable> {
    private struct Entry {
        var baseline: Draft
        var current: Draft
        var isDirty: Bool
        var revision: Int
    }

    private var entries: [SettingsTarget: Entry] = [:]

    func draft(for target: SettingsTarget) -> Draft? {
        entries[target]?.current
    }

    func isDirty(_ target: SettingsTarget) -> Bool {
        entries[target]?.isDirty == true
    }

    func revision(for target: SettingsTarget) -> Int? {
        entries[target]?.revision
    }

    mutating func update(_ draft: Draft, for target: SettingsTarget) {
        if var entry = entries[target] {
            entry.current = draft
            entry.isDirty = draft != entry.baseline
            entry.revision &+= 1
            entries[target] = entry
        } else {
            entries[target] = Entry(baseline: draft, current: draft, isDirty: true, revision: 1)
        }
    }

    @discardableResult
    mutating func install(_ draft: Draft, for target: SettingsTarget) -> Bool {
        guard entries[target]?.isDirty != true else { return false }
        let revision = (entries[target]?.revision ?? 0) &+ 1
        entries[target] = Entry(baseline: draft, current: draft, isDirty: false, revision: revision)
        return true
    }

    @discardableResult
    mutating func markSaved(
        _ draft: Draft,
        for target: SettingsTarget,
        expectedRevision: Int
    ) -> Bool {
        guard let entry = entries[target],
              entry.revision == expectedRevision,
              entry.current == draft else { return false }
        entries[target] = Entry(
            baseline: draft,
            current: draft,
            isDirty: false,
            revision: entry.revision &+ 1
        )
        return true
    }
}

struct AgentDefaultsLoadID: Hashable {
    let settingsTarget: SettingsTarget?
    let providerTarget: ProviderCatalogTarget
    let settingsInvalidationGeneration: Int
    let providerInvalidationGeneration: Int
}

struct SettingsLoadID: Hashable {
    let target: SettingsTarget?
    let invalidationGeneration: Int
}
