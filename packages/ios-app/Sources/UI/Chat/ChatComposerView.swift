import SwiftUI

/// Value-driven composer presentation. Draft, route, transport, and canonical
/// ownership remain outside this view and enter only through bindings/intents.
struct ChatComposerView: View {
    let sessionFacts: ChatVisibleSessionFacts?
    let processOverview: SessionProcessOverview?
    let processActivities: [SessionProcessActivity]?
    let pendingAttachments: [PendingAttachment]
    let selectedResource: ComposerResourceEntry?
    let resourcePicker: ComposerResourcePickerSource?
    let resourceResults: [ComposerResourceEntry]
    let morphRegistry: ChatMorphFrameRegistry
    let reduceMotion: Bool
    let showsCatchUp: Bool
    let showsAmbientWorkingBlur: Bool
    let keyboardVisible: Bool
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var selection: NSRange
    let responder: ChatComposerResponder
    let isEditable: Bool
    let keyboardAppearance: UIKeyboardAppearance
    let contextProgress: SessionContextProgressPresentation
    let trailingMode: ComposerTrailingMode?
    let isSending: Bool
    let submissionPending: Bool
    let hasActiveUploads: Bool
    let isTranscriptReady: Bool
    let isCommandReady: Bool
    let attachmentMenuState: ChatAttachmentMenuState
    let attachmentActionsEnabled: Bool
    let resourcePickerAvailable: Bool
    let glassNamespace: Namespace.ID

    let onProcessesTap: () -> Void
    let onRemoveAttachment: (String) -> Void
    let onRemoveResource: () -> Void
    let onSelectResource: (ComposerResourceEntry) -> Void
    let onDismissResourcePicker: () -> Void
    let onShowContext: () -> Void
    let onSend: (String?) -> Void
    let onAbort: () -> Void
    let onSelectAttachmentDestination: @MainActor @Sendable (ChatAttachmentDestination) -> Void
    let onCatchUp: () -> Void
    let onComposerHeight: (CGFloat) -> Void
    let onComposerHeightSettled: (CGFloat) -> Void

