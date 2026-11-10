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
    static let effectOverflow: CGFloat = 24
    static let settledOverflow: CGFloat = DisplayInlineLayoutPolicy.maximumViewportHeight
        + DisplayInlineLayoutPolicy.controlTouchTarget
        + effectOverflow
    static let maximumAnimatedHeight: CGFloat = 8_000

    static func normalizedProgress(_ progress: CGFloat) -> CGFloat {
        guard progress.isFinite else { return 0 }
        return min(1, max(0, progress))
    }

    static func height(natural: CGFloat, progress: CGFloat) -> CGFloat {
        guard natural.isFinite, natural > 0 else { return 0 }
        guard natural <= maximumAnimatedHeight else { return natural }
        return min(natural, max(1, natural * normalizedProgress(progress)))
    }

    static func clipRect(in bounds: CGRect, progress: CGFloat) -> CGRect {
        let normalized = normalizedProgress(progress)
        guard normalized < 1 else {
            return bounds.insetBy(dx: -settledOverflow, dy: -settledOverflow)
        }
        return bounds.insetBy(dx: -effectOverflow, dy: effectOverflow * (1 - normalized))
    }
}

enum ChatIncrementalContentGrowthPolicy {
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
    func chatIncrementalVerticalClip() -> some View {
        padding(.horizontal, ChatEntranceGrowthPolicy.effectOverflow)
            .clipShape(Rectangle())
            .padding(.horizontal, -ChatEntranceGrowthPolicy.effectOverflow)
    }

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
    let installationTag: ChatTranscriptProjectionTag
    let toolPayloadRevision: ChatToolPayloadRevision
    let resolveToolDetails: ([String]) -> [ChatToolPresentation]?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.item == rhs.item,
              lhs.preparedText.revision == rhs.preparedText.revision,
              lhs.preparedText.hiddenThinkingLabel
                == rhs.preparedText.hiddenThinkingLabel else { return false }
        guard case .toolRun = lhs.item else { return true }
        return lhs.toolPayloadRevision == rhs.toolPayloadRevision
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
                resolveDetails: { callIDs, _ in resolveToolDetails(callIDs) }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        case .notification(let notification):
            ChatNotificationView(presentation: notification)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
