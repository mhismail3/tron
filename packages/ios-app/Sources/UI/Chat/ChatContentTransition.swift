import SwiftUI

/// Presentation-only motion roles for content entering an already-installed chat.
/// These values never create transcript continuity or participate in canonical
/// identity; the authoritative transcript and queue remain the only row owners.
struct ChatComposerStructuralIdentity: Hashable, Sendable {
    let extensionOwnerIDs: [String]
    let attachmentIDs: [String]
    let selectedSkillID: String?
    let pickerKind: ComposerResourceEntry.Kind?
    let pickerVisibleRows: Int
    let submissionPending: Bool
}

struct ChatComposerStructuralMeasurement: Equatable {
    let identity: ChatComposerStructuralIdentity
    let height: CGFloat
}

enum ChatComposerStructuralTransitionPolicy {
    static let heightEpsilon: CGFloat = 0.5
    static let settlementDelay: Duration = .milliseconds(380)

    static func isStructuralRetarget(
        previous: ChatComposerStructuralMeasurement?,
        current: ChatComposerStructuralMeasurement
    ) -> Bool {
        guard let previous else { return false }
        return previous.identity != current.identity
    }

    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion
            ? nil
            : .smooth(duration: 0.34)
    }
}

/// Permanently mounted aggregate composer viewport. Its inner content keeps its
/// natural size for measurement while this bottom-aligned frame exposes the new
/// height continuously, so the sole safe-area inset and the accessory content
/// share one geometry curve. A retargeted spring starts from the current
/// presentation value; ordinary multiline measurements update directly.
struct ChatComposerStructuralHost<Content: View>: View {
    let identity: ChatComposerStructuralIdentity
    let reduceMotion: Bool
    let transitionWillBegin: () -> Int?
    let transitionDidSettle: (Int) -> Void
    @ViewBuilder let content: () -> Content

    @State private var presentedHeight: CGFloat?
    @State private var previousMeasurement: ChatComposerStructuralMeasurement?
    @State private var settlementTask: Task<Void, Never>?

    var body: some View {
        content()
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: ChatComposerStructuralMeasurement.self) { geometry in
                ChatComposerStructuralMeasurement(identity: identity, height: geometry.size.height)
            } action: { measurement in
                admit(measurement)
            }
            .frame(height: presentedHeight, alignment: .bottom)
            .clipped()
            .onDisappear {
                settlementTask?.cancel()
                settlementTask = nil
            }
    }

    private func admit(_ measurement: ChatComposerStructuralMeasurement) {
        guard measurement.height.isFinite, measurement.height > 0 else { return }
        guard let previousMeasurement else {
            self.previousMeasurement = measurement
            presentedHeight = measurement.height
            return
        }
        let retargets = ChatComposerStructuralTransitionPolicy.isStructuralRetarget(
            previous: previousMeasurement,
            current: measurement
        )
        self.previousMeasurement = measurement
        guard retargets else {
            if abs((presentedHeight ?? measurement.height) - measurement.height)
                > ChatComposerStructuralTransitionPolicy.heightEpsilon {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { presentedHeight = measurement.height }
            }
            return
        }

        let generation = transitionWillBegin()
        withAnimation(ChatComposerStructuralTransitionPolicy.animation(reduceMotion: reduceMotion)) {
            presentedHeight = measurement.height
        }
        settlementTask?.cancel()
        guard let generation else { return }
        if reduceMotion {
            transitionDidSettle(generation)
            return
        }
        settlementTask = Task { @MainActor in
            do { try await Task.sleep(for: ChatComposerStructuralTransitionPolicy.settlementDelay) }
            catch { return }
            guard !Task.isCancelled else { return }
            transitionDidSettle(generation)
            settlementTask = nil
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
