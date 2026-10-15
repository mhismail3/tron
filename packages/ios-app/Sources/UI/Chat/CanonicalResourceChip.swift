import SwiftUI
import TronMobileCore

private struct CanonicalResourceSessionIDKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var canonicalResourceSessionID: String? {
        get { self[CanonicalResourceSessionIDKey.self] }
        set { self[CanonicalResourceSessionIDKey.self] = newValue }
    }
}

enum CanonicalResourceChipPresentation {
    static func title(for resource: ComposerResourceInvocation) -> String {
        ComposerResourceNameFormatter.friendly(resource.name)
    }

    static func kindTitle(for resource: ComposerResourceInvocation) -> String {
        switch resource.source {
        case .skill: "Skill"
        case .prompt: "Prompt"
        case .extension: "Command"
        }
    }

    static func icon(for resource: ComposerResourceInvocation) -> String {
        switch resource.source {
        case .skill: "sparkles"
        case .prompt: "text.quote"
        case .extension: "command"
        }
    }

    static func tone(for resource: ComposerResourceInvocation) -> ChatNotificationTone {
        switch resource.source {
        case .skill: .information
        case .prompt: ChatSemanticPillRole.prompt.tone
        case .extension: ChatSemanticPillRole.command.tone
        }
    }

    @MainActor static func accent(for resource: ComposerResourceInvocation) -> Color {
        switch resource.source {
        case .skill: .tronCyan
        case .prompt: ChatSemanticPillRole.prompt.accent
        case .extension: ChatSemanticPillRole.command.accent
        }
    }

    static func detailEntry(for resource: ComposerResourceInvocation) -> ComposerResourceEntry? {
        let source: CommandInfo.Source = switch resource.source {
        case .skill: .skill
        case .prompt: .prompt
        case .extension: .extension
        }
        let commandName = source == .skill ? "skill:\(resource.name)" : resource.name
        return ComposerResourceEntry(command: CommandInfo(
            name: commandName,
            description: nil,
            argumentHint: nil,
            source: source,
            sourcePath: nil
        ))
    }

    static func invocationPrefix(for resource: ComposerResourceInvocation) -> String {
        resource.source == .skill ? "@" : "/"
    }
}

/// The skills and prompts one message invoked, in order, wrapping like tool
/// chips. An extension command owns its own command row, so it never shows here.
struct CanonicalResourceChips: View, Equatable {
    let resources: [ComposerResourceInvocation]

    var body: some View {
        let shown = Self.messageResources(resources)
        if !shown.isEmpty {
            ToolChipFlowLayout(spacing: 6) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, resource in
                    CanonicalResourceChip(resource: resource)
                }
            }
        }
    }

    static func messageResources(_ resources: [ComposerResourceInvocation]?) -> [ComposerResourceInvocation] {
        (resources ?? []).filter { !$0.isExtensionCommand }
    }

    /// "Skill Review, Prompt Tests" for a row's combined accessibility label.
    static func accessibilityLabel(_ resources: [ComposerResourceInvocation]?) -> String? {
        let shown = messageResources(resources)
        guard !shown.isEmpty else { return nil }
        return shown.map {
            "\(CanonicalResourceChipPresentation.kindTitle(for: $0)) \(CanonicalResourceChipPresentation.title(for: $0))"
        }.joined(separator: ", ")
    }
}

/// Stable metadata chip for a canonical user message bound to one Gateway
/// resource invocation. Transcript identity and scrolling stay with the row;
/// the chip owns only its detail-sheet route.
struct CanonicalResourceChip: View, Equatable {
    let resource: ComposerResourceInvocation

    @Environment(\.canonicalResourceSessionID) private var sessionID
    @State private var showsDetail = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.resource == rhs.resource }

    var body: some View {
        ChatCompactPillSurface(
            tone: tone,
            material: .glass,
            interactive: detailEntry != nil,
            accentOverride: CanonicalResourceChipPresentation.accent(for: resource),
            cornerRadiusOverride: ChatToolChipShapePolicy.cornerRadius
        ) {
            ChatCompactPillLabel(
                icon: CanonicalResourceChipPresentation.icon(for: resource),
                title: CanonicalResourceChipPresentation.title(for: resource),
                detail: CanonicalResourceChipPresentation.kindTitle(for: resource),
                tone: tone,
                iconSize: ChatCompactPillLayoutPolicy.toolIconSize,
                titleWeight: .bold,
                foregroundOverride: resource.source == .skill ? CanonicalResourceChipPresentation.accent(for: resource) : nil
            )
        }
        .chatCompactPillInteraction(
            accessibilityLabel: "Show resource details, \(CanonicalResourceChipPresentation.title(for: resource))",
            accessibilityValue: CanonicalResourceChipPresentation.kindTitle(for: resource)
        ) {
            if detailEntry != nil { showsDetail = true }
        }
        .tronManagedSheet(
            isPresented: $showsDetail,
            identity: "chat.canonical-resource"
        ) {
            if let detailEntry {
                ComposerResourceDetailSheet(
                    sessionID: sessionID,
                    entry: detailEntry,
                    accent: CanonicalResourceChipPresentation.accent(for: resource),
                    prefix: CanonicalResourceChipPresentation.invocationPrefix(for: resource)
                )
            }
        }
    }

    private var tone: ChatNotificationTone {
        CanonicalResourceChipPresentation.tone(for: resource)
    }

    private var detailEntry: ComposerResourceEntry? {
        CanonicalResourceChipPresentation.detailEntry(for: resource)
    }
}
