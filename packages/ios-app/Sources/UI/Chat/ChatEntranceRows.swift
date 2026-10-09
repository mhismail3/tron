import SwiftUI

struct ChatSemanticFrameObservation: Equatable {
    let layoutEpoch: Int
    let viewportActivation: Int
    let frame: CGRect
    let entranceAdmissionTag: ChatTranscriptProjectionTag?

    init(
        layoutEpoch: Int,
        viewportActivation: Int,
        frame: CGRect,
        entranceAdmissionTag: ChatTranscriptProjectionTag? = nil
    ) {
        self.layoutEpoch = layoutEpoch
        self.viewportActivation = viewportActivation
        self.frame = frame
        self.entranceAdmissionTag = entranceAdmissionTag
    }
}

enum ChatEntranceGrowthPolicy {
    /// Liquid Glass paints shadows and interactive press expansion beyond a
    /// row's layout bounds. The entrance reveal owns only vertical admission;
    /// this transparent gutter keeps those effects out of its clip boundary.
    static let effectOverflow: CGFloat = 24
    /// A settled row's clip covers this far past its own bounds in every
    /// direction. The clip node is present at every progress — removing it at
    /// admission switched the row's view structure — so at progress 1 it must not
    /// trim any surface a row draws past its animated frame. The largest is an
    /// inline display card's expansion: its host animates from the collapsed pill
    /// to the card while the card's expanded layer keeps its natural height, so
    /// the card overhangs its own frame by up to its bounded viewport plus its
    /// header. Liquid Glass press expansion, shadows and a prompt's selection
    /// chrome fit inside that too.
    static let settledOverflow: CGFloat = DisplayInlineLayoutPolicy.maximumViewportHeight
        + DisplayInlineLayoutPolicy.controlTouchTarget
        + effectOverflow
    /// Height interpolation is a layout optimization for compact arrivals, not
    /// a transcript admission requirement. Keeping very tall rows at their
    /// natural height prevents a single large prompt or Markdown response from
    /// moving the lazy stack by tens of thousands of points per animation.
    static let maximumAnimatedHeight: CGFloat = 8_000

    static func normalizedProgress(_ progress: CGFloat) -> CGFloat {
        guard progress.isFinite else { return 0 }
        return min(1, max(0, progress))
    }

    static func height(natural: CGFloat, progress: CGFloat) -> CGFloat {
        guard natural.isFinite, natural > 0 else { return 0 }
        guard natural <= maximumAnimatedHeight else { return natural }
        // A zero-height run of pending compact pills can be culled by the
        // lazy stack before placement, preventing the geometry that admits
        // their entrance. Keep an invisible layout footprint, not a new view
        // identity or retry; opacity still hides the pending content.
        return min(natural, max(1, natural * normalizedProgress(progress)))
    }

    /// The admission clip: vertically inset while the row is still being
    /// admitted, and past every edge of the row at progress 1. The clip is
    /// applied at every progress, because removing the node at admission is what
    /// switched the row's view structure and discarded the state below it; at
    /// progress 1 it constrains neither the row's shadows nor its press region.
    static func clipRect(in bounds: CGRect, progress: CGFloat) -> CGRect {
        let normalized = normalizedProgress(progress)
        guard normalized < 1 else {
            return bounds.insetBy(dx: -settledOverflow, dy: -settledOverflow)
        }
        // Horizontal overflow stays available to native text and glass effects
        // throughout incremental growth; only the vertical admission is clipped.
        return bounds.insetBy(dx: -effectOverflow, dy: effectOverflow * (1 - normalized))
    }
}

enum ChatIncrementalContentGrowthPolicy {
    /// A large accumulated network backlog installs atomically instead of
    /// interpolating an unbounded row. Ordinary line and chip growth remains
    /// well below this limit.
    static let maximumAnimatedGrowth: CGFloat = 2_000

    static func shouldAnimate(
        currentHeight: CGFloat?,
        targetHeight: CGFloat,
        contentChanged: Bool,
        streaming: Bool,
        reduceMotion: Bool,
        surfaceActive: Bool
    ) -> Bool {
        guard let currentHeight,
              currentHeight.isFinite,
              targetHeight.isFinite,
              targetHeight > currentHeight + 0.5 else { return false }
        return contentChanged
            && streaming
            && !reduceMotion
            && surfaceActive
            && targetHeight - currentHeight <= maximumAnimatedGrowth
    }
}

private struct ChatIncrementalContentMeasurement<Identity: Equatable & Sendable>: Equatable, Sendable {
    let identity: Identity
    let width: CGFloat
    let height: CGFloat
}

