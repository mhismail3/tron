import SwiftUI
import PhotosUI

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
    @State private var blockFocusUntil: Date = .distantPast
    private let audioMonitor = AudioAvailabilityMonitor.shared
    @State private var showingImagePicker = false
    @State private var showCamera = false
    @State private var showFilePicker = false
    @State private var showSkillMentionPopup = false
    @State private var skillMentionQuery = ""
    @State private var showSpellMentionPopup = false
    @State private var spellMentionQuery = ""
    @State private var isMicPulsing = false
    @State private var hasAppeared = false
    @State private var showAttachmentButton = false
    @State private var showMicButton = false

    // Namespaces for morph animations
    @Namespace private var actionButtonNamespace
    @Namespace private var modelPillNamespace
    @Namespace private var tokenPillNamespace
    @Namespace private var micButtonNamespace
    @Namespace private var reasoningPillNamespace
    @Namespace private var attachmentButtonNamespace

    private let actionButtonSize: CGFloat = 40

    // MARK: - Computed Properties

    private var canSend: Bool {
        state.hasContent && !config.isPostProcessing && !config.isCompacting
    }

    private var shouldShowActionButton: Bool {
        config.isProcessing || canSend || config.isPostProcessing
    }

    private var shouldShowStatusPills: Bool {
        !config.modelName.isEmpty || true // Token pill always visible
    }

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
            // Skill mention popup
            if showSkillMentionPopup, let store = config.skillStore {
                MentionPopup(
                    skills: store.skills,
                    query: skillMentionQuery,
                    style: .skill,
                    onSelect: { skill in
                        selectSkillFromMention(skill)
                    },
                    onDismiss: {
                        dismissSkillMentionPopup()
                    }
                )
                .padding(.horizontal, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Spell mention popup (ephemeral skills)
            if showSpellMentionPopup, let store = config.skillStore {
                MentionPopup(
                    skills: store.skills,
                    query: spellMentionQuery,
                    style: .spell,
                    onSelect: { skill in
                        selectSpellFromMention(skill)
                    },
                    onDismiss: {
                        dismissSpellMentionPopup()
                    }
                )
                .padding(.horizontal, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Content area: attachments, skills (wrapping), and status pills
            contentArea
                .padding(.horizontal, 16)
                .transition(.opacity)

            // Input row - floating liquid glass elements
            HStack(alignment: .bottom, spacing: 12) {
                // Attachment button
                if showAttachmentButton {
                    GlassAttachmentButton(
                        isProcessing: config.isProcessing || config.readOnly,
                        hasSkillsAvailable: hasSkillsAvailable,
                        buttonSize: actionButtonSize,
                        skillStore: config.skillStore,
                        showCamera: $showCamera,
                        showingImagePicker: $showingImagePicker,
                        showFilePicker: $showFilePicker,
                        showSkillMentionPopup: $showSkillMentionPopup,
                        skillMentionQuery: $skillMentionQuery,
                        showSpellMentionPopup: $showSpellMentionPopup,
                        spellMentionQuery: $spellMentionQuery
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
                        isProcessing: config.isProcessing,
                        canSend: canSend,
                        onSend: actions.onSend,
                        onAbort: actions.onAbort,
                        namespace: actionButtonNamespace,
                        buttonSize: actionButtonSize
                    )
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }

                // Mic button
                if showMicButton {
                    GlassMicButton(
                        isRecording: config.isRecording,
                        isTranscribing: config.isTranscribing,
                        isProcessing: config.isProcessing || config.readOnly,
                        onMicTap: actions.onMicTap,
                        buttonSize: actionButtonSize,
                        audioMonitor: audioMonitor
                    )
                    .matchedGeometryEffect(id: "micMorph", in: micButtonNamespace)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: showAttachmentButton)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: showMicButton)
            .animation(.tronStandard, value: shouldShowActionButton)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        // Focus management
        .onChange(of: isFocused) { _, newValue in
            if newValue && Date() < blockFocusUntil {
                isFocused = false
            }
        }
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
            } else if wasProcessing && !isNowProcessing {
                // Processing ended - ensure keyboard stays dismissed and block refocus briefly
                isFocused = false
                blockFocusUntil = Date().addingTimeInterval(0.5)
            }
        }
        // Animation coordinator updates
        .onChange(of: config.currentModelInfo?.supportsReasoning) { _, supportsReasoning in
            config.animationCoordinator?.updateReasoningSupport(supportsReasoning == true)
        }
        // Skill and spell mention detection
        .onChange(of: state.text) { _, newText in
            detectSkillMention(in: newText)
            detectSpellMention(in: newText)
        }
        // Sync mention popup visibility to shared state
        .onChange(of: showSkillMentionPopup) { _, _ in
            state.isMentionPopupVisible = showSkillMentionPopup || showSpellMentionPopup
        }
        .onChange(of: showSpellMentionPopup) { _, _ in
            state.isMentionPopupVisible = showSkillMentionPopup || showSpellMentionPopup
        }
        // External dismiss (tap outside)
        .onChange(of: state.isMentionPopupVisible) { _, visible in
            if !visible {
                if showSkillMentionPopup { dismissSkillMentionPopup() }
                if showSpellMentionPopup { dismissSpellMentionPopup() }
            }
        }
        // Sheets
        .sheet(isPresented: $showCamera) {
            CameraCaptureSheet { capturedImage in
                Task {
                    if let result = await ImageCompressor.compress(capturedImage) {
                        let attachment = Attachment(
                            type: .image,
                            data: result.data,
                            mimeType: result.mimeType,
                            fileName: nil,
                            originalSize: Int(capturedImage.jpegData(compressionQuality: 1.0)?.count ?? 0)
                        )
                        await MainActor.run {
                            actions.onAddAttachment(attachment)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showFilePicker) {
            DocumentPicker { url, mimeType, fileName in
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
            }
        }
        .photosPicker(
            isPresented: $showingImagePicker,
            selection: $state.selectedImages,
            maxSelectionCount: 5,
            matching: .images
        )
        // Entrance animation
        .onAppear {
            showAttachmentButton = false
            showMicButton = false
            hasAppeared = false

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)

                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    showAttachmentButton = true
                }

                try? await Task.sleep(nanoseconds: 130_000_000)
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    showMicButton = true
                }

                try? await Task.sleep(nanoseconds: 100_000_000)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
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
            if !state.selectedSkills.isEmpty || !state.selectedSpells.isEmpty || !state.attachments.isEmpty {
                ContentAreaView(
                    selectedSkills: state.selectedSkills,
                    selectedSpells: state.selectedSpells,
                    attachments: state.attachments,
                    onSkillRemove: { skill in
                        removeSelectedSkill(skill)
                    },
                    onSkillDetailTap: actions.onSkillDetailTap,
                    onSpellRemove: { skill in
                        removeSelectedSpell(skill)
                    },
                    onSpellDetailTap: actions.onSpellDetailTap,
                    onRemoveAttachment: actions.onRemoveAttachment
                )
            }

            Spacer(minLength: 0)

            StatusPillsColumn(
                modelName: config.modelName,
                cachedModels: config.cachedModels,
                currentModelInfo: config.currentModelInfo,
                contextPercentage: config.contextPercentage,
                contextWindow: config.contextWindow,
                lastTurnInputTokens: config.lastTurnInputTokens,
                reasoningLevel: $state.reasoningLevel,
                hasAppeared: hasAppeared,
                reasoningPillNamespace: reasoningPillNamespace,
                onContextTap: actions.onContextTap,
                onModelPickerTap: actions.onModelPickerTap,
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
                .disabled(config.isProcessing || config.readOnly)
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

    // MARK: - Mention Detection (shared for skills and spells)

    private func detectSkillMention(in newText: String) {
        detectMention(
            in: newText,
            detector: .skill,
            selected: state.selectedSkills,
            showPopup: $showSkillMentionPopup,
            query: $skillMentionQuery,
            dismissOther: { dismissSpellMentionPopup() },
            onCompleted: { skill in
                if !state.selectedSkills.contains(where: { $0.name == skill.name }) {
                    state.selectedSkills.append(skill)
                }
                actions.onSkillSelect?(skill)
            }
        )
    }

    private func detectSpellMention(in newText: String) {
        detectMention(
            in: newText,
            detector: .spell,
            selected: state.selectedSpells,
            showPopup: $showSpellMentionPopup,
            query: $spellMentionQuery,
            dismissOther: { dismissSkillMentionPopup() },
            onCompleted: { skill in
                if !state.selectedSpells.contains(where: { $0.name == skill.name }) {
                    state.selectedSpells.append(skill)
                }
            }
        )
    }

    private func detectMention(
        in newText: String,
        detector: MentionDetector,
        selected: [Skill],
        showPopup: Binding<Bool>,
        query: Binding<String>,
        dismissOther: () -> Void,
        onCompleted: (Skill) -> Void
    ) {
        guard let store = config.skillStore else { return }

        if let completed = detector.detectCompletedMention(in: newText, skills: store.skills, alreadySelected: selected) {
            onCompleted(completed)
            withAnimation(.tronStandard) {
                showPopup.wrappedValue = false
                query.wrappedValue = ""
            }
            return
        }

        if let q = detector.detectMention(in: newText) {
            query.wrappedValue = q
            if !showPopup.wrappedValue {
                withAnimation(.tronStandard) {
                    dismissOther()
                    showPopup.wrappedValue = true
                }
            }
        } else if showPopup.wrappedValue {
            withAnimation(.tronStandard) {
                showPopup.wrappedValue = false
                query.wrappedValue = ""
            }
        }
    }

    private func selectSkillFromMention(_ skill: Skill) {
        if let triggerIndex = state.text.lastIndex(of: "@") {
            state.text = String(state.text[..<triggerIndex]) + "@" + skill.name + " "
        }
        if !state.selectedSkills.contains(where: { $0.name == skill.name }) {
            state.selectedSkills.append(skill)
        }
        withAnimation(.tronStandard) {
            showSkillMentionPopup = false
            skillMentionQuery = ""
        }
        actions.onSkillSelect?(skill)
    }

    private func selectSpellFromMention(_ skill: Skill) {
        if let triggerIndex = state.text.lastIndex(of: "%") {
            state.text = String(state.text[..<triggerIndex]) + "%" + skill.name + " "
        }
        if !state.selectedSpells.contains(where: { $0.name == skill.name }) {
            state.selectedSpells.append(skill)
        }
        withAnimation(.tronStandard) {
            showSpellMentionPopup = false
            spellMentionQuery = ""
        }
    }

    private func dismissSkillMentionPopup() {
        withAnimation(.tronStandard) {
            showSkillMentionPopup = false
            skillMentionQuery = ""
        }
    }

    private func dismissSpellMentionPopup() {
        withAnimation(.tronStandard) {
            showSpellMentionPopup = false
            spellMentionQuery = ""
        }
    }

    private func removeSelectedSkill(_ skill: Skill) {
        state.selectedSkills.removeAll { $0.name == skill.name }
        actions.onSkillRemove?(skill)
    }

    private func removeSelectedSpell(_ skill: Skill) {
        state.selectedSpells.removeAll { $0.name == skill.name }
        actions.onSpellRemove?(skill)
    }

    /// Trigger reasoning pill animation
    func triggerReasoningPillAnimation() {
        config.animationCoordinator?.updateReasoningSupport(true)
    }

    /// Hide reasoning pill
    func hideReasoningPill() {
        config.animationCoordinator?.updateReasoningSupport(false)
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
                modelName: "claude-sonnet-4-5-20260105",
                tokenUsage: TokenUsage(inputTokens: 50000, outputTokens: 10000, cacheReadTokens: nil, cacheCreationTokens: nil),
                contextPercentage: 30,
                contextWindow: 200_000,
                lastTurnInputTokens: 60000,
                cachedModels: [],
                isLoadingModels: false,
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
