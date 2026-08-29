import SwiftUI

/// Stable metadata chip for a canonical user message bound to one Gateway
/// resource invocation. It is presentation-only and does not own transcript
/// identity or scrolling.
struct CanonicalResourceChip: View, Equatable {
    let resource: ComposerResourceInvocation

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.resource == rhs.resource }

    var body: some View {
        ChatCompactPillSurface(tone: .accent, material: .glass, interactive: false) {
            ChatCompactPillLabel(
                icon: resource.source == .skill ? "sparkles" : "command",
                title: resource.source == .skill ? "Skill" : resource.source == .prompt ? "Prompt" : "Command",
                detail: ComposerResourceNameFormatter.friendly(resource.name),
                tone: .accent,
                iconSize: ChatCompactPillLayoutPolicy.toolIconSize,
                titleWeight: .bold
            )
        }
        .accessibilityLabel("\(resource.source == .skill ? "Skill" : resource.source == .prompt ? "Prompt" : "Command") \(resource.name)")
    }
}
