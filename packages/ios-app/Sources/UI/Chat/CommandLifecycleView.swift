import SwiftUI

/// Canonical invocation receipt presentation. This is an inbound command
/// record, not a user prompt bubble; its physical identity is the receipt ID.
struct CommandLifecycleView: View {
    let item: TranscriptItem

    private var name: String {
        item.semantic?.resourceInvocation?.name ?? "Extension command"
    }
    private var state: String {
        item.semantic?.lifecycle?.rawValue ?? "accepted"
    }
    private var origin: String {
        item.semantic?.origin.title
            ?? item.semantic?.origin.kind.rawValue.capitalized
            ?? "Extension"
    }
    private var tone: ChatNotificationTone {
        switch state {
        case "failed", "interrupted": return .error
        case "completed": return .accent
        case "outcomeUnknown": return .warning
        default: return .neutral
        }
    }

    var body: some View {
        ChatCompactPillSurface(tone: tone, material: .glass, interactive: false) {
            ChatCompactPillLabel(
                icon: "command",
                title: "\(origin) · /\(name)",
                detail: ComposerResourceNameFormatter.friendly(state),
                tone: tone,
                iconSize: ChatCompactPillLayoutPolicy.toolIconSize,
                titleWeight: .bold
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(origin) command \(name), \(state)")
    }
}
