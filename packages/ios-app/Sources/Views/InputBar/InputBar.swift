import SwiftUI
import PhotosUI

// MARK: - Input Bar (iOS 26 Liquid Glass)

@available(iOS 26.0, *)
struct InputBar: View {
    @Binding var text: String
    let isProcessing: Bool
    let isRecording: Bool
    let isTranscribing: Bool
    @Binding var selectedImages: [PhotosPickerItem]
    let onSend: () -> Void
    let onAbort: () -> Void
    let onMicTap: () -> Void
    @Binding var attachments: [Attachment]
    let onAddAttachment: (Attachment) -> Void
    let onRemoveAttachment: (Attachment) -> Void
    var inputHistory: InputHistoryStore?
    var onHistoryNavigate: ((String) -> Void)?

    // Status bar info
    var modelName: String = ""
    var tokenUsage: TokenUsage?
    var contextPercentage: Int = 0
    var contextWindow: Int = 0
    var lastTurnInputTokens: Int = 0

    // Model picker integration
    var cachedModels: [ModelInfo] = []
    var isLoadingModels: Bool = false
    var onModelSelect: ((ModelInfo) -> Void)?

    // Reasoning level picker
    @Binding var reasoningLevel: String
    var currentModelInfo: ModelInfo?
    var onReasoningLevelChange: ((String) -> Void)?

    // Context manager action
    var onContextTap: (() -> Void)?

    // Skills integration
    var skillStore: SkillStore?
    var onSkillSelect: ((Skill) -> Void)?
    @Binding var selectedSkills: [Skill]
    var onSkillRemove: ((Skill) -> Void)?
    var onSkillDetailTap: ((Skill) -> Void)?

    /// Optional animation coordinator for chained pill morph animations
    var animationCoordinator: AnimationCoordinator?

    /// Read-only mode disables input when workspace is deleted
    var readOnly: Bool = false

    // MARK: - Private State

    @FocusState private var isFocused: Bool
    @State private var blockFocusUntil: Date = .distantPast
    @ObservedObject private var audioMonitor = AudioAvailabilityMonitor.shared
    @State private var showingImagePicker = false
    @State private var showCamera = false
    @State private var showFilePicker = false
    @State private var showSkillMentionPopup = false
    @State private var skillMentionQuery = ""
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
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private var shouldShowActionButton: Bool {
        isProcessing || canSend
    }

    private var shouldShowStatusPills: Bool {
        !modelName.isEmpty || true // Token pill always visible
    }

