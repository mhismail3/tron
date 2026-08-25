import SwiftUI

/// Value-driven composer presentation. Draft, route, transport, and canonical
/// ownership remain outside this view and enter only through bindings/intents.
struct ChatComposerView: View {
    let snapshot: SessionSnapshot?
    let pendingAttachments: [PendingAttachment]
    let selectedSkill: ComposerResourceEntry?
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
    let skillPickerAvailable: Bool
    let glassNamespace: Namespace.ID

    let onExtensionTap: (String) -> Void
    let onExtensionVisualState: (ExtensionActivityPillVisualState, Int) -> Void
    let onExtensionExpiry: (String, ExtensionActivityVisibility, Int?) -> Void
    let onRemoveAttachment: (String) -> Void
    let onRemoveSkill: () -> Void
    let onSelectResource: (ComposerResourceEntry) -> Void
    let onDismissResourcePicker: () -> Void
    let onShowContext: () -> Void
    let onSend: (String?) -> Void
    let onAbort: () -> Void
    let onSelectAttachmentDestination: @MainActor @Sendable (ChatAttachmentDestination) -> Void
    let onCatchUp: () -> Void
    let onComposerHeight: (CGFloat) -> Void

    var body: some View {
        ChatComposerStructuralHost(
            accessoryIdentity: ChatComposerAccessoryLayoutIdentity(
                attachmentIDs: pendingAttachments.map(\.id),
                selectedSkillID: selectedSkill?.id,
                resourcePickerKind: resourcePicker?.kind,
                resourceResultIDs: resourceResults.map(\.id)
            ),
            reduceMotion: reduceMotion,
            onHeightChange: onComposerHeight
        ) {
            VStack(spacing: 10) {
                extensionPills
                attachmentStrip
                selectedSkillStrip
                resourcePickerView
                GlassEffectContainer(spacing: 8) {
                    HStack(alignment: .bottom, spacing: 8) {
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
                value: selectedSkill?.id
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

    @ViewBuilder
    private var extensionPills: some View {
        if let snapshot {
            let groups = ExtensionActivityPillPolicy.composerGroups(
                ChatExtensionWidgetPolicy.liveGroups(
                    snapshot.extensionPresentation,
                    executions: snapshot.toolExecutions,
                    activities: snapshot.extensionActivities ?? []
                )
            )
            if !groups.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(groups) { group in
                            ExtensionActivityPill(
                                group: group,
                                onTap: { onExtensionTap(group.id) },
                                onVisualState: onExtensionVisualState,
                                onExpiry: onExtensionExpiry
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 16)
                }
                .scrollClipDisabled()
                .transition(.opacity)
                .accessibilityElement(children: .contain)
            }
        }
    }

    @ViewBuilder
    private var attachmentStrip: some View {
        if !pendingAttachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(pendingAttachments) { attachment in
                        PendingAttachmentChip(attachment: attachment) {
                            onRemoveAttachment(attachment.id)
                        }
                        .chatDraftAttachmentMorphSource(id: attachment.id, registry: morphRegistry)
                        .transition(ChatContentTransitionPolicy.attachmentTransition(
                            reduceMotion: reduceMotion
                        ))
                    }
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
    private var selectedSkillStrip: some View {
        if let selectedSkill {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ComposerSkillChip(skill: selectedSkill, onRemove: onRemoveSkill)
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
                    offersQueueChoices: snapshot?.phase.isActive == true,
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
                showsSkills: skillPickerAvailable,
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