    var body: some View {
        ChatComposerStructuralHost(
            accessoryIdentity: ChatComposerAccessoryLayoutIdentity(
                attachmentIDs: pendingAttachments.map(\.id),
                selectedResourceID: selectedResource?.id,
                resourcePickerKind: resourcePicker?.kind,
                resourceResultIDs: resourceResults.map(\.id)
            ),
            reduceMotion: reduceMotion,
            onHeightChange: onComposerHeight,
            onHeightSettled: onComposerHeightSettled
        ) {
            VStack(spacing: 10) {
                attachmentStrip
                selectedResourceStrip
                resourcePickerView
                GlassEffectContainer(spacing: 8) {
                    HStack(alignment: .bottom, spacing: 8) {
                        if let overview = processOverview,
                           processActivities?.contains(where: {
                               $0.kind == .subagent && SessionProcessAdmissionPolicy.admits($0)
                           }) == true {
                            SessionProcessButton(
                                overview: overview,
                                glassNamespace: glassNamespace,
                                reduceMotion: reduceMotion,
                                onTap: onProcessesTap
                            )
                        }
                        inputBar
                        if showsCatchUp { catchUpButton }
                    }
                }
                .animation(
                    reduceMotion
                        ? .easeOut(duration: 0.12)
                        : .spring(response: 0.32, dampingFraction: 0.82),
                    value: showsCatchUp
                )
                .animation(
                    reduceMotion
                        ? .easeOut(duration: 0.12)
                        : .spring(response: 0.32, dampingFraction: 0.82),
                    value: processOverview?.visibility
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            // Structural height remains atomic in ChatComposerStructuralHost.
            // These value-scoped transactions animate only newly inserted or
            // removed child surfaces inside the already-installed space.
            .animation(
                ChatContentTransitionPolicy.attachmentAnimation(reduceMotion: reduceMotion),
                value: pendingAttachments.map(\.id)
            )
            .animation(
                ChatContentTransitionPolicy.composerSurfaceAnimation(reduceMotion: reduceMotion),
                value: selectedResource?.id
            )
            .animation(
                ChatContentTransitionPolicy.composerSurfaceAnimation(reduceMotion: reduceMotion),
                value: resourcePicker?.kind
            )
        }
        .background(alignment: .bottom) {
            ChatBottomActivityBlur(
                isActive: showsAmbientWorkingBlur,
                keyboardVisible: keyboardVisible
            )
            .offset(y: ChatBottomActivityBlurLayout.translation(keyboardVisible: keyboardVisible))
            .ignoresSafeArea(edges: .bottom)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: keyboardVisible)
        }
    }

    private var attachmentStrip: some View {
        ChatPendingAttachmentStrip(
            attachments: pendingAttachments,
            morphRegistry: morphRegistry,
            reduceMotion: reduceMotion,
            onRemove: onRemoveAttachment
        )
    }

    @ViewBuilder
    private var selectedResourceStrip: some View {
        if let selectedResource {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ComposerResourceChip(
                        sessionID: sessionFacts?.sessionID,
                        resource: selectedResource,
                        onRemove: onRemoveResource
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
            .transition(ChatContentTransitionPolicy.composerSurfaceTransition(
                reduceMotion: reduceMotion
            ))
        }
    }

    @ViewBuilder
    private var resourcePickerView: some View {
        if let resourcePicker {
            ComposerResourcePicker(
                sessionID: sessionFacts?.sessionID,
                kind: resourcePicker.kind,
                query: resourcePicker.query,
                entries: resourceResults,
                keyboardVisible: keyboardVisible,
                onSelect: onSelectResource,
                onDismiss: onDismissResourcePicker
            )
            .padding(.horizontal, 16)
            .transition(ChatContentTransitionPolicy.composerSurfaceTransition(
                reduceMotion: reduceMotion
            ))
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 4) {
            attachmentButton
            ZStack(alignment: .leading) {
                if text.isEmpty && !isFocused {
                    Text("Type here")
                        .font(TronTypography.input)
                        .foregroundStyle(Color.tronEmerald)
                        .opacity(isTranscriptReady ? 1 : 0.38)
                        .padding(.leading, 2)
                        .padding(.vertical, 10)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
                MultilineComposerTextView(
                    text: $text,
                    isFocused: $isFocused,
                    selection: $selection,
                    responder: responder,
                    isEditable: isEditable,
                    keyboardAppearance: keyboardAppearance,
                    maximumLines: ComposerResourcePanelPolicy.editorLines(
                        panelPresented: resourcePicker != nil,
                        keyboardVisible: keyboardVisible
                    )
                )
                .padding(.horizontal, 2)
                .padding(.vertical, 10)
            }
            .frame(minHeight: 40)
            .chatDraftPromptMorphSource(registry: morphRegistry)

            SessionContextProgressButton(presentation: contextProgress, onTap: onShowContext)

            if let trailingMode {
                ComposerTrailingButton(
                    mode: trailingMode,
                    isDisabled: isSending || submissionPending || hasActiveUploads || !isCommandReady,
                    isSending: isSending,
                    offersQueueChoices: sessionFacts?.phase.isActive == true,
                    onSend: onSend,
                    onAbort: onAbort
                )
                .transition(
                    reduceMotion
                        ? .opacity
                        : .scale(scale: 0.78, anchor: .center).combined(with: .opacity)
                )
            }
        }
        .animation(
            reduceMotion
                ? .easeOut(duration: 0.12)
                : .spring(response: 0.32, dampingFraction: 0.82),
            value: trailingMode
        )
        .frame(maxWidth: .infinity, minHeight: 40)
        .padding(.horizontal, 4)
        .glassEffect(
            .regular.tint(Color.tronPhthaloGreen.opacity(0.25)).interactive(),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .glassEffectID("chat-composer", in: glassNamespace)
        .buttonStyle(.plain)
    }

    private var attachmentButton: some View {
        ZStack {
            Image(systemName: "plus")
                .font(TronTypography.sans(
                    size: ComposerControlMetrics.symbolSize,
                    weight: .semibold
                ))
                .foregroundStyle(attachmentActionsEnabled ? Color.tronEmerald : Color.tronTextMuted)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            ComposerAttachmentMenuButton(
                isEnabled: attachmentActionsEnabled,
                showsSkills: resourcePickerAvailable,
                onSelect: onSelectAttachmentDestination
            )
            .frame(width: ComposerControlMetrics.hitTarget, height: ComposerControlMetrics.hitTarget)
            .id(attachmentMenuState.identity)
            .accessibilityLabel("Add attachment")
        }
        .frame(width: ComposerControlMetrics.hitTarget, height: ComposerControlMetrics.hitTarget)
    }

    private var catchUpButton: some View {
        Button(action: onCatchUp) {
            Image(systemName: "arrow.down")
                .font(TronTypography.buttonSM)
                .foregroundStyle(Color.tronEmerald)
                .frame(width: ComposerControlMetrics.hitTarget, height: ComposerControlMetrics.hitTarget)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(Color.tronPhthaloGreen.opacity(0.25)).interactive(),
            in: .circle
        )
        .glassEffectID("chat-catch-up", in: glassNamespace)
        .glassEffectTransition(.matchedGeometry)
        .transition(
            reduceMotion
                ? .opacity
                : .move(edge: .leading)
                    .combined(with: .scale(scale: 0.82, anchor: .leading))
                    .combined(with: .opacity)
        )
        .accessibilityLabel("Catch up")
        .accessibilityHint("Returns to the latest response and follows new messages")
    }
}

private struct ChatPendingAttachmentStrip: View {
    let attachments: [PendingAttachment]
    let morphRegistry: ChatMorphFrameRegistry
    let reduceMotion: Bool
    let onRemove: (String) -> Void

    @State private var presentedAttachments: [PendingAttachment]
    @State private var reconciliationTask: Task<Void, Never>?

    init(
        attachments: [PendingAttachment],
        morphRegistry: ChatMorphFrameRegistry,
        reduceMotion: Bool,
        onRemove: @escaping (String) -> Void
    ) {
        self.attachments = attachments
        self.morphRegistry = morphRegistry
        self.reduceMotion = reduceMotion
        self.onRemove = onRemove
        _presentedAttachments = State(initialValue: attachments)
    }

    var body: some View {
        Group {
            if !presentedAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(presentedAttachments) { attachment in
                            PendingAttachmentChip(attachment: attachment) {
                                onRemove(attachment.id)
                            }
                            .chatDraftAttachmentMorphSource(id: attachment.id, registry: morphRegistry)
                            .transition(
                                presentedAttachments.count == 1
                                    ? .identity
                                    : ChatContentTransitionPolicy.attachmentTransition(
                                        reduceMotion: reduceMotion
                                    )
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                }
                .scrollClipDisabled()
                .transition(ChatContentTransitionPolicy.attachmentTransition(
                    reduceMotion: reduceMotion
                ))
            }
        }
        .onChange(of: attachments) { _, target in
            reconcile(to: target)
        }
        .onDisappear {
            reconciliationTask?.cancel()
            reconciliationTask = nil
        }
    }

    private func reconcile(to target: [PendingAttachment]) {
        reconciliationTask?.cancel()
        reconciliationTask = nil

        if reduceMotion {
            withAnimation(ChatContentTransitionPolicy.attachmentAnimation(reduceMotion: true)) {
                presentedAttachments = target
            }
            return
        }

        let targetIDs = Set(target.map(\.id))
        let targetByID = Dictionary(uniqueKeysWithValues: target.map { ($0.id, $0) })
        for index in presentedAttachments.indices {
            if let updated = targetByID[presentedAttachments[index].id] {
                presentedAttachments[index] = updated
            }
        }

        let insertionIDs = ChatContentTransitionPolicy.attachmentInsertionIDs(
            current: presentedAttachments.map(\.id),
            target: target.map(\.id)
        )
        let animation = ChatContentTransitionPolicy.attachmentAnimation(reduceMotion: false)
        withAnimation(animation) {
            presentedAttachments.removeAll { !targetIDs.contains($0.id) }
            if insertionIDs.isEmpty {
                presentedAttachments = target
            }
        }

        guard !insertionIDs.isEmpty else { return }
        reconciliationTask = Task { @MainActor in
            for (rank, id) in insertionIDs.enumerated() {
                if rank > 0 {
                    try? await Task.sleep(for: .seconds(
                        ChatContentTransitionPolicy.attachmentStaggerInterval
                    ))
                }
                guard !Task.isCancelled,
                      let attachment = targetByID[id],
                      !presentedAttachments.contains(where: { $0.id == id }) else { continue }
                let targetIndex = target.firstIndex(where: { $0.id == id }) ?? target.endIndex
                let precedingIDs = Set(target[..<targetIndex].map(\.id))
                let insertionIndex = presentedAttachments.prefix {
                    precedingIDs.contains($0.id)
                }.count
                withAnimation(animation) {
                    presentedAttachments.insert(
                        attachment,
                        at: min(insertionIndex, presentedAttachments.endIndex)
                    )
                }
            }
            guard !Task.isCancelled else { return }
            withAnimation(animation) { presentedAttachments = target }
            reconciliationTask = nil
        }
    }
}
