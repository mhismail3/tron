import SwiftUI

// MARK: - New Session Creation

struct NewSessionCreated: Equatable, Sendable {
    let sessionId: String
    let workspaceId: String
    let model: String
    let workingDirectory: String
}

struct NewSessionCreateIntent: Equatable, Sendable {
    let workingDirectory: String
    let model: String
    let sourceControl: SessionSourceControlSelection?

    static func make(
        workingDirectory: String,
        model: String,
        sourceControl: SessionSourceControlSelection? = nil
    ) -> NewSessionCreateIntent? {
        let workingDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workingDirectory.isEmpty, !model.isEmpty else { return nil }
        return NewSessionCreateIntent(
            workingDirectory: workingDirectory,
            model: model,
            sourceControl: sourceControl
        )
    }
}

struct NewSessionSourceControlProbeKey: Equatable, Sendable {
    let workingDirectory: String
    let continuity: EngineConnectionContinuity
}

enum NewSessionSourceControlProbeFailure: Equatable, Sendable {
    case serverUpgradeRequired
    case retry

    init(errorCode: String?) {
        self = errorCode == "NOT_FOUND" ? .serverUpgradeRequired : .retry
    }

    var value: String {
        switch self {
        case .serverUpgradeRequired: "Server Update Required"
        case .retry: "Could Not Check"
        }
    }

    var caption: String {
        switch self {
        case .serverUpgradeRequired:
            "The connected Tron server does not support Git session placement yet. Update or restart it, then retry."
        case .retry:
            "Could not inspect this workspace. Tap to retry."
        }
    }
}

enum NewSessionWorkingDirectoryResolution {
    static func resolve(
        requested: String,
        sourceControl: SessionSourceControlSelection?,
        serverWorkingDirectory: String?
    ) -> String? {
        if let resolved = serverWorkingDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !resolved.isEmpty {
            return resolved
        }
        return sourceControl == nil ? requested : nil
    }
}

extension SessionSourceControlPlacement {
    var title: String {
        switch self {
        case .existing: "Use Existing"
        case .branch: "New Branch"
        case .worktree: "New Worktree"
        }
    }

    var icon: String {
        switch self {
        case .existing: "arrow.triangle.branch"
        case .branch: "point.topleft.down.to.point.bottomright.curvepath"
        case .worktree: "square.split.2x1"
        }
    }

    func caption(currentBranch: String?) -> String {
        switch self {
        case .existing:
            if let currentBranch, !currentBranch.isEmpty {
                return "Use the selected checkout on \(currentBranch)."
            }
            return "Use the selected checkout at its current commit."
        case .branch:
            return "Create and switch this checkout to a new Tron session branch."
        case .worktree:
            return "Create an isolated checkout and branch from the current commit."
        }
    }
}

enum NewSessionPreferredModel: Equatable, Sendable {
    static func resolve(
        defaultModel: String,
        availableModels: [ModelInfo]
    ) -> String {
        let selectable = availableModels.filter { !$0.isDisabled }
        let defaultModel = defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if let defaultMatch = selectable.first(where: { $0.id == defaultModel }) {
            return defaultMatch.id
        }
        if !defaultModel.isEmpty && !availableModels.contains(where: { $0.id == defaultModel }) {
            return defaultModel
        }
        return selectable.first(where: { $0.recommended == true })?.id
            ?? selectable.first?.id
            ?? ""
    }
}

enum NewSessionModelCardValue: Equatable, Sendable {
    static func resolve(
        selectedModel: String,
        availableModels: [ModelInfo],
        isLoadingModels: Bool
    ) -> String {
        if isLoadingModels && selectedModel.isEmpty {
            return "Loading..."
        }
        if selectedModel.isEmpty {
            return "Unavailable"
        }
        if let model = availableModels.first(where: { $0.id == selectedModel }) {
            return model.name
        }
        return selectedModel.shortModelName
    }
}

// MARK: - Workspace Selection

struct WorkspaceSelectionOption: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case defaultWorkspace
        case recent
    }

    let path: String
    let title: String
    let subtitle: String
    let source: Source

    var id: String {
        "\(source.key):\(path)"
    }
}

enum WorkspaceSelectionOptionBuilder {
    static func options(
        defaultWorkspace: String,
        recentWorkspaces: [(path: String, name: String)]
    ) -> [WorkspaceSelectionOption] {
        var seen = Set<String>()
        var result: [WorkspaceSelectionOption] = []

        let trimmedDefault = defaultWorkspace.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDefault.isEmpty, seen.insert(trimmedDefault).inserted {
            result.append(WorkspaceSelectionOption(
                path: trimmedDefault,
                title: "Default workspace",
                subtitle: trimmedDefault.abbreviatingHomeDirectory,
                source: .defaultWorkspace
            ))
        }

        for workspace in recentWorkspaces {
            let trimmedPath = workspace.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPath.isEmpty, seen.insert(trimmedPath).inserted else { continue }
            let trimmedName = workspace.name.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(WorkspaceSelectionOption(
                path: trimmedPath,
                title: trimmedName.isEmpty ? CachedSession.workspaceDisplayName(for: trimmedPath) : trimmedName,
                subtitle: trimmedPath.abbreviatingHomeDirectory,
                source: .recent
            ))
        }

        return result
    }
}

private extension WorkspaceSelectionOption.Source {
    var key: String {
        switch self {
        case .defaultWorkspace:
            return "default"
        case .recent:
            return "recent"
        }
    }
}

// MARK: - New Session Flow
