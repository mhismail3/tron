import SwiftUI
import PhotosUI

// ARCHITECTURE: ~606 lines — keyboard handling, attachment picker, skill picker,
// voice capture, and send flow. These share input state (@State variables) that
// Swift's file-scoped `private` prevents extracting to separate files.

// MARK: - Input Bar (iOS 26 Liquid Glass)

@available(iOS 26.0, *)
struct InputBar: View {
    // MARK: - Consolidated Input (State/Config/Actions pattern)

    /// Mutable input state (text, attachments, skills, etc.)
    @Bindable var state: InputBarState

    /// Read-only configuration (processing state, model info, etc.)
    let config: InputBarConfig

    /// Action callbacks (send, abort, mic, etc.)
    let actions: InputBarActions

    // MARK: - Private State

    @FocusState private var isFocused: Bool
    @Environment(\.dependencies) private var dependencies
    private let audioMonitor = AudioAvailabilityMonitor.shared
    @State private var showingImagePicker = false
    @State private var showCamera = false
    @State private var showFilePicker = false
    @State private var showSkillMentionPopup = false
    @State private var skillMentionQuery = ""
    @State private var showPromptLibrary = false
    @State private var hasAppeared = false
    @State private var showAttachmentButton = false
    @State private var showMicButton = false

    // Namespaces for morph animations
    @Namespace private var actionButtonNamespace
    @Namespace private var micButtonNamespace
    @Namespace private var attachmentButtonNamespace

    private let actionButtonSize: CGFloat = 40

    // MARK: - Computed Properties

    private var canSend: Bool {
        if config.agentPhase.isActive {
            // During processing/postProcessing: allow send if has text
            // so the message can be queued (server rejects if queue full).
            // Async blockers like compaction / retain / disconnect still
            // prevent queueing — nothing to queue into.
            return state.hasTextContent && config.sendBlockReason == nil
        }
        return state.hasContent && config.sendBlockReason == nil
    }

    /// Show stop button when agent is active and user has no text to queue.
    private var showStop: Bool {
        config.agentPhase.isActive && !state.hasTextContent
    }

    private var shouldShowActionButton: Bool {
        if config.agentPhase.isActive {
            return true  // Always show during processing (either stop or send-to-queue)
        }
        return canSend
    }

    private var shouldShowStatusPills: Bool { true }

    private var hasSkillsAvailable: Bool {
        config.skillStore != nil && (config.skillStore?.totalCount ?? 0) > 0
    }