/// Owns only the presentation height of an already-mounted streaming message.
/// Canonical text and controls are installed immediately at natural size, then
/// clipped by one local height while ordinary additions expand. Width changes,
/// replacement/shrink, covered surfaces, and large backlogs install atomically.
///
/// A settled row owns no height here at all: pinning one would lay the row out at
/// a stale height whenever its width, Dynamic Type or document changed, and would
/// write state on every mount for nothing. The pinned height is released when a
/// stream ends, after any growth animation still in flight completes.
struct ChatIncrementalContentGrowthHost<Identity: Equatable & Sendable, Content: View>: View {
    let identity: Identity
    let streaming: Bool
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var presentedHeight: CGFloat?
    @State private var measuredIdentity: Identity?
    @State private var measuredWidth: CGFloat?
    @State private var isAnimatingGrowth = false

    init(
        identity: Identity,
        streaming: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.identity = identity
        self.streaming = streaming
        self.content = content()
    }

    var body: some View {
        let measurementIdentity = identity
        return content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: ChatIncrementalContentMeasurement<Identity>.self) { geometry in
                ChatIncrementalContentMeasurement(
                    identity: measurementIdentity,
                    width: geometry.size.width,
                    height: geometry.size.height
                )
            } action: { measurement in
                install(measurement)
            }
            .frame(height: presentedHeight, alignment: .top)
            .chatIncrementalVerticalClip()
            .onChange(of: streaming) { _, isStreaming in
                if !isStreaming { releaseSettledHeight() }
            }
            .onChange(of: isAnimatingGrowth) { _, isAnimating in
                if !isAnimating { releaseSettledHeight() }
            }
    }

    @MainActor
    private func install(_ measurement: ChatIncrementalContentMeasurement<Identity>) {
        guard measurement.width.isFinite,
              measurement.height.isFinite,
              measurement.height >= 0 else { return }
        let contentChanged = measuredIdentity.map { $0 != measurement.identity } ?? false
        let layoutStable = measuredWidth.map { abs($0 - measurement.width) <= 0.5 } ?? false
        let animates = ChatIncrementalContentGrowthPolicy.shouldAnimate(
            currentHeight: presentedHeight,
            targetHeight: measurement.height,
            contentChanged: contentChanged && layoutStable,
            streaming: streaming,
            reduceMotion: reduceMotion,
            surfaceActive: presentationActivity.allowsContinuousAnimation
        )
        measuredIdentity = measurement.identity
        measuredWidth = measurement.width
        guard streaming || isAnimatingGrowth else {
            releaseSettledHeight()
            return
        }
        if animates {
            let animation = ChatMotion.streamingResize
            isAnimatingGrowth = true
            withAnimation(animation, completionCriteria: .logicallyComplete) {
                // The growth marker travels with the height write itself:
                // `chatStableTranscriptUpdates` reads it to keep a projection
                // change in the same update from erasing this animation.
                var transaction = Transaction(animation: animation)
                transaction.admitsChatIncrementalGrowthAnimation = true
                withTransaction(transaction) { presentedHeight = measurement.height }
            } completion: {
                isAnimatingGrowth = false
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { presentedHeight = measurement.height }
        }
    }

    /// A settled row keeps no pinned height. `onChange` re-enters through a fresh
    /// body, so this reads the current `streaming` and animation state rather
    /// than the values captured when an animation started.
    @MainActor
    private func releaseSettledHeight() {
        guard !streaming, !isAnimatingGrowth, presentedHeight != nil else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { presentedHeight = nil }
    }
}

enum ChatTranscriptEntrancePresentationPolicy {
    static func initiallyRevealed(state: ChatTranscriptEntranceState) -> Bool {
        state == .none
    }
}

private struct ChatEntranceGrowthLayout: Layout, Animatable {
    struct Cache {
        var proposedWidth: CGFloat?
        var naturalSize: CGSize?
    }

    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        // Payload and Dynamic Type changes invalidate the intrinsic measurement.
        // Animating `progress` alone does not, so the lazy row can reuse one
        // exact measurement for every frame of its short height reveal.
        cache = Cache()
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let natural = naturalSize(width: proposal.width, subview: subview, cache: &cache)
        return CGSize(
            width: proposal.width ?? natural.width,
            height: ChatEntranceGrowthPolicy.height(
                natural: natural.height,
                progress: progress
            )
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        guard let subview = subviews.first else { return }
        let natural = naturalSize(width: bounds.width, subview: subview, cache: &cache)
        subview.place(
            at: CGPoint(x: bounds.minX, y: bounds.maxY - natural.height),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: natural.height)
        )
    }

    private func naturalSize(
        width: CGFloat?,
        subview: LayoutSubview,
        cache: inout Cache
    ) -> CGSize {
        if cache.proposedWidth == width, let naturalSize = cache.naturalSize {
            return naturalSize
        }
        let measured = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
        cache.proposedWidth = width
        cache.naturalSize = measured
        return measured
    }
}

private struct ChatEntranceGrowthClipShape: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path(ChatEntranceGrowthPolicy.clipRect(in: rect, progress: progress))
    }
}

