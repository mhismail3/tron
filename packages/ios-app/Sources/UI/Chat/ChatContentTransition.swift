import SwiftUI

/// The composer is one permanently mounted inset owner. Its children may use
/// local opacity/scale/offset feedback, but its structural height is installed in one
/// nonanimated transaction. Animating the safe-area inset forces the native
/// transcript viewport through a layout on every animation frame, which can
/// redraw already-visible rows and expose them beneath navigation chrome.
enum ChatComposerStructuralTransitionPolicy {
    static let heightEpsilon: CGFloat = 0.5

    static func admitsHeightChange(current: CGFloat?, measured: CGFloat) -> Bool {
        measured.isFinite
            && measured > 0
            && current.map { abs($0 - measured) > heightEpsilon } != false
    }
}

struct ChatComposerStructuralHost<Content: View>: View {
    let onHeightChange: ((CGFloat) -> Void)?
    @ViewBuilder let content: () -> Content

    @State private var presentedHeight: CGFloat?

    init(
        onHeightChange: ((CGFloat) -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.onHeightChange = onHeightChange
        self.content = content
    }

    var body: some View {
        content()
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                guard ChatComposerStructuralTransitionPolicy.admitsHeightChange(
                    current: presentedHeight,
                    measured: height
                ) else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { presentedHeight = height }
            }
            .frame(height: presentedHeight, alignment: .bottom)
            .clipped()
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                guard height.isFinite, height >= 0 else { return }
                onHeightChange?(height)
            }
    }
}

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

enum ChatPromptLifecycleTransitionPolicy {
    static func entranceKind(for behavior: ChatPromptBehavior) -> ChatContentEntranceKind {
        behavior.isQueuedKind ? .queuedPrompt : .userPrompt
    }

    static func shouldAnimateQueueEntrance(
        isReady: Bool,
        entranceSuppressed: Bool,
        hasIdentityAlias: Bool
    ) -> Bool {
        isReady && !entranceSuppressed && !hasIdentityAlias
    }

    static func shouldAnimateUserEntrance(
        isReady: Bool,
        entranceSuppressed: Bool
    ) -> Bool {
        isReady && !entranceSuppressed
    }

    static func suppressesQueueReplacement(
        pendingOperationID: String,
        authoritativeQueueIDs: Set<String>
    ) -> Bool {
        authoritativeQueueIDs.contains(pendingOperationID)
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

    static func composerSurfaceAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.36, dampingFraction: 0.86, blendDuration: 0.06)
    }

    static func composerSurfaceTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .bottom)
                .combined(with: .scale(scale: 0.97, anchor: .bottom))
                .combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity)
        )
    }

    static func attachmentTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .bottom)
                .combined(with: .scale(scale: 0.92, anchor: .bottom))
                .combined(with: .opacity),
            removal: .move(edge: .top)
                .combined(with: .scale(scale: 0.94, anchor: .top))
                .combined(with: .opacity)
        )
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
/// The modifier may own the structural transcript stack; explicitly tagged row
/// entrances and shallow tool-chip transactions still pass through it.
private enum ChatToolChipAnimationTransactionKey: TransactionKey {
    static let defaultValue = false
}

private enum ChatEntranceAnimationTransactionKey: TransactionKey {
    static let defaultValue = false
}

extension Transaction {
    var admitsChatToolChipAnimation: Bool {
        get { self[ChatToolChipAnimationTransactionKey.self] }
        set { self[ChatToolChipAnimationTransactionKey.self] = newValue }
    }

    var admitsChatEntranceAnimation: Bool {
        get { self[ChatEntranceAnimationTransactionKey.self] }
        set { self[ChatEntranceAnimationTransactionKey.self] = newValue }
    }
}

private struct ChatStableTranscriptUpdateModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.transaction { transaction in
            // Projection replacements must not inherit ambient layout motion,
            // but continuous direct manipulation belongs to the system control
            // beneath this boundary. Clearing that transaction makes native
            // interactive glass jump to its pressed scale before its drag morph.
            if !transaction.admitsChatToolChipAnimation,
               !transaction.admitsChatEntranceAnimation,
               !transaction.isContinuous {
                transaction.animation = nil
            }
        }
    }
}

extension View {
    func chatStableTranscriptUpdates() -> some View {
        modifier(ChatStableTranscriptUpdateModifier())
    }
}
