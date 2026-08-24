import SwiftUI

/// The composer remains one bottom inset owner. Fixed surfaces, especially the
/// input bar, are measured first; the resource picker receives only the finite
/// height left by the keyboard-reduced container.
struct ChatComposerLayoutAllocation: Equatable, Sendable {
    let flexibleHeight: CGFloat
    let totalHeight: CGFloat
}

enum ChatComposerLayoutPolicy {
    static func allocation(
        maximumHeight: CGFloat?,
        fixedHeight: CGFloat,
        desiredFlexibleHeight: CGFloat,
        fixedSurfaceCount: Int,
        spacing: CGFloat
    ) -> ChatComposerLayoutAllocation {
        let safeFixedHeight = fixedHeight.isFinite ? max(0, fixedHeight) : 0
        let safeDesiredHeight = desiredFlexibleHeight.isFinite
            ? max(0, desiredFlexibleHeight)
            : 0
        let safeSpacing = spacing.isFinite ? max(0, spacing) : 0
        let safeFixedCount = max(0, fixedSurfaceCount)
        let flexibleSpacing = safeDesiredHeight > 0 && safeFixedCount > 0 ? safeSpacing : 0
        let fixedSpacing = safeSpacing * CGFloat(max(0, safeFixedCount - 1))
        let unconstrainedTotal = safeFixedHeight + fixedSpacing
            + flexibleSpacing + safeDesiredHeight
        guard let maximumHeight,
              maximumHeight.isFinite,
              maximumHeight >= 0 else {
            return ChatComposerLayoutAllocation(
                flexibleHeight: safeDesiredHeight,
                totalHeight: unconstrainedTotal
            )
        }
        let flexibleHeight = min(
            safeDesiredHeight,
            max(0, maximumHeight - safeFixedHeight - fixedSpacing - flexibleSpacing)
        )
        let actualFlexibleSpacing = flexibleHeight > 0 ? flexibleSpacing : 0
        return ChatComposerLayoutAllocation(
            flexibleHeight: flexibleHeight,
            totalHeight: min(
                maximumHeight,
                safeFixedHeight + fixedSpacing + actualFlexibleSpacing + flexibleHeight
            )
        )
    }
}

private enum ChatComposerLayoutRole: Equatable {
    case fixed
    case flexible
}

private struct ChatComposerLayoutRoleKey: LayoutValueKey {
    static let defaultValue = ChatComposerLayoutRole.fixed
}

extension View {
    func chatFlexibleComposerSurface() -> some View {
        layoutValue(key: ChatComposerLayoutRoleKey.self, value: .flexible)
    }
}

struct ChatComposerLayout: Layout {
    let maximumHeight: CGFloat?
    let spacing: CGFloat

    private struct Measurement {
        let sizes: [CGSize]
        let allocation: ChatComposerLayoutAllocation
        let width: CGFloat
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let measurement = measure(proposal: proposal, subviews: subviews)
        return CGSize(width: measurement.width, height: measurement.allocation.totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let measurement = measure(
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height),
            subviews: subviews
        )
        let placedSizes = subviews.enumerated().map { index, subview in
            var size = measurement.sizes[index]
            if subview[ChatComposerLayoutRoleKey.self] == .flexible {
                size.height = measurement.allocation.flexibleHeight
            }
            return size
        }
        let visibleCount = placedSizes.count { $0.height > 0 }
        let placedHeight = placedSizes.reduce(CGFloat.zero) { partial, size in
            partial + max(0, size.height)
        } + spacing * CGFloat(max(0, visibleCount - 1))

        // Bottom placement keeps the input bar installed above the keyboard.
        // Under an unexpectedly tiny proposal, fixed pills may extend upward
        // rather than pushing the input below or clipping it at the host edge.
        var y = bounds.maxY - placedHeight
        var placedVisibleSurface = false
        for (index, subview) in subviews.enumerated() {
            let size = placedSizes[index]
            guard size.height > 0 else { continue }
            if placedVisibleSurface { y += spacing }
            subview.place(
                at: CGPoint(x: bounds.midX, y: y),
                anchor: .top,
                proposal: ProposedViewSize(width: bounds.width, height: size.height)
            )
            y += size.height
            placedVisibleSurface = true
        }
    }

    private func measure(proposal: ProposedViewSize, subviews: Subviews) -> Measurement {
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil }
        var sizes: [CGSize] = []
        sizes.reserveCapacity(subviews.count)
        var fixedHeight: CGFloat = 0
        var fixedSurfaceCount = 0
        var desiredFlexibleHeight: CGFloat = 0
        var measuredWidth: CGFloat = width ?? 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            sizes.append(size)
            measuredWidth = max(measuredWidth, size.width)
            if subview[ChatComposerLayoutRoleKey.self] == .flexible {
                desiredFlexibleHeight = max(desiredFlexibleHeight, size.height)
            } else if size.height > 0 {
                fixedHeight += size.height
                fixedSurfaceCount += 1
            }
        }
        let proposedMaximum = proposal.height.flatMap { $0.isFinite ? max(0, $0) : nil }
        let finiteMaximum: CGFloat? = switch (maximumHeight, proposedMaximum) {
        case let (configured?, proposed?): min(max(0, configured), proposed)
        case let (configured?, nil): configured.isFinite ? max(0, configured) : nil
        case let (nil, proposed?): proposed
        case (nil, nil): nil
        }
        return Measurement(
            sizes: sizes,
            allocation: ChatComposerLayoutPolicy.allocation(
                maximumHeight: finiteMaximum,
                fixedHeight: fixedHeight,
                desiredFlexibleHeight: desiredFlexibleHeight,
                fixedSurfaceCount: fixedSurfaceCount,
                spacing: spacing
            ),
            width: measuredWidth
        )
    }
}

struct ChatComposerStructuralHost<Content: View>: View {
    let maximumHeight: CGFloat?
    let onHeightChange: ((CGFloat) -> Void)?
    @ViewBuilder let content: () -> Content

    init(
        maximumHeight: CGFloat? = nil,
        onHeightChange: ((CGFloat) -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.maximumHeight = maximumHeight
        self.onHeightChange = onHeightChange
        self.content = content
    }

    var body: some View {
        content()
            .frame(maxHeight: maximumHeight, alignment: .bottom)
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

    static func attachmentAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion
            ? nil
            : .spring(response: 0.34, dampingFraction: 0.86, blendDuration: 0.06)
    }

    static func composerSurfaceAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.24)
    }

    static func composerSurfaceTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }
        return .move(edge: .bottom).combined(with: .opacity)
    }

    static func attachmentTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }
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
