import SwiftUI

// MARK: - New Session Creation

struct NewSessionCreated: Equatable, Sendable {
    let sessionId: String
    let workspaceId: String
    let model: String
    let workingDirectory: String
    let source: String?
    let profile: String
}

struct NewSessionCreateIntent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case chat
        case project
    }

    let kind: Kind
    let workingDirectory: String
    let model: String
    let title: String?
    let source: String?
    let profile: String
    let useWorktree: Bool?

    static func chat(workspace: String, model: String) -> NewSessionCreateIntent? {
        let workspace = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspace.isEmpty, !model.isEmpty else { return nil }
        return NewSessionCreateIntent(
            kind: .chat,
            workingDirectory: workspace,
            model: model,
            title: "Chat",
            source: "chat",
            profile: NewSessionProfileMode.chat.profileName,
            useWorktree: nil
        )
    }

    static func project(
        workingDirectory: String,
        model: String,
        profile: NewSessionProfileMode = .normal,
        useWorktreeOverride: Bool?
    ) -> NewSessionCreateIntent? {
        let workingDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workingDirectory.isEmpty, !model.isEmpty else { return nil }
        return NewSessionCreateIntent(
            kind: .project,
            workingDirectory: workingDirectory,
            model: model,
            title: nil,
            source: nil,
            profile: profile.profileName,
            useWorktree: useWorktreeOverride
        )
    }
}

enum NewSessionQuickChatPresetAction: Equatable, Sendable {
    case configure(workspace: String)
    case selectWorkspace

    static func resolve(quickWorkspace: String) -> NewSessionQuickChatPresetAction {
        let workspace = quickWorkspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspace.isEmpty else { return .selectWorkspace }
        return .configure(workspace: workspace)
    }
}

enum NewSessionProfileMode: String, CaseIterable, Identifiable, Sendable {
    case normal
    case chat
    case local

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: return "Normal"
        case .chat: return "Quick Chat"
        case .local: return "Local"
        }
    }

    var shortValue: String {
        switch self {
        case .normal: return "Normal"
        case .chat: return "Chat"
        case .local: return "Local"
        }
    }

    var icon: String {
        switch self {
        case .normal: return "sparkles"
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .local: return "desktopcomputer"
        }
    }

    var color: Color {
        switch self {
        case .normal: return .tronEmerald
        case .chat: return .tronCyan
        case .local: return .tronAmber
        }
    }

    var source: String? {
        self == .chat ? "chat" : nil
    }

    var profileName: String {
        rawValue
    }

    var titleOverride: String? {
        self == .chat ? "Chat" : nil
    }

    var caption: String {
        switch self {
        case .normal:
            return "Normal project/workspace session."
        case .chat:
            return "Fast conversation without project worktree context."
        case .local:
            return "Local-provider mode with compact context."
        }
    }

    static func effective(requested: NewSessionProfileMode, selectedModel: ModelInfo?) -> NewSessionProfileMode {
        selectedModel?.isLocalProvider == true ? .local : requested
    }
}

enum NewSessionPreferredModel: Equatable, Sendable {
    static func resolve(
        defaultModel: String,
        availableModels: [ModelInfo],
        profile: NewSessionProfileMode
    ) -> String {
        let selectable = availableModels.filter { !$0.isDisabled }
        let defaultModel = defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if profile == .local {
            return preferredLocalModel(from: selectable)?.id
                ?? fallbackUnknownDefaultModel(defaultModel, availableModels: availableModels)
        }

        if let defaultMatch = selectable.first(where: { $0.id == defaultModel && !$0.isLocalProvider }) {
            return defaultMatch.id
        }
        if !defaultModel.isEmpty && !availableModels.contains(where: { $0.id == defaultModel }) {
            return defaultModel
        }
        return selectable.first(where: { $0.recommended == true && $0.isAnthropic })?.id
            ?? selectable.first(where: { !$0.isLocalProvider && $0.recommended == true })?.id
            ?? selectable.first(where: { !$0.isLocalProvider })?.id
            ?? ""
    }

    private static func preferredLocalModel(from models: [ModelInfo]) -> ModelInfo? {
        models.first(where: { $0.isLocalProvider && $0.recommended == true })
            ?? models.first(where: { $0.isLocalProvider })
    }

    private static func fallbackUnknownDefaultModel(
        _ defaultModel: String,
        availableModels: [ModelInfo]
    ) -> String {
        if !defaultModel.isEmpty && !availableModels.contains(where: { $0.id == defaultModel }) {
            return defaultModel
        }
        return ""
    }
}

enum NewSessionCloneTarget: Equatable, Sendable {
    static func destinationWorkspace(from selectedWorkspace: String) -> String? {
        let selectedWorkspace = selectedWorkspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedWorkspace.isEmpty else { return nil }
        return selectedWorkspace
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

enum NewSessionWorktreeVisibility: Equatable, Sendable {
    static func whileChecking(currentIsGitRepo: Bool, nextWorkspace: String) -> Bool {
        let nextWorkspace = nextWorkspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nextWorkspace.isEmpty else { return false }
        return currentIsGitRepo
    }
}

enum NewSessionMode: String, Identifiable, Sendable {
    case chat
    case project
    case clone
    case importClaude

    var id: String { rawValue }
}

// MARK: - New Session Flow