    private var hasSkillsAvailable: Bool {
        skillStore != nil && (skillStore?.totalCount ?? 0) > 0
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
            if showSkillMentionPopup, let store = skillStore {
                SkillMentionPopup(
                    skills: store.skills,
                    query: skillMentionQuery,
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

            // Content area: attachments, skills (wrapping), and status pills
            contentArea
                .padding(.horizontal, 16)
                .transition(.opacity)

            // Input row - floating liquid glass elements
            HStack(alignment: .bottom, spacing: 12) {
                // Attachment button
                if showAttachmentButton {
                    GlassAttachmentButton(
                        isProcessing: isProcessing || readOnly,
                        hasSkillsAvailable: hasSkillsAvailable,
                        buttonSize: actionButtonSize,
                        skillStore: skillStore,
                        showCamera: $showCamera,
                        showingImagePicker: $showingImagePicker,
                        showFilePicker: $showFilePicker,
                        showSkillMentionPopup: $showSkillMentionPopup,
                        skillMentionQuery: $skillMentionQuery
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
                if shouldShowActionButton && !readOnly {
                    GlassActionButton(
                        isProcessing: isProcessing,
                        canSend: canSend,
                        onSend: onSend,
                        onAbort: onAbort,
                        namespace: actionButtonNamespace,
                        buttonSize: actionButtonSize
                    )
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }

                // Mic button
                if showMicButton {
                    GlassMicButton(
                        isRecording: isRecording,
                        isTranscribing: isTranscribing,
                        isProcessing: isProcessing || readOnly,
                        onMicTap: onMicTap,
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
        .onChange(of: isProcessing) { wasProcessing, isNowProcessing in
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
        .onChange(of: currentModelInfo?.supportsReasoning) { _, supportsReasoning in
            animationCoordinator?.updateReasoningSupport(supportsReasoning == true)
        }
        // Skill mention detection
        .onChange(of: text) { _, newText in
            detectSkillMention(in: newText)
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
                            onAddAttachment(attachment)
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
                    onAddAttachment(attachment)
                } catch {
                    logger.warning("Failed to read document: \(error.localizedDescription)", category: .chat)
                }
            }
        }
        .photosPicker(
            isPresented: $showingImagePicker,
            selection: $selectedImages,
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
            if !selectedSkills.isEmpty || !attachments.isEmpty {
                ContentAreaView(
                    selectedSkills: selectedSkills,
                    attachments: attachments,
                    onSkillRemove: { skill in
                        removeSelectedSkill(skill)
                    },
                    onSkillDetailTap: onSkillDetailTap,
                    onRemoveAttachment: onRemoveAttachment
                )
            }

            Spacer(minLength: 0)

            StatusPillsColumn(
                modelName: modelName,
                cachedModels: cachedModels,
                currentModelInfo: currentModelInfo,
                contextPercentage: contextPercentage,
                contextWindow: contextWindow,
                lastTurnInputTokens: lastTurnInputTokens,
                reasoningLevel: $reasoningLevel,
                hasAppeared: hasAppeared,
                reasoningPillNamespace: reasoningPillNamespace,
                onContextTap: onContextTap,
                readOnly: readOnly
            )
            .opacity(shouldShowStatusPills ? 1 : 0)
        }
    }

    // MARK: - Text Field

    private var textFieldGlass: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty && !isFocused {
                Text("Type here")
                    .font(TronTypography.input)
                    .foregroundStyle(.tronEmerald.opacity(0.5))
                    .padding(.leading, 14)
                    .padding(.vertical, 10)
            }

            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(TronTypography.input)
                .foregroundStyle(readOnly ? .tronEmerald.opacity(0.5) : .tronEmerald)
                .padding(.leading, 14)
                .padding(.trailing, textFieldTrailingPadding)
                .padding(.vertical, 10)
                .lineLimit(1...8)
                .focused($isFocused)
                .disabled(isProcessing || readOnly)
                .onSubmit {
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !readOnly {
                        onSend()
                    }
                }
        }
        .frame(minHeight: actionButtonSize)
        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.35)), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(.tronStandard, value: shouldShowActionButton)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showMicButton)
    }

    // MARK: - Skill Mention Detection

    private func detectSkillMention(in newText: String) {
        guard let store = skillStore else { return }

        if let completedSkill = detectCompletedSkillMention(in: newText, skills: store.skills) {
            selectCompletedSkillMention(completedSkill, in: newText)
            return
        }

        if let query = SkillMentionDetector.detectMention(in: newText) {
            skillMentionQuery = query
            if !showSkillMentionPopup {
                withAnimation(.tronStandard) {
                    showSkillMentionPopup = true
                }
            }
        } else {
            if showSkillMentionPopup {
                withAnimation(.tronStandard) {
                    showSkillMentionPopup = false
                    skillMentionQuery = ""
                }
            }
        }
    }

    private func detectCompletedSkillMention(in text: String, skills: [Skill]) -> Skill? {
        let pattern = "@([a-zA-Z0-9][a-zA-Z0-9-]*)(?:\\s|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }

        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, options: [], range: range)

        for match in matches.reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let skillNameRange = match.range(at: 1)
            let skillName = nsText.substring(with: skillNameRange)

            guard !skillName.isEmpty else { continue }

            let atIndex = match.range.location
            if atIndex > 0 {
                let prevChar = nsText.character(at: atIndex - 1)
                let prevCharScalar = Unicode.Scalar(prevChar)!
                let isWhitespace = CharacterSet.whitespacesAndNewlines.contains(prevCharScalar)
                guard isWhitespace else { continue }
            }

            let beforeAt = nsText.substring(to: atIndex)
            let backtickCount = beforeAt.filter { $0 == "`" }.count
            if backtickCount % 2 != 0 { continue }

            if let skill = skills.first(where: { $0.name.lowercased() == skillName.lowercased() }) {
                if !selectedSkills.contains(where: { $0.name.lowercased() == skillName.lowercased() }) {
                    return skill
                }
            }
        }

        return nil
    }

    private func selectCompletedSkillMention(_ skill: Skill, in currentText: String) {
        if !selectedSkills.contains(where: { $0.name == skill.name }) {
            selectedSkills.append(skill)
        }
        dismissSkillMentionPopup()
        onSkillSelect?(skill)
    }

    private func selectSkillFromMention(_ skill: Skill) {
        if let atIndex = text.lastIndex(of: "@") {
            let beforeAt = String(text[..<atIndex])
            text = beforeAt + "@" + skill.name + " "
        }

        if !selectedSkills.contains(where: { $0.name == skill.name }) {
            selectedSkills.append(skill)
        }

        dismissSkillMentionPopup()
        onSkillSelect?(skill)
    }

    private func dismissSkillMentionPopup() {
        withAnimation(.tronStandard) {
            showSkillMentionPopup = false
            skillMentionQuery = ""
        }
    }

    private func removeSelectedSkill(_ skill: Skill) {
        selectedSkills.removeAll { $0.name == skill.name }
        onSkillRemove?(skill)
    }

    /// Trigger reasoning pill animation
    func triggerReasoningPillAnimation() {
        animationCoordinator?.updateReasoningSupport(true)
    }

    /// Hide reasoning pill
    func hideReasoningPill() {
        animationCoordinator?.updateReasoningSupport(false)
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
    VStack {
        Spacer()
        InputBar(
            text: .constant("Hello world"),
            isProcessing: false,
            isRecording: false,
            isTranscribing: false,
            selectedImages: .constant([]),
            onSend: {},
            onAbort: {},
            onMicTap: {},
            attachments: .constant([]),
            onAddAttachment: { _ in },
            onRemoveAttachment: { _ in },
            inputHistory: nil,
            onHistoryNavigate: nil,
            modelName: "claude-sonnet-4-5-20260105",
            tokenUsage: TokenUsage(inputTokens: 50000, outputTokens: 10000, cacheReadTokens: nil, cacheCreationTokens: nil),
            contextPercentage: 30,
            contextWindow: 200_000,
            lastTurnInputTokens: 60000,
            cachedModels: [],
            isLoadingModels: false,
            onModelSelect: nil,
            reasoningLevel: .constant("medium"),
            currentModelInfo: nil,
            onReasoningLevelChange: nil,
            selectedSkills: .constant([]),
            onSkillRemove: nil,
            onSkillDetailTap: nil
        )
    }
    .preferredColorScheme(.dark)
}