private extension View {
    /// Clips only the animated vertical admission. Horizontal overflow remains
    /// available to native text and glass effects throughout incremental growth.
    func chatIncrementalVerticalClip() -> some View {
        padding(.horizontal, ChatEntranceGrowthPolicy.effectOverflow)
            .clipShape(Rectangle())
            .padding(.horizontal, -ChatEntranceGrowthPolicy.effectOverflow)
    }

    /// Clips only the animated vertical admission. The clip node is present at
    /// every progress — a settled row's clip covers everything it can draw — so
    /// admission never switches the row's view structure and the transcript chip
    /// keeps its unconstrained Liquid Glass press-and-drag region.
    func chatEntranceGrowthClip(progress: CGFloat) -> some View {
        clipShape(ChatEntranceGrowthClipShape(progress: progress))
    }
}

enum ChatEntranceGeometryAdmissionPolicy {
    static func admits(
        observation: ChatSemanticFrameObservation,
        installedTag: ChatTranscriptProjectionTag?,
        installedContainsRenderedID: Bool,
        currentLayoutEpoch: Int,
        entranceState: ChatTranscriptEntranceState
    ) -> Bool {
        observation.entranceAdmissionTag != nil
            && observation.entranceAdmissionTag == installedTag
            && installedContainsRenderedID
            && observation.layoutEpoch == currentLayoutEpoch
            && entranceState == .pending
    }
}

struct ChatTranscriptEntranceRow<Content: View>: View {
    let state: ChatTranscriptEntranceState
    let admissionTag: ChatTranscriptProjectionTag?
    let kind: ChatContentEntranceKind
    let reduceMotion: Bool
    let onEntranceSettled: () -> Void
    @ViewBuilder let content: Content
    @State private var revealed: Bool

    init(
        state: ChatTranscriptEntranceState,
        admissionTag: ChatTranscriptProjectionTag? = nil,
        kind: ChatContentEntranceKind,
        reduceMotion: Bool,
        onEntranceSettled: @escaping () -> Void = {},
        @ViewBuilder content: () -> Content
    ) {
        self.state = state
        self.admissionTag = admissionTag
        self.kind = kind
        self.reduceMotion = reduceMotion
        self.onEntranceSettled = onEntranceSettled
        self.content = content()
        _revealed = State(initialValue: ChatTranscriptEntrancePresentationPolicy.initiallyRevealed(
            state: state
        ))
    }

    var body: some View {
        let hidden = ChatContentTransitionPolicy.hiddenTransform(
            for: kind,
            reduceMotion: reduceMotion
        )
        let progress: CGFloat = revealed || reduceMotion ? 1 : 0
        ChatEntranceGrowthLayout(progress: progress) {
            content
                .opacity(revealed ? 1 : 0)
                .scaleEffect(
                    revealed ? 1 : hidden.scale,
                    anchor: hidden.anchor.unitPoint
                )
                .offset(
                    x: revealed ? 0 : hidden.offsetX,
                    y: revealed ? 0 : hidden.offsetY
                )
        }
        .chatEntranceGrowthClip(progress: progress)
        .onChange(of: state, initial: true) { _, state in
            switch state {
            case .pending:
                break
            case .admitted:
                let animation = ChatMotion.transcriptReveal(reduceMotion: reduceMotion)
                var transaction = Transaction()
                transaction.admitsChatEntranceAnimation = true
                withTransaction(transaction) {
                    withAnimation(animation, completionCriteria: .logicallyComplete) {
                        revealed = true
                    } completion: {
                        onEntranceSettled()
                    }
                }
            case .none:
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { revealed = true }
            }
        }
    }
}

/// The ephemeral submission occupies its complete final layout immediately.
/// Only the already-sized row fades and translates straight up; later canonical
/// replacements reuse the same physical host without replaying the entrance.
struct ChatOutgoingSubmissionEntranceRow<Content: View>: View {
    static var hiddenOffset: CGFloat { 20 }

    let reduceMotion: Bool
    let animatesEntrance: Bool
    let onEntranceConsumed: () -> Void
    let onEntranceSettled: () -> Void
    @ViewBuilder let content: Content
    @State private var revealed: Bool
    @State private var reportedSettlement = false

    init(
        reduceMotion: Bool,
        animatesEntrance: Bool = true,
        onEntranceConsumed: @escaping () -> Void = {},
        onEntranceSettled: @escaping () -> Void = {},
        @ViewBuilder content: () -> Content
    ) {
        self.reduceMotion = reduceMotion
        self.animatesEntrance = animatesEntrance
        self.onEntranceConsumed = onEntranceConsumed
        self.onEntranceSettled = onEntranceSettled
        self.content = content()
        _revealed = State(initialValue: !animatesEntrance)
    }