    private var textFieldTrailingPadding: CGFloat {
        let basePadding: CGFloat = 14
        var totalPadding = basePadding
        if !shouldShowActionButton {
            totalPadding += actionButtonSize + 8
        }
        if !showMicButton {
            totalPadding += actionButtonSize + 8
        }
        return totalPadding
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 10) {
            // Content area: attachments, skills (wrapping), and status pills
            contentArea
                .padding(.horizontal, 16)
                .transition(.opacity)

            // Queued message chips
            if !config.queuedMessages.isEmpty {
                QueuedMessageChipsView(
                    queue: config.queuedMessages,
                    onRemove: { id in actions.onQueueRemove?(id) }
                )
                .padding(.horizontal, 16)
            }

            // Skill mention popup
            if showSkillMentionPopup, let store = config.skillStore {
                MentionPopup(
                    skills: store.skills,
                    query: skillMentionQuery,
                    skillStore: store,
                    onSelect: { skill in
                        selectFromMention(skill)
                    },
                    onDismiss: {
                        dismissMentionPopup()
                    }
                )
                .padding(.horizontal, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Input row - floating liquid glass elements
            HStack(alignment: .bottom, spacing: 12) {
                // Attachment button
                if showAttachmentButton {
                    GlassAttachmentButton(
                        isProcessing: config.agentPhase.isActive || config.readOnly,
                        hasSkillsAvailable: hasSkillsAvailable,
                        buttonSize: actionButtonSize,
                        skillStore: config.skillStore,
                        attachmentCapability: config.attachmentCapability,
                        showCamera: $showCamera,
                        showingImagePicker: $showingImagePicker,
                        showFilePicker: $showFilePicker,
                        showSkillMentionPopup: $showSkillMentionPopup,
                        skillMentionQuery: $skillMentionQuery,
                        showPromptLibrary: $showPromptLibrary
                    )
                    .matchedGeometryEffect(id: "attachmentMorph", in: attachmentButtonNamespace)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }

                // Text field with glass background
                textFieldGlass
                    .overlay(alignment: .leading) {
                        Group {
                            if !showAttachmentButton {
                                AttachmentButtonDock(buttonSize: actionButtonSize)
                                    .matchedGeometryEffect(id: "attachmentMorph", in: attachmentButtonNamespace)
                            }
                        }
                        // Prevent overlay from intercepting text selection drag gestures
                        .allowsHitTesting(false)
                    }
                    .overlay(alignment: .trailing) {
                        HStack(spacing: 8) {
                            if !shouldShowActionButton {
                                ActionButtonDock(namespace: actionButtonNamespace, buttonSize: actionButtonSize)
                            }
                            if !showMicButton {
                                MicButtonDock(buttonSize: actionButtonSize)
                                    .matchedGeometryEffect(id: "micMorph", in: micButtonNamespace)
                            }
                        }
                        .padding(.trailing, 8)
                        // Prevent overlay from intercepting text selection drag gestures
                        .allowsHitTesting(false)
                    }

                // Send/Abort button
                if shouldShowActionButton && !config.readOnly {
                    GlassActionButton(
                        showStop: showStop,
                        canSend: canSend,
                        onSend: actions.onSend,
                        onAbort: actions.onAbort,
                        namespace: actionButtonNamespace,
                        buttonSize: actionButtonSize
                    )
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    // H9: explain the disabled state. Visible on long-press
                    // / hover via `.help()`; always read by VoiceOver via
                    // `.accessibilityHint()`.
                    .help(config.sendBlockReason?.description ?? "")
                    .accessibilityHint(config.sendBlockReason?.description ?? "")
                }

                // Mic button
                if showMicButton {
                    GlassMicButton(
                        isRecording: config.isRecording,
                        isTranscribing: config.isTranscribing,
                        isProcessing: config.isProcessing || config.readOnly,
                        onMicTap: {
                            isFocused = false
                            actions.onMicTap()
                        },
                        buttonSize: actionButtonSize,
                        audioMonitor: audioMonitor
                    )
                    .matchedGeometryEffect(id: "micMorph", in: micButtonNamespace)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .overlay(alignment: .top) {
                if config.showDragHint {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.tronEmerald.opacity(0.6))
                        .offset(y: -20)
                        .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: showAttachmentButton)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: showMicButton)
            .animation(.tronStandard, value: shouldShowActionButton)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        // Focus management — no blockFocusUntil; user can tap to refocus for queueing
        .animation(nil, value: isFocused)
        .onChange(of: config.isProcessing) { wasProcessing, isNowProcessing in
            if !wasProcessing && isNowProcessing {
                // Processing started - dismiss keyboard IMMEDIATELY using both methods
                // 1. SwiftUI FocusState - updates focus binding
                isFocused = false
                // 2. UIKit endEditing - ensures keyboard frame updates for safe area calculations
                // This is critical for Menu positioning after keyboard dismiss
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil
                )
            }
        }
        // Skill mention detection
        .onChange(of: state.text) { _, newText in
            detectSkillMention(in: newText)
        }
        // Sync mention popup visibility to shared state
        .onChange(of: showSkillMentionPopup) { _, _ in
            state.isMentionPopupVisible = showSkillMentionPopup
        }
        // External dismiss (tap outside)
        .onChange(of: state.isMentionPopupVisible) { _, visible in
            if !visible && showSkillMentionPopup {
                dismissMentionPopup()
            }
        }
        // Sheets
        .sheet(isPresented: $showCamera) {
            CameraCaptureSheet { capturedImage in
                Task {
                    // Camera always produces JPEG
                    let jpegData = capturedImage.jpegData(compressionQuality: 1.0) ?? Data()
                    let limits = config.providerImageLimits
                    if let result = await ImageProcessor.process(
                        originalData: jpegData,
                        mimeType: "image/jpeg",
                        limits: limits
                    ) {
                        let attachment = Attachment(
                            type: .image,
                            data: result.data,
                            mimeType: result.mimeType,
                            fileName: nil,
                            originalSize: jpegData.count,
                            wasConverted: result.wasConverted
                        )
                        await MainActor.run {
                            actions.onAddAttachment(attachment)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showFilePicker) {
            DocumentPicker(
                capability: config.attachmentCapability,
                onDocumentPicked: { url, mimeType, fileName in
                    do {
                        let data = try Data(contentsOf: url)
                        let type = AttachmentType.from(mimeType: mimeType)
                        let attachment = Attachment(
                            type: type,
                            data: data,
                            mimeType: mimeType,
                            fileName: fileName
                        )
                        actions.onAddAttachment(attachment)
                    } catch {
                        logger.warning("Failed to read document: \(error.localizedDescription)", category: .chat)
                    }
                },
                onSizeExceeded: { actualSize, maxSize in
                    let actualMB = actualSize / (1024 * 1024)
                    let maxMB = maxSize / (1024 * 1024)
                    logger.warning("File too large: \(actualMB)MB exceeds \(maxMB)MB limit", category: .chat)
                }
            )
        }
        .photosPicker(
            isPresented: $showingImagePicker,
            selection: $state.selectedImages,
            maxSelectionCount: 5,
            matching: .images
        )
        .sheet(isPresented: $showPromptLibrary) {
            PromptLibrarySheet(rpcClient: dependencies.rpcClient) { selected in
                state.text = selected
            }
        }
        // Entrance animation — three staggered morph-ins over ~430ms.
        // All timings/springs live in TronAnimationTiming so the
        // cumulative timeline can be tweaked in one place.
        .onAppear {
            showAttachmentButton = false
            showMicButton = false
            hasAppeared = false

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: TronAnimationTiming.inputBarAttachmentDelayNanos)
                withAnimation(TronAnimationTiming.inputBarButtonSpring) {
                    showAttachmentButton = true
                }
                try? await Task.sleep(nanoseconds: TronAnimationTiming.inputBarMicDelayNanos)
                withAnimation(TronAnimationTiming.inputBarButtonSpring) {
                    showMicButton = true
                }
                try? await Task.sleep(nanoseconds: TronAnimationTiming.inputBarFinalDelayNanos)
                withAnimation(TronAnimationTiming.inputBarFinalSpring) {
                    hasAppeared = true
                }
            }
        }
        .onDisappear {
            showAttachmentButton = false
            showMicButton = false
            hasAppeared = false
        }
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        HStack(alignment: .bottom, spacing: 12) {
            if !state.selectedSkills.isEmpty || !state.attachments.isEmpty {
                ContentAreaView(
                    selectedSkills: state.selectedSkills,
                    attachments: state.attachments,
                    attachmentCapability: config.attachmentCapability,
                    onSkillRemove: { skill in
                        removeSelectedMention(skill)
                    },
                    onSkillDetailTap: actions.onSkillDetailTap,
                    onRemoveAttachment: actions.onRemoveAttachment
                )
            }

            Spacer(minLength: 0)

            AgentControlPill(
                contextPercentage: config.contextPercentage,
                modelName: config.currentModelInfo?.name,
                hasAppeared: hasAppeared,
                onTap: actions.onContextTap,
                readOnly: config.readOnly
            )
            .opacity(shouldShowStatusPills ? 1 : 0)
        }
    }

    // MARK: - Text Field

    private var textFieldGlass: some View {
        ZStack(alignment: .leading) {
            if state.text.isEmpty && !isFocused {
                Text("Type here")
                    .font(TronTypography.input)
                    .foregroundStyle(.tronEmerald.opacity(0.5))
                    .padding(.leading, 14)
                    .padding(.vertical, 10)
            }

            TextField("", text: $state.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(TronTypography.input)
                .foregroundStyle(config.readOnly ? .tronEmerald.opacity(0.5) : .tronEmerald)
                .padding(.leading, 14)
                .padding(.trailing, textFieldTrailingPadding)
                .padding(.vertical, 10)
                .lineLimit(1...8)
                .focused($isFocused)
                .disabled(config.readOnly)
                .accessibilityLabel("Message input")
                .onSubmit {
                    if !state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !config.readOnly {
                        actions.onSend()
                    }
                }
        }
        .frame(minHeight: actionButtonSize)
        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.25)).interactive(), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(.tronStandard, value: shouldShowActionButton)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showMicButton)
    }

    // MARK: - Mention Detection

    private func detectSkillMention(in newText: String) {
        guard let store = config.skillStore else { return }

        if let completed = SkillMentions.detectCompletedMention(
            in: newText,
            skills: store.skills,
            alreadySelected: state.selectedSkills
        ) {
            if !state.selectedSkills.contains(where: { $0.name == completed.name }) {
                state.selectedSkills.append(completed)
            }
            actions.onSkillSelect?(completed)
            withAnimation(.tronStandard) {
                showSkillMentionPopup = false
                skillMentionQuery = ""
            }
            return
        }

        if let q = SkillMentions.detectMention(in: newText) {
            skillMentionQuery = q
            if !showSkillMentionPopup {
                withAnimation(.tronStandard) {
                    showSkillMentionPopup = true
                }
            }
        } else if showSkillMentionPopup {
            withAnimation(.tronStandard) {
                showSkillMentionPopup = false
                skillMentionQuery = ""
            }
        }
    }

    private func selectFromMention(_ skill: Skill) {
        let trigger = SkillMentions.trigger
        if let triggerIndex = state.text.lastIndex(of: trigger) {
            state.text = String(state.text[..<triggerIndex]) + String(trigger) + skill.name + " "
        }
        if !state.selectedSkills.contains(where: { $0.name == skill.name }) {
            state.selectedSkills.append(skill)
        }
        actions.onSkillSelect?(skill)
        dismissMentionPopup()
    }

    private func dismissMentionPopup() {
        withAnimation(.tronStandard) {
            showSkillMentionPopup = false
            skillMentionQuery = ""
        }
    }

    private func removeSelectedMention(_ skill: Skill) {
        state.selectedSkills.removeAll { $0.name == skill.name }
        actions.onSkillRemove?(skill)
    }

}

// MARK: - iOS 26 Menu Workaround Notifications

extension Notification.Name {
    /// iOS 26 Menu bug: State mutations in button actions break gesture handling
    static let modelPickerAction = Notification.Name("modelPickerAction")
    static let attachmentMenuAction = Notification.Name("attachmentMenuAction")
    static let reasoningLevelAction = Notification.Name("reasoningLevelAction")
    /// Plan mode: Request to add plan skill and enter planning mode
    static let draftPlanRequested = Notification.Name("draftPlanRequested")
}

// MARK: - Preview

#if DEBUG
@available(iOS 26.0, *)
#Preview {
    @Previewable @State var previewState = InputBarState()

    VStack {
        Spacer()
        InputBar(
            state: previewState,
            config: InputBarConfig(
                isRecording: false,
                isTranscribing: false,
                tokenUsage: TokenUsage(inputTokens: 50000, outputTokens: 10000, cacheReadTokens: nil, cacheCreationTokens: nil),
                contextPercentage: 30,
                contextWindow: 200_000,
                lastTurnInputTokens: 60000,
                currentModelInfo: nil,
                skillStore: nil,
                inputHistory: nil,
                animationCoordinator: nil,
                readOnly: false
            ),
            actions: InputBarActions()
        )
    }
    .onAppear {
        previewState.text = "Hello world"
    }
}
#endif
