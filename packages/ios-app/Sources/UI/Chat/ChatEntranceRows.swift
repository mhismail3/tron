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

private struct ChatEntranceFailsafeID: Hashable {
    let state: ChatTranscriptEntranceState
    let admissionTag: ChatTranscriptProjectionTag?
}

struct ChatTranscriptEntranceRow<Content: View>: View {
    let state: ChatTranscriptEntranceState
    let admissionTag: ChatTranscriptProjectionTag?
    let kind: ChatContentEntranceKind
    let reduceMotion: Bool
    let onFailsafeReveal: () -> Void
    @ViewBuilder let content: Content
    @State private var revealed: Bool

    init(
        state: ChatTranscriptEntranceState,
        admissionTag: ChatTranscriptProjectionTag? = nil,
        kind: ChatContentEntranceKind,
        reduceMotion: Bool,
        onFailsafeReveal: @escaping () -> Void = {},
        @ViewBuilder content: () -> Content
    ) {
        self.state = state
        self.admissionTag = admissionTag
        self.kind = kind
        self.reduceMotion = reduceMotion
        self.onFailsafeReveal = onFailsafeReveal
        self.content = content()
        _revealed = State(initialValue: state != .pending)
    }

    var body: some View {
        let hidden = ChatContentTransitionPolicy.hiddenTransform(
            for: kind,
            reduceMotion: reduceMotion
        )
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
            .task(id: ChatEntranceFailsafeID(state: state, admissionTag: admissionTag)) {
                guard state == .pending else { return }
                if !reduceMotion { try? await Task.sleep(for: .milliseconds(34)) }
                guard !Task.isCancelled, !revealed else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    revealed = true
                    onFailsafeReveal()
                }
            }
            .onChange(of: state, initial: true) { _, state in
                switch state {
                case .pending:
                    break
                case .admitted:
                    withAnimation(ChatContentTransitionPolicy.revealAnimation(
                        for: kind,
                        reduceMotion: reduceMotion
                    )) {
                        revealed = true
                    }
                case .none:
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { revealed = true }
                }
            }
    }
}

/// The ephemeral submission is the visual handoff from the composer. It owns
/// one insertion animation while it waits for canonical reconciliation; later
/// transcript snapshots update the same bubble without replaying that motion.
struct ChatOutgoingSubmissionEntranceRow<Content: View>: View {
    let reduceMotion: Bool
    let animatesEntrance: Bool
    let kind: ChatContentEntranceKind
    @ViewBuilder let content: Content
    @State private var revealed: Bool

    init(
        reduceMotion: Bool,
        animatesEntrance: Bool = true,
        kind: ChatContentEntranceKind = .userPrompt,
        @ViewBuilder content: () -> Content
    ) {
        self.reduceMotion = reduceMotion
        self.animatesEntrance = animatesEntrance
        self.kind = kind
        self.content = content()
        _revealed = State(initialValue: !animatesEntrance)
    }

    var body: some View {
        let hidden = ChatContentTransitionPolicy.hiddenTransform(
            for: kind,
            reduceMotion: reduceMotion
        )
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
            .onAppear {
                guard animatesEntrance, !revealed else { return }
                withAnimation(ChatContentTransitionPolicy.revealAnimation(
                    for: kind,
                    reduceMotion: reduceMotion
                )) {
                    revealed = true
                }
            }
            .onChange(of: animatesEntrance) { _, enabled in
                guard !enabled else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { revealed = true }
            }
    }
}

/// Canonical prompt replacement uses the same role-aware transform as a new
/// user row, but owns one explicit settling animation. This is distinct from
/// entrance bookkeeping: the prior optimistic/pending card already consumed
/// its insertion animation, so the canonical ID must not be admitted again.
struct ChatPromptLifecycleReplacementEntranceRow<Content: View>: View {
    let reduceMotion: Bool
    let kind: ChatContentEntranceKind
    @ViewBuilder let content: Content
    @State private var revealed = false

    init(
        reduceMotion: Bool,
        kind: ChatContentEntranceKind,
        @ViewBuilder content: () -> Content
    ) {
        self.reduceMotion = reduceMotion
        self.kind = kind
        self.content = content()
    }

    var body: some View {
        let hidden = ChatContentTransitionPolicy.hiddenTransform(
            for: kind,
            reduceMotion: reduceMotion
        )
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
            .onAppear {
                guard !revealed else { return }
                withAnimation(ChatContentTransitionPolicy.revealAnimation(
                    for: kind,
                    reduceMotion: reduceMotion
                )) {
                    revealed = true
                }
            }
    }
}

struct ChatQueuedMessageEntranceRow<Content: View>: View {
    let animatesEntrance: Bool
    let reduceMotion: Bool
    @ViewBuilder let content: Content
    @State private var revealed: Bool

    init(
        animatesEntrance: Bool,
        reduceMotion: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.animatesEntrance = animatesEntrance
        self.reduceMotion = reduceMotion
        self.content = content()
        _revealed = State(initialValue: !animatesEntrance)
    }

    var body: some View {
        let hidden = ChatContentTransitionPolicy.hiddenTransform(
            for: .queuedPrompt,
            reduceMotion: reduceMotion
        )
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
            .onAppear {
                guard animatesEntrance, !revealed else { return }
                withAnimation(ChatContentTransitionPolicy.revealAnimation(
                    for: .queuedPrompt,
                    reduceMotion: reduceMotion
                )) {
                    revealed = true
                }
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
    let hiddenThinkingLabel: String?
    let installationTag: ChatTranscriptProjectionTag
    let resolveToolDetails: ([String], ChatTranscriptProjectionTag) -> [ChatToolPresentation]?
    let recordToolChip: (ToolChipInstrumentationSample) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.item == rhs.item,
              lhs.preparedText.revision == rhs.preparedText.revision,
              lhs.hiddenThinkingLabel == rhs.hiddenThinkingLabel else { return false }
        guard case .toolRun = lhs.item else { return true }
        return lhs.installationTag == rhs.installationTag
    }

    @ViewBuilder var body: some View {
        switch item {
        case .transcript(let transcript):
            TranscriptRow(
                item: transcript,
                rendersToolCalls: false,
                preparedText: preparedText,
                hiddenThinkingLabel: hiddenThinkingLabel
            )
        case .message(let message):
            TranscriptRow(
                item: message.item,
                streaming: message.streaming,
                rendersToolCalls: false,
                projectedMessageParts: message.parts,
                preparedText: preparedText,
                showsMessageFooter: message.showsFooter,
                hiddenThinkingLabel: hiddenThinkingLabel
            )
        case .toolRun(let run):
            ToolRunView(
                run: run,
                installationTag: installationTag,
                resolveDetails: resolveToolDetails,
                recordChip: recordToolChip
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        case .notification(let notification):
            ChatNotificationView(presentation: notification)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