    var body: some View {
        content
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed || reduceMotion ? 0 : Self.hiddenOffset)
            .onAppear {
                onEntranceConsumed()
                revealIfNeeded()
            }
            .onChange(of: animatesEntrance) { _, enabled in
                guard !enabled else { return }
                installRevealed()
                reportSettlementOnce()
            }
    }

    private func revealIfNeeded() {
        guard !revealed else {
            reportSettlementOnce()
            return
        }
        guard animatesEntrance else {
            installRevealed()
            reportSettlementOnce()
            return
        }
        let animation = ChatMotion.promptArrive(reduceMotion: reduceMotion)
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            var transaction = Transaction(animation: animation)
            transaction.admitsChatEntranceAnimation = true
            withTransaction(transaction) { revealed = true }
        } completion: {
            reportSettlementOnce()
        }
    }

    private func installRevealed() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { revealed = true }
    }

    private func reportSettlementOnce() {
        guard !reportedSettlement else { return }
        reportedSettlement = true
        onEntranceSettled()
    }
}

struct ChatQueuedMessageEntranceRow<Content: View>: View {
    let animatesEntrance: Bool
    let reduceMotion: Bool
    let onEntranceConsumed: () -> Void
    @ViewBuilder let content: Content
    @State private var revealed: Bool

    init(
        animatesEntrance: Bool,
        reduceMotion: Bool,
        onEntranceConsumed: @escaping () -> Void = {},
        @ViewBuilder content: () -> Content
    ) {
        self.animatesEntrance = animatesEntrance
        self.reduceMotion = reduceMotion
        self.onEntranceConsumed = onEntranceConsumed
        self.content = content()
        _revealed = State(initialValue: !animatesEntrance)
    }

    var body: some View {
        let hidden = ChatContentTransitionPolicy.hiddenTransform(
            for: .queuedPrompt,
            reduceMotion: reduceMotion
        )
        let progress: CGFloat = revealed || reduceMotion ? 1 : 0
        ChatEntranceGrowthLayout(progress: progress) {
            content
                .opacity(revealed ? 1 : 0)
                .scaleEffect(
                    revealed ? 1 : hidden.scale,
                    anchor: hidden.anchor.unitPoint
                )
                .offset(
                    x: revealed ? 0 : hidden.offsetX,
                    y: revealed ? 0 : hidden.offsetY
                )
        }
        .chatEntranceGrowthClip(progress: progress)
        .onAppear {
            onEntranceConsumed()
            guard animatesEntrance, !revealed else { return }
            var transaction = Transaction(animation: ChatMotion.transcriptReveal(reduceMotion: reduceMotion))
            transaction.admitsChatEntranceAnimation = true
            withTransaction(transaction) { revealed = true }
        }
        .onChange(of: animatesEntrance) { _, enabled in
            guard !enabled else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { revealed = true }
        }
    }
}

struct ChatTranscriptRenderRow: View, Equatable {
    let item: ChatTranscriptRenderItem
    let preparedText: ChatTextPreparationSnapshot
    /// The inline display card's disclosure phase, or the default phase for a
    /// row without a display. It is part of the row's identity because the row is
    /// `.equatable()`: an observable read below that boundary is skipped when the
    /// row's inputs are unchanged.
    let inlineDisclosurePhase: DisplayInlineDisclosureState
    let installationTag: ChatTranscriptProjectionTag
    let toolPayloadRevision: ChatToolPayloadRevision
    let resolveToolDetails: ([String]) -> [ChatToolPresentation]?
    let recordToolChip: (ToolChipInstrumentationSample) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.item == rhs.item,
              lhs.preparedText.revision == rhs.preparedText.revision,
              lhs.preparedText.hiddenThinkingLabel
                == rhs.preparedText.hiddenThinkingLabel else { return false }
        guard case .toolRun = lhs.item else { return true }
        return lhs.toolPayloadRevision == rhs.toolPayloadRevision
            && lhs.inlineDisclosurePhase == rhs.inlineDisclosurePhase
    }

    @ViewBuilder var body: some View {
        switch item {
        case .transcript(let transcript):
            TranscriptRow(
                item: transcript,
                rendersToolCalls: false,
                preparedText: preparedText
            )
        case .message(let message):
            TranscriptRow(
                item: message.item,
                streaming: message.streaming,
                rendersToolCalls: false,
                projectedMessageParts: message.parts,
                preparedText: preparedText,
                showsMessageFooter: message.showsFooter
            )
        case .toolRun(let run):
            ToolRunView(
                run: run,
                installationTag: installationTag,
                resolveDetails: { callIDs, _ in resolveToolDetails(callIDs) },
                recordChip: recordToolChip,
                inlineDisclosurePhase: inlineDisclosurePhase
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        case .notification(let notification):
            ChatNotificationView(presentation: notification)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
