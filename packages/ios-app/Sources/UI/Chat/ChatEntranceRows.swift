import SwiftUI

struct ChatSemanticFrameObservation: Equatable {
    let layoutEpoch: Int
    let frame: CGRect
    let entranceAdmissionTag: ChatTranscriptProjectionTag?

    init(
        layoutEpoch: Int,
        frame: CGRect,
        entranceAdmissionTag: ChatTranscriptProjectionTag? = nil
    ) {
        self.layoutEpoch = layoutEpoch
        self.frame = frame
        self.entranceAdmissionTag = entranceAdmissionTag
    }
}

enum ChatEntranceGrowthPolicy {
    /// Liquid Glass paints shadows and interactive press expansion beyond a
    /// row's layout bounds. The entrance reveal owns only vertical admission;
    /// this transparent gutter keeps those effects out of its clip boundary.
    static let effectOverflow: CGFloat = 24
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
        return natural * normalizedProgress(progress)
    }

    static func requiresClip(progress: CGFloat) -> Bool {
        normalizedProgress(progress) < 1
    }

    static func clipRect(in bounds: CGRect, progress: CGFloat) -> CGRect {
        let hiddenVerticalOverflow = effectOverflow * (1 - normalizedProgress(progress))
        return bounds.insetBy(dx: 0, dy: hiddenVerticalOverflow)
    }
}

enum ChatIncrementalContentGrowthPolicy {
    static let duration = ChatScrollCoordinator.liveGrowthAnimationDuration
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

private struct ChatIncrementalContentMeasurement<Identity: Equatable>: Equatable {
    let identity: Identity
    let width: CGFloat
    let height: CGFloat
}

/// Owns only the presentation height of an already-mounted streaming message.
/// Canonical text and controls are installed immediately at natural size, then
/// clipped by one local height while ordinary additions expand. Width changes,
/// replacement/shrink, covered surfaces, and large backlogs install atomically.
struct ChatIncrementalContentGrowthHost<Identity: Equatable, Content: View>: View {
    let identity: Identity
    let streaming: Bool
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var presentedHeight: CGFloat?
    @State private var measuredIdentity: Identity?
    @State private var measuredWidth: CGFloat?

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
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: ChatIncrementalContentMeasurement<Identity>.self) { geometry in
                ChatIncrementalContentMeasurement(
                    identity: identity,
                    width: geometry.size.width,
                    height: geometry.size.height
                )
            } action: { measurement in
                install(measurement)
            }
            .frame(height: presentedHeight, alignment: .top)
            .chatIncrementalVerticalClip()
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
        if animates {
            var transaction = Transaction(animation: .smooth(
                duration: ChatIncrementalContentGrowthPolicy.duration
            ))
            transaction.admitsChatIncrementalGrowthAnimation = true
            withTransaction(transaction) { presentedHeight = measurement.height }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { presentedHeight = measurement.height }
        }
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

    /// Keeps the measured-height entrance vertically bounded while preserving
    /// the natural horizontal shadow and press-morph region. Vertical overflow
    /// joins continuously as the row reaches its full admitted height.
    @ViewBuilder
    func chatEntranceGrowthClip(progress: CGFloat) -> some View {
        if ChatEntranceGrowthPolicy.requiresClip(progress: progress) {
            padding(ChatEntranceGrowthPolicy.effectOverflow)
                .clipShape(ChatEntranceGrowthClipShape(progress: progress))
                .padding(-ChatEntranceGrowthPolicy.effectOverflow)
        } else {
            // Once admission settles, remove the clipping node entirely. The
            // transcript chip then has its unconstrained native Liquid Glass
            // press-and-drag region.
            self
        }
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
                let animation = ChatContentTransitionPolicy.revealAnimation(
                    for: kind,
                    reduceMotion: reduceMotion
                )
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
        let animation = Animation.easeOut(
            duration: reduceMotion ? 0.12 : ChatContentTransitionPolicy.promptEntranceDuration
        )
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
            var transaction = Transaction(animation: ChatContentTransitionPolicy.revealAnimation(
                for: .queuedPrompt,
                reduceMotion: reduceMotion
            ))
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
    let installationTag: ChatTranscriptProjectionTag
    let toolPayloadRevision: ChatToolPayloadRevision
    let resolveToolDetails: ([String]) -> [ChatToolPresentation]?
    let recordEvaluation: () -> Void
    let recordToolChip: (ToolChipInstrumentationSample) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.item == rhs.item,
              lhs.preparedText.revision == rhs.preparedText.revision,
              lhs.preparedText.hiddenThinkingLabel
                == rhs.preparedText.hiddenThinkingLabel else { return false }
        guard case .toolRun = lhs.item else { return true }
        return lhs.toolPayloadRevision == rhs.toolPayloadRevision
    }

    @ViewBuilder var body: some View {
        let _ = recordEvaluation()
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
                recordChip: recordToolChip
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        case .notification(let notification):
            ChatNotificationView(presentation: notification)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
