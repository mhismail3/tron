import SwiftUI

/// Presentation-only motion roles for content entering an already-installed chat.
/// These values never create transcript continuity or participate in canonical
/// identity; the authoritative transcript and queue remain the only row owners.
enum ChatContentEntranceKind: Hashable, Sendable {
    case userPrompt
    case assistantContent
    case leadingActivity
    case centeredActivity
    case queuedPrompt

    static func classify(_ item: ChatTranscriptRenderItem) -> Self {
        switch item {
        case .transcript(let item):
            item.role == .user ? .userPrompt : .assistantContent
        case .message(let message):
            message.item.role == .user ? .userPrompt : .assistantContent
        case .toolRun:
            .leadingActivity
        case .notification:
            .centeredActivity
        }
    }
}

struct ChatContentEntranceTransform: Equatable, Sendable {
    enum Anchor: Equatable, Sendable {
        case leading, center, trailing
    }

    let scale: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat
    let anchor: Anchor

    static let identity = ChatContentEntranceTransform(
        scale: 1,
        offsetX: 0,
        offsetY: 0,
        anchor: .center
    )
}

enum ChatContentTransitionPolicy {
    static func hiddenTransform(
        for kind: ChatContentEntranceKind,
        reduceMotion: Bool
    ) -> ChatContentEntranceTransform {
        guard !reduceMotion else { return .identity }
        switch kind {
        case .userPrompt:
            return ChatContentEntranceTransform(
                scale: 0.955,
                offsetX: 8,
                offsetY: 18,
                anchor: .trailing
            )
        case .queuedPrompt:
            return ChatContentEntranceTransform(
                scale: 0.95,
                offsetX: 8,
                offsetY: 20,
                anchor: .trailing
            )
        case .leadingActivity:
            return ChatContentEntranceTransform(
                scale: 0.965,
                offsetX: -5,
                offsetY: 10,
                anchor: .leading
            )
        case .centeredActivity:
            return ChatContentEntranceTransform(
                scale: 0.965,
                offsetX: 0,
                offsetY: 10,
                anchor: .center
            )
        case .assistantContent:
            return ChatContentEntranceTransform(
                scale: 0.985,
                offsetX: 0,
                offsetY: 7,
                anchor: .leading
            )
        }
    }

    static func revealAnimation(
        for kind: ChatContentEntranceKind,
        reduceMotion: Bool
    ) -> Animation {
        if reduceMotion { return .easeOut(duration: 0.12) }
        switch kind {
        case .userPrompt, .queuedPrompt:
            return .spring(response: 0.40, dampingFraction: 0.86, blendDuration: 0.08)
        case .leadingActivity, .centeredActivity:
            return .spring(response: 0.34, dampingFraction: 0.84, blendDuration: 0.06)
        case .assistantContent:
            return .smooth(duration: 0.24)
        }
    }

    static func attachmentAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.34, dampingFraction: 0.86, blendDuration: 0.06)
    }
}

extension ChatContentEntranceTransform.Anchor {
    var unitPoint: UnitPoint {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// Transcript projection is published in complete snapshots while streaming.
/// Those updates must not inherit an unrelated scroll/composer transaction and
/// replay an opacity or layout animation over content that is already visible.
/// Insertions still animate through `ChatTranscriptEntranceRow`; this modifier
/// only makes updates to an installed row transaction-stable.
private struct ChatStableTranscriptUpdateModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.transaction { transaction in
            transaction.animation = nil
        }
    }
}

extension View {
    func chatStableTranscriptUpdates() -> some View {
        modifier(ChatStableTranscriptUpdateModifier())
    }
}
