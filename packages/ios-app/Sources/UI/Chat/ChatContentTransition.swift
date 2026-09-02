import SwiftUI

/// The composer is one permanently mounted inset owner. Editor-only height
/// changes remain atomic for UIKit caret ownership. Accessory insertion and
/// removal receives one value-scoped smooth transition through that same owner.
@MainActor
final class ChatComposerHeightLedger {
    private(set) var current: CGFloat = 0

    func install(_ height: CGFloat) {
        guard height.isFinite, height >= 0 else { return }
        current = height
    }
}

struct ChatComposerAccessoryLayoutIdentity: Equatable {
    let attachmentIDs: [String]
    let selectedResourceID: String?
    let resourcePickerKind: ComposerResourceEntry.Kind?
    let resourceResultIDs: [String]
}

enum ChatComposerStructuralTransitionPolicy {
    static let heightEpsilon: CGFloat = 0.5
    static let accessoryDuration: TimeInterval = 0.24

    static func admitsHeightChange(current: CGFloat?, measured: CGFloat) -> Bool {
        measured.isFinite
            && measured > 0
            && current.map { abs($0 - measured) > heightEpsilon } != false
    }

    static func animatesAccessoryHeight(
        current: CGFloat?,
        installedIdentity: ChatComposerAccessoryLayoutIdentity?,
        identity: ChatComposerAccessoryLayoutIdentity,
        reduceMotion: Bool
    ) -> Bool {
        current != nil
            && installedIdentity != identity
            && !reduceMotion
    }
}

struct ChatComposerStructuralHost<Content: View>: View {
    let accessoryIdentity: ChatComposerAccessoryLayoutIdentity
    let reduceMotion: Bool
    let onHeightChange: ((CGFloat) -> Void)?
    let onHeightSettled: ((CGFloat) -> Void)?
    @ViewBuilder let content: () -> Content

    @State private var presentedHeight: CGFloat?
    @State private var installedAccessoryIdentity: ChatComposerAccessoryLayoutIdentity?

    init(
        accessoryIdentity: ChatComposerAccessoryLayoutIdentity,
        reduceMotion: Bool,
        onHeightChange: ((CGFloat) -> Void)? = nil,
        onHeightSettled: ((CGFloat) -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.accessoryIdentity = accessoryIdentity
        self.reduceMotion = reduceMotion
        self.onHeightChange = onHeightChange
        self.onHeightSettled = onHeightSettled
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
                let animatesAccessory = ChatComposerStructuralTransitionPolicy.animatesAccessoryHeight(
                    current: presentedHeight,
                    installedIdentity: installedAccessoryIdentity,
                    identity: accessoryIdentity,
                    reduceMotion: reduceMotion
                )
                installedAccessoryIdentity = accessoryIdentity
                if animatesAccessory {
                    withAnimation(
                        .smooth(duration: ChatComposerStructuralTransitionPolicy.accessoryDuration),
                        completionCriteria: .logicallyComplete
                    ) {
                        presentedHeight = height
                    } completion: {
                        onHeightSettled?(height)
                    }
                } else {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { presentedHeight = height }
                    onHeightSettled?(height)
                }
            }
            .frame(height: presentedHeight, alignment: .bottom)
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
    /// Height-coupled transcript entrances share one short, non-overshooting
    /// clock. Spring overshoot is inappropriate here because growth progress is
    /// clamped to layout bounds and can otherwise settle through visible stalls.
    static let transcriptEntranceDuration: TimeInterval = 0.18
    static let promptEntranceDuration: TimeInterval = transcriptEntranceDuration
    static let promptFlightDuration: TimeInterval = 0.18
    static let promptReplacementDuration: TimeInterval = 0.14
    static let notificationReplacementDuration: TimeInterval = 0.16
    static let attachmentHiddenScale: CGFloat = 0.5
    static let attachmentStaggerInterval: TimeInterval = 0.04

    static func attachmentInsertionIDs(current: [String], target: [String]) -> [String] {
        let installed = Set(current)
        return target.filter { !installed.contains($0) }
    }

    static func hiddenTransform(
        for kind: ChatContentEntranceKind,
        reduceMotion: Bool
    ) -> ChatContentEntranceTransform {
        guard !reduceMotion else { return .identity }
        switch kind {
        case .userPrompt:
            return ChatContentEntranceTransform(
                scale: 0.98,
                offsetX: 4,
                offsetY: 10,
                anchor: .trailing
            )
        case .queuedPrompt:
            return ChatContentEntranceTransform(
                scale: 0.978,
                offsetX: 4,
                offsetY: 12,
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
        for _: ChatContentEntranceKind,
        reduceMotion: Bool
    ) -> Animation {
        if reduceMotion { return .easeOut(duration: 0.12) }
        // Layout height and the visual transform must advance on the same
        // monotonic curve. This keeps native bottom anchoring continuous while
        // avoiding a spring's clamped overshoot for tool/status insertions.
        return .smooth(duration: transcriptEntranceDuration)
    }

    static func attachmentAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .smooth(duration: 0.22)
    }

    static func promptFlightAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: promptFlightDuration)
    }

