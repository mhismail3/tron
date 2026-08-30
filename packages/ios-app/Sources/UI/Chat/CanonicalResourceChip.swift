import SwiftUI

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
        resource.source == .skill ? "sparkles" : "command"
    }

    static func tone(for resource: ComposerResourceInvocation) -> ChatNotificationTone {
        resource.source == .skill ? .information : .purple
    }

    static func accent(for resource: ComposerResourceInvocation) -> Color {
        resource.source == .skill ? .tronCyan : .tronPurple
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
            cornerRadiusOverride: ChatToolChipShapePolicy.cornerRadius
        ) {
            ChatCompactPillLabel(
                icon: CanonicalResourceChipPresentation.icon(for: resource),
                title: CanonicalResourceChipPresentation.title(for: resource),
                detail: CanonicalResourceChipPresentation.kindTitle(for: resource),
                tone: tone,
                iconSize: ChatCompactPillLayoutPolicy.toolIconSize,
                titleWeight: .bold
            )
        }
        .chatCompactPillInteraction(
            accessibilityLabel: "Show resource details, \(CanonicalResourceChipPresentation.title(for: resource))",
            accessibilityValue: CanonicalResourceChipPresentation.kindTitle(for: resource)
        ) {
            if detailEntry != nil { showsDetail = true }
        }
        .sheet(isPresented: $showsDetail) {
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