    static func notificationReplacementAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? .linear(duration: 0.10) : .smooth(duration: notificationReplacementDuration)
    }

    static func composerSurfaceAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.36, dampingFraction: 0.86, blendDuration: 0.06)
    }

    static let composerSurfaceRemovalEdge: Edge = .bottom

    static func composerSurfaceTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .bottom)
                .combined(with: .scale(scale: 0.97, anchor: .bottom))
                .combined(with: .opacity),
            removal: .move(edge: composerSurfaceRemovalEdge).combined(with: .opacity)
        )
    }

    static func attachmentTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .scale(scale: attachmentHiddenScale, anchor: .center)
            .combined(with: .opacity)
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

/// Complete transcript snapshots install atomically while explicitly tagged row,
/// prompt, tool-chip, and continuous native-control animations pass through.
private enum ChatToolChipAnimationTransactionKey: TransactionKey {
    static let defaultValue = false
}

private enum ChatEntranceAnimationTransactionKey: TransactionKey {
    static let defaultValue = false
}

private enum ChatPromptReplacementAnimationTransactionKey: TransactionKey {
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

    var admitsChatPromptReplacementAnimation: Bool {
        get { self[ChatPromptReplacementAnimationTransactionKey.self] }
        set { self[ChatPromptReplacementAnimationTransactionKey.self] = newValue }
    }
}

enum ChatPromptReplacementAnimationPolicy {
    static func animates(reduceMotion: Bool) -> Bool { !reduceMotion }

    static func animation(reduceMotion: Bool) -> Animation? {
        guard animates(reduceMotion: reduceMotion) else { return nil }
        return .smooth(duration: ChatContentTransitionPolicy.promptReplacementDuration)
    }
}

private struct ChatStableTranscriptUpdateModifier<ProjectionIdentity: Equatable>: ViewModifier {
    let projectionIdentity: ProjectionIdentity

    func body(content: Content) -> some View {
        content.transaction(value: projectionIdentity) { transaction in
            // Suppress inherited animation only when the installed projection
            // changes. Native Liquid Glass begins with a discrete touch-down
            // transaction before its continuous drag updates; an unconditional
            // transaction transform was erasing that first animation.
            if !transaction.admitsChatToolChipAnimation,
               !transaction.admitsChatEntranceAnimation,
               !transaction.admitsChatPromptReplacementAnimation {
                transaction.animation = nil
            }
        }
    }
}

extension View {
    func chatStableTranscriptUpdates<ProjectionIdentity: Equatable>(
        projectionIdentity: ProjectionIdentity
    ) -> some View {
        modifier(ChatStableTranscriptUpdateModifier(
            projectionIdentity: projectionIdentity
        ))
    }
}
