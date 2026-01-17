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
    var contextWindow: Int = 0  // From server via ChatViewModel.currentContextWindow
    var lastTurnInputTokens: Int = 0  // Actual current context size for accurate "X left" display

    // Model picker integration
    var cachedModels: [ModelInfo] = []
    var isLoadingModels: Bool = false
    var onModelSelect: ((ModelInfo) -> Void)?

    // Reasoning level picker (for OpenAI Codex models)
    @Binding var reasoningLevel: String
    var currentModelInfo: ModelInfo?
    var onReasoningLevelChange: ((String) -> Void)?

    // Context manager action
    var onContextTap: (() -> Void)?

    // Skills integration
    var skillStore: SkillStore?
    var onSkillSelect: ((Skill) -> Void)?

    /// Selected skills to be sent with the message (rendered as chips)
    @Binding var selectedSkills: [Skill]
    /// Callback when a skill is removed from selection
    var onSkillRemove: ((Skill) -> Void)?
    /// Callback when skill detail sheet should be shown
    var onSkillDetailTap: ((Skill) -> Void)?

    /// Optional animation coordinator for chained pill morph animations
    /// When provided, uses coordinator's phase state instead of local timing
    var animationCoordinator: AnimationCoordinator?

    @FocusState private var isFocused: Bool
    /// Prevents auto-focus immediately after agent finishes responding
    @State private var blockFocusUntil: Date = .distantPast
    @ObservedObject private var audioMonitor = AudioAvailabilityMonitor.shared
    @State private var showingImagePicker = false
    @State private var showCamera = false
    @State private var showFilePicker = false
    @State private var showSkillMentionPopup = false
    @State private var skillMentionQuery = ""
    @State private var isMicPulsing = false
    /// Controls entrance morph animation - starts false, animates to true after view appears
    /// When false: docks visible (inside text field), buttons hidden
    /// When true: buttons visible (morphed out), docks hidden
    /// matchedGeometryEffect creates smooth morph between dock and button positions
    @State private var hasAppeared = false
    /// Tracks if attachment button should be visible (for morph animation)
    @State private var showAttachmentButton = false
    /// Tracks if mic button should be visible (for morph animation)
    @State private var showMicButton = false
    @Namespace private var actionButtonNamespace
    @Namespace private var modelPillNamespace
    @Namespace private var tokenPillNamespace
    @Namespace private var micButtonNamespace
    @Namespace private var reasoningPillNamespace
    @Namespace private var attachmentButtonNamespace

    private let actionButtonSize: CGFloat = 40
    private let micDockInset: CGFloat = 18
    private let attachmentDockInset: CGFloat = 18

    var body: some View {
        VStack(spacing: 10) {
            // Skill mention popup (appears above everything when typing @)
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
            // All positioned close together, anchored above the input bar
            contentArea
                .padding(.horizontal, 16)
                .transition(.opacity)

            // Input row - floating liquid glass elements with morph animations
            // Buttons morph OUT from text field edges via matchedGeometryEffect
            // Conditional rendering triggers the morph: when button appears, dock disappears
            HStack(alignment: .bottom, spacing: 12) {
                // Attachment button - morphs out from left edge of text field
                if showAttachmentButton {
                    attachmentButtonGlass
                        .matchedGeometryEffect(id: "attachmentMorph", in: attachmentButtonNamespace)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }

                // Text field with glass background
                textFieldGlass
                    .overlay(alignment: .leading) {
                        // Attachment dock - morph origin inside text field (when button hidden)
                        if !showAttachmentButton {
                            attachmentButtonDock
                                .matchedGeometryEffect(id: "attachmentMorph", in: attachmentButtonNamespace)
                        }
                    }
                    .overlay(alignment: .trailing) {
                        // Mic dock - morph origin inside text field (when button hidden)
                        HStack(spacing: 8) {
                            if !shouldShowActionButton {
                                actionButtonDock
                            }
                            if !showMicButton {
                                micButtonDock
                                    .matchedGeometryEffect(id: "micMorph", in: micButtonNamespace)
                            }
                        }
                        .padding(.trailing, 8)
                    }

                // Send/Abort button - liquid glass (standard show/hide, not morph)
                if shouldShowActionButton {
                    actionButtonGlass
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }

                // Mic button - morphs out from right edge of text field
                if showMicButton {
                    micButtonGlass
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
        // Block any focus attempts immediately after agent finishes
        .onChange(of: isFocused) { _, newValue in
            if newValue && Date() < blockFocusUntil {
                // Immediately cancel focus attempt
                isFocused = false
            }
        }
        .animation(nil, value: isFocused) // Disable focus animations to prevent jitter
        // Dismiss keyboard when agent finishes
        .onChange(of: isProcessing) { wasProcessing, isNowProcessing in
            if wasProcessing && !isNowProcessing {
                // Agent finished - dismiss keyboard and block focus attempts
                isFocused = false
                blockFocusUntil = Date().addingTimeInterval(0.5)
            }
        }
        // Update animation coordinator when model changes (for legacy animation support)
        .onChange(of: currentModelInfo?.supportsReasoning) { _, supportsReasoning in
            animationCoordinator?.updateReasoningSupport(supportsReasoning == true)
        }
        // Detect @ mentions for skill popup
        .onChange(of: text) { _, newText in
            detectSkillMention(in: newText)
        }
        // Camera picker sheet
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
        // Document picker sheet
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
        // Photo library picker (triggered by menu button)
        .photosPicker(
            isPresented: $showingImagePicker,
            selection: $selectedImages,
            maxSelectionCount: 5,
            matching: .images
        )
        // Entrance morph animation - buttons morph out from text field
        .onAppear {
            // Reset state for fresh animation
            showAttachmentButton = false
            showMicButton = false
            hasAppeared = false

            // Staggered morph sequence after navigation completes
            Task { @MainActor in
                // Wait for navigation to complete
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms

                // 1. Attachment button morphs out from left
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    showAttachmentButton = true
                }

                // 2. Short delay then mic button morphs out from right
                try? await Task.sleep(nanoseconds: 130_000_000) // 130ms
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    showMicButton = true
                }

                // 3. Mark hasAppeared for pills
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    hasAppeared = true
                }
            }
        }
        .onDisappear {
            // Reset for next entrance
            showAttachmentButton = false
            showMicButton = false
            hasAppeared = false
        }
    }

    // MARK: - Model Categorization

    /// Anthropic 4.5 models (latest) - sorted: Haiku (top) → Sonnet → Opus (bottom, closest to thumb)
    private var latestAnthropicModels: [ModelInfo] {
        cachedModels.filter { $0.isAnthropic && $0.is45Model }
            .sorted { tierPriority($0) > tierPriority($1) }
    }

    /// OpenAI Codex models - sorted: 5.1 (top) → 5.2 (bottom, closest to thumb)
    private var codexModels: [ModelInfo] {
        cachedModels.filter { $0.provider.lowercased() == "openai-codex" }
            .sorted { codexVersionPriority($0) < codexVersionPriority($1) }
    }

    /// Legacy Anthropic models (non-4.5) - sorted: Sonnet (top) → Opus (bottom)
    private var legacyModels: [ModelInfo] {
        cachedModels.filter { $0.isAnthropic && !$0.is45Model }
            .sorted { tierPriority($0) > tierPriority($1) }
    }

    private func tierPriority(_ model: ModelInfo) -> Int {
        let id = model.id.lowercased()
        if id.contains("opus") { return 0 }
        if id.contains("sonnet") { return 1 }
        if id.contains("haiku") { return 2 }
        return 3
    }

    private func codexVersionPriority(_ model: ModelInfo) -> Int {
        let id = model.id.lowercased()
        if id.contains("5.2") { return 52 }
        if id.contains("5.1") { return 51 }
        if id.contains("5.0") || id.contains("-5-") { return 50 }
        return 0
    }

    // MARK: - Reasoning Level Helpers

    private func reasoningLevelLabel(_ level: String) -> String {
        switch level.lowercased() {
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Max"
        default: return level.capitalized
        }
    }

    private func reasoningLevelIcon(_ level: String) -> String {
        switch level.lowercased() {
        case "low": return "hare"
        case "medium": return "brain"
        case "high": return "brain.head.profile"
        case "xhigh": return "sparkles"
        default: return "brain"
        }
    }

    private func reasoningLevelColor(_ level: String) -> Color {
        let levels = ["low", "medium", "high", "xhigh"]
        let index = levels.firstIndex(of: level.lowercased()) ?? 0
        let progress = Double(index) / Double(max(levels.count - 1, 1))
        // Interpolate from #1F5E3F to #00A69B
        let lowR = 31.0 / 255.0, lowG = 94.0 / 255.0, lowB = 63.0 / 255.0
        let highR = 0.0 / 255.0, highG = 166.0 / 255.0, highB = 155.0 / 255.0
        return Color(
            red: lowR + (progress * (highR - lowR)),
            green: lowG + (progress * (highG - lowG)),
            blue: lowB + (progress * (highB - lowB))
        )
    }

    /// Available reasoning levels for current model (computed property like model picker)
    private var availableReasoningLevels: [String] {
        currentModelInfo?.reasoningLevels ?? ["low", "medium", "high", "xhigh"]
    }

    // MARK: - Content Area (Attachments + Skills + Status Pills)

    /// Main content area showing skills, attachments (with wrapping), and status pills
    /// All items in one wrapping container - skills at bottom, attachments wrap above
    /// IMPORTANT: Status pills are always in layout (opacity-controlled) to prevent height changes
    /// that would cause safeAreaInset to shift the ScrollView content
    @ViewBuilder
    private var contentArea: some View {
        HStack(alignment: .bottom, spacing: 12) {
            // Skills + Attachments in single wrapping container
            // Skills first (bottom), attachments after (wrap above)
            if !selectedSkills.isEmpty || !attachments.isEmpty {
                wrappingSkillsAndAttachments
            }

            Spacer(minLength: 0)

            // Status pills column - ALWAYS in layout to maintain stable height
            // Uses opacity for visibility to prevent safeAreaInset changes
            statusPillsColumn
                .opacity(shouldShowStatusPills ? 1 : 0)
        }
    }

    /// Combined wrapping container for skills and attachments
    /// Skills appear at bottom rows, attachments wrap to rows above
    private var wrappingSkillsAndAttachments: some View {
        WrappingHStack(spacing: 8, lineSpacing: 8) {
            // Skills first (will appear on bottom rows)
            ForEach(selectedSkills, id: \.name) { skill in
                SkillChip(
                    skill: skill,
                    showRemoveButton: true,
                    onRemove: { removeSelectedSkill(skill) },
                    onTap: { onSkillDetailTap?(skill) }
                )
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.8).combined(with: .opacity),
                    removal: .scale(scale: 0.6).combined(with: .opacity)
                ))
            }

            // Line break to ensure attachments always start on new row above skills
            if !selectedSkills.isEmpty && !attachments.isEmpty {
                LineBreak()
            }

            // Attachments after (will wrap to rows above skills)
            ForEach(attachments) { attachment in
                AttachmentBubble(attachment: attachment) {
                    onRemoveAttachment(attachment)
                }
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.8).combined(with: .opacity),
                    removal: .scale(scale: 0.6).combined(with: .opacity)
                ))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: selectedSkills.count)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: attachments.count)
    }

    // MARK: - Legacy Combined Status Row (kept for reference)

    /// Combined row that shows:
    /// - Left side: skills (if present) OR attachments (if only attachments, no skills)
    /// - Right side: model and context pills
    /// Aligned to bottom so skills/attachments align with context pill
    private var combinedStatusRow: some View {
        HStack(alignment: .bottom, spacing: 12) {
            // Left side content
            if !selectedSkills.isEmpty {
                // Skills on left (when skills are present)
                skillChipsRowInline
            } else if !attachments.isEmpty {
                // Attachments on left (only when no skills, but attachments present)
                attachmentsRowInline
            }

            Spacer(minLength: 0)

            // Right side: status pills (always shown if available)
            if shouldShowStatusPills {
                statusPillsColumn
            }
        }
    }

    /// Skills chips displayed inline (for combined row)
    private var skillChipsRowInline: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(selectedSkills, id: \.name) { skill in
                    SkillChip(
                        skill: skill,
                        showRemoveButton: true,
                        onRemove: { removeSelectedSkill(skill) },
                        onTap: { onSkillDetailTap?(skill) }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Attachments displayed inline (for combined row)
    private var attachmentsRowInline: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentBubble(attachment: attachment) {
                        onRemoveAttachment(attachment)
                    }
                }
            }
        }
        .frame(height: 60)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Status pills column (model + context pills stacked vertically, right-aligned)
    /// Pill order from top to bottom: reasoning → model → token (context)
    /// IMPORTANT: All pills are ALWAYS in layout to maintain stable height
    /// Visibility is controlled via opacity to prevent safeAreaInset changes
    /// Entrance animation: pills morph UP from collapsed state with staggered timing
    private var statusPillsColumn: some View {
        VStack(alignment: .trailing, spacing: 8) {
            // Reasoning level picker - morphs up from model pill area
            reasoningLevelMenu
                .scaleEffect(hasAppeared && effectiveShowReasoningPill ? 1 : 0.3, anchor: .bottom)
                .opacity(hasAppeared && effectiveShowReasoningPill ? 1 : 0)
                .allowsHitTesting(hasAppeared && effectiveShowReasoningPill)

            // Model picker - morphs up from token pill area
            modelPickerMenu
                .scaleEffect(hasAppeared && effectiveShowModelPill ? 1 : 0.3, anchor: .bottom)
                .opacity(hasAppeared && effectiveShowModelPill ? 1 : 0)
                .allowsHitTesting(hasAppeared && effectiveShowModelPill)

            // Token stats pill - morphs up from bottom (first to appear)
            tokenStatsPillWithChevrons
                .scaleEffect(hasAppeared ? 1 : 0.3, anchor: .bottom)
                .opacity(hasAppeared ? 1 : 0)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: hasAppeared)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: effectiveShowModelPill)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: effectiveShowReasoningPill)
    }

    /// Model picker menu (iOS 26 liquid glass)
    private var modelPickerMenu: some View {
        Menu {
            // Anthropic 4.5 models at top (closest to thumb when menu opens upward)
            ForEach(latestAnthropicModels) { model in
                Button { NotificationCenter.default.post(name: .modelPickerAction, object: model) } label: {
                    Label(model.formattedModelName, systemImage: "sparkles")
                }
            }
            Divider()

            // OpenAI Codex models in middle
            if !codexModels.isEmpty {
                ForEach(codexModels) { model in
                    Button { NotificationCenter.default.post(name: .modelPickerAction, object: model) } label: {
                        Label(model.formattedModelName, systemImage: "bolt")
                    }
                }
                Divider()
            }

            // Legacy models at bottom (furthest from thumb)
            if !legacyModels.isEmpty {
                ForEach(legacyModels) { model in
                    Button { NotificationCenter.default.post(name: .modelPickerAction, object: model) } label: {
                        Label(model.formattedModelName, systemImage: "clock")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.system(size: 9, weight: .medium))
                Text(modelName.shortModelName)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .medium))
            }
            .foregroundStyle(.tronEmerald)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule()
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.35)), in: .capsule)
            }
            .contentShape(Capsule())
        }
    }

    /// Reasoning level picker menu (iOS 26 liquid glass)
    private var reasoningLevelMenu: some View {
        Menu {
            Button { NotificationCenter.default.post(name: .reasoningLevelAction, object: "low") } label: {
                Label("Low", systemImage: "hare")
            }
            Button { NotificationCenter.default.post(name: .reasoningLevelAction, object: "medium") } label: {
                Label("Medium", systemImage: "brain")
            }
            Button { NotificationCenter.default.post(name: .reasoningLevelAction, object: "high") } label: {
                Label("High", systemImage: "brain.head.profile")
            }
            Button { NotificationCenter.default.post(name: .reasoningLevelAction, object: "xhigh") } label: {
                Label("Max", systemImage: "sparkles")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: reasoningLevelIcon(reasoningLevel))
                    .font(.system(size: 9, weight: .medium))
                Text(reasoningLevelLabel(reasoningLevel))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .medium))
            }
            .foregroundStyle(reasoningLevelColor(reasoningLevel))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule()
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.35)), in: .capsule)
            }
            .contentShape(Capsule())
        }
        .matchedGeometryEffect(id: "reasoningPillMorph", in: reasoningPillNamespace)
        .transition(.asymmetric(
            insertion: .scale(scale: 0.6, anchor: .leading).combined(with: .opacity),
            removal: .scale(scale: 0.8).combined(with: .opacity)
        ))
    }

    // MARK: - Status Pills Row (iOS 26 Liquid Glass) - Legacy
    // NOTE: This view is deprecated - use statusPillsColumn instead
    // Kept for reference but not used in the main layout

    private var statusPillsRow: some View {
        HStack {
            Spacer()
            statusPillsColumn
        }
    }

    private var contextPercentageColor: Color {
        if contextPercentage >= 95 {
            return .red
        } else if contextPercentage >= 80 {
            return .orange
        }
        return .tronEmerald
    }

    private var tokensRemaining: Int {
        // Use last turn's input tokens as actual context size
        // (input tokens already includes system prompt + history, so it's the full context)
        return max(0, contextWindow - lastTurnInputTokens)
    }

    private var formattedTokensRemaining: String {
        let remaining = tokensRemaining
        if remaining >= 1_000_000 {
            return String(format: "%.1fM", Double(remaining) / 1_000_000)
        } else if remaining >= 1000 {
            return String(format: "%.0fk", Double(remaining) / 1000)
        }
        return "\(remaining)"
    }

    private var tokenStatsPill: some View {
        Button {
            onContextTap?()
        } label: {
            HStack(spacing: 8) {
                // Context usage bar - use overlay + clipShape to prevent overflow
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 40, height: 6)
                    .overlay(alignment: .leading) {
                        // Fill rectangle that gets clipped by parent Capsule shape
                        Rectangle()
                            .fill(contextPercentageColor)
                            .frame(width: 40 * min(CGFloat(contextPercentage) / 100.0, 1.0))
                    }
                    .clipShape(Capsule())

                // Tokens remaining
                Text("\(formattedTokensRemaining) left")
                    .foregroundStyle(contextPercentageColor)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.35)).interactive(), in: .capsule)
    }

    private var tokenStatsPillWithChevrons: some View {
        Button {
            onContextTap?()
        } label: {
            HStack(spacing: 8) {
                // Context usage bar - use overlay + clipShape to prevent overflow
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 40, height: 6)
                    .overlay(alignment: .leading) {
                        // Fill rectangle that gets clipped by parent Capsule shape
                        Rectangle()
                            .fill(contextPercentageColor)
                            .frame(width: 40 * min(CGFloat(contextPercentage) / 100.0, 1.0))
                    }
                    .clipShape(Capsule())

                // Tokens remaining + Chevrons (spacing: 4 to match model pill)
                HStack(spacing: 4) {
                    Text("\(formattedTokensRemaining) left")
                        .foregroundStyle(contextPercentageColor)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(contextPercentageColor)
                }
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.35)).interactive(), in: .capsule)
    }

    // MARK: - Unified Attachments Row

    private var attachmentsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentBubble(attachment: attachment) {
                        onRemoveAttachment(attachment)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 60)
    }

    // MARK: - Attachment Button (iOS 26 Liquid Glass)

    /// Whether skills are available for selection
    private var hasSkillsAvailable: Bool {
        skillStore != nil && (skillStore?.totalCount ?? 0) > 0
    }

    private var attachmentButtonGlass: some View {
        Menu {
            // iOS 26 fix: Use NotificationCenter to decouple button action from state mutation
            Button { NotificationCenter.default.post(name: .attachmentMenuAction, object: "camera") } label: {
                Label("Take Photo", systemImage: "camera")
            }

            Button { NotificationCenter.default.post(name: .attachmentMenuAction, object: "photos") } label: {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }

            Button { NotificationCenter.default.post(name: .attachmentMenuAction, object: "files") } label: {
                Label("Choose File", systemImage: "folder")
            }

            // Skills section (only show if skillStore is configured)
            if skillStore != nil {
                Divider()

                Button { NotificationCenter.default.post(name: .attachmentMenuAction, object: "skills") } label: {
                    Label("Add Skill", systemImage: "sparkles")
                }
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isProcessing ? Color.tronEmerald.opacity(0.3) : Color.tronEmerald)
                    .frame(width: actionButtonSize, height: actionButtonSize)
                    .background {
                        Circle()
                            .fill(.clear)
                            .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.35)).interactive(), in: .circle)
                    }
                    .contentShape(Circle())

                // Skills available indicator - small sparkles badge
                if hasSkillsAvailable && !isProcessing {
                    Image(systemName: "sparkle")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tronCyan)
                        .offset(x: 2, y: -2)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .disabled(isProcessing)
        // iOS 26 Menu workaround: Handle attachment actions via NotificationCenter
        .onReceive(NotificationCenter.default.publisher(for: .attachmentMenuAction)) { notification in
            guard let action = notification.object as? String else { return }
            switch action {
            case "camera": showCamera = true
            case "photos": showingImagePicker = true
            case "files": showFilePicker = true
            case "skills":
                // Show the non-blocking skill mention popup instead of the old sheet
                withAnimation(.tronStandard) {
                    showSkillMentionPopup = true
                    skillMentionQuery = "" // Start with empty query to show all skills
                }
            default: break
            }
        }
    }

    // MARK: - Simplified Text Field (without history navigation)

    private var textFieldSimplified: some View {
        ZStack(alignment: .leading) {
            // Placeholder overlay - only show when empty AND not focused
            if text.isEmpty && !isFocused {
                Text("Type here")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.tronEmerald.opacity(0.5))
                    .padding(.leading, 14)
                    .padding(.vertical, 10)
            }

            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.tronEmerald)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .lineLimit(1...8)
                .focused($isFocused)
                .disabled(isProcessing)
                .onSubmit {
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        onSend()
                    }
                }
        }
        .background(Color.tronSurfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Glass Text Field (iOS 26 Liquid Glass)

    private var textFieldGlass: some View {
        ZStack(alignment: .leading) {
            // Placeholder overlay - only show when empty AND not focused
            if text.isEmpty && !isFocused {
                Text("Type here")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.tronEmerald.opacity(0.5))
                    .padding(.leading, 14)
                    .padding(.vertical, 10)
            }

            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.tronEmerald)
                .padding(.leading, 14)
                .padding(.trailing, textFieldTrailingPadding)
                .padding(.vertical, 10)
                .lineLimit(1...8)
                .focused($isFocused)
                .disabled(isProcessing)
                .onSubmit {
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        onSend()
                    }
                }
        }
        .frame(minHeight: actionButtonSize)
        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.35)), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .leading) {
            if shouldShowModelPillDock {
                modelPillDock
            }
        }
        .overlay(alignment: .trailing) {
            if shouldShowTrailingDock {
                trailingDock
            }
        }
        .animation(.tronStandard, value: shouldShowActionButton)
        .animation(micButtonAnimation, value: shouldShowMicButton)
    }

    // MARK: - Text Field (preserved implementation with history)

    private var textField: some View {
        VStack(spacing: 4) {
            // History indicator
            if let history = inputHistory, history.isNavigating,
               let position = history.navigationPosition {
                Text("History: \(position)")
                    .font(.caption2)
                    .foregroundStyle(.tronTextMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.tronSurfaceElevated)
                    .clipShape(Capsule())
            }

            HStack(spacing: 8) {
                // History navigation buttons
                if inputHistory != nil {
                    historyNavigationButtons
                }

                ZStack(alignment: .leading) {
                    // Placeholder overlay - only show when empty AND not focused
                    if text.isEmpty && !isFocused {
                        Text("Type here")
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(.tronEmerald.opacity(0.5))
                            .padding(.leading, 14)
                            .padding(.vertical, 10)
                    }

                    TextField("", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.tronEmerald)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .lineLimit(1...8)
                        .focused($isFocused)
                        .disabled(isProcessing)
                        .onSubmit {
                            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                onSend()
                            }
                        }
                }
                .background(Color.tronSurfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    // MARK: - History Navigation

    private var historyNavigationButtons: some View {
        VStack(spacing: 2) {
            Button {
                navigateHistoryUp()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption)
                    .foregroundStyle(.tronTextSecondary)
                    .frame(width: 24, height: 16)
            }
            .disabled(isProcessing || inputHistory?.history.isEmpty == true)

            Button {
                navigateHistoryDown()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.tronTextSecondary)
                    .frame(width: 24, height: 16)
            }
            .disabled(isProcessing || inputHistory?.isNavigating != true)
        }
    }

    private func navigateHistoryUp() {
        guard let history = inputHistory else { return }
        if let newText = history.navigateUp(currentInput: text) {
            onHistoryNavigate?(newText)
        }
    }

    private func navigateHistoryDown() {
        guard let history = inputHistory else { return }
        if let newText = history.navigateDown() {
            onHistoryNavigate?(newText)
        }
    }

    /// Insert a skill reference (@skillname) into the text field
    private func insertSkillReference(_ skill: Skill) {
        let reference = "@\(skill.name) "

        // If text is empty or ends with space/newline, just append
        if text.isEmpty || text.hasSuffix(" ") || text.hasSuffix("\n") {
            text += reference
        } else {
            // Add a space before the reference
            text += " " + reference
        }

        // Notify via callback if provided
        onSkillSelect?(skill)
    }

    // MARK: - Skill Mention Detection

    /// Detect @ mentions in the text and show/hide the popup accordingly
    /// Also detects completed @skillname (with trailing space) and auto-adds chip
    private func detectSkillMention(in newText: String) {
        guard let store = skillStore else { return }

        // First check if user just completed a @skillname with a space
        // This handles the case where user types full skill name and presses space
        if let completedSkill = detectCompletedSkillMention(in: newText, skills: store.skills) {
            // Found a completed @skillname - add it as a chip
            selectCompletedSkillMention(completedSkill, in: newText)
            return
        }

        // Otherwise, check for active mention (no space yet)
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

    /// Detect if the user just completed typing @skillname followed by a space
    /// Returns the matched skill if found, nil otherwise
    private func detectCompletedSkillMention(in text: String, skills: [Skill]) -> Skill? {
        // Find all @mentions in the text and check if any match a skill
        // that isn't already selected
        let pattern = "@([a-zA-Z0-9][a-zA-Z0-9-]*)(?:\\s|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }

        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, options: [], range: range)

        for match in matches.reversed() { // Check most recent first
            // Get the skill name (capture group 1)
            guard match.numberOfRanges > 1 else { continue }
            let skillNameRange = match.range(at: 1)
            let skillName = nsText.substring(with: skillNameRange)

            // Skip if empty
            guard !skillName.isEmpty else { continue }

            // Check if this @ is at start or preceded by whitespace
            let atIndex = match.range.location
            if atIndex > 0 {
                let prevChar = nsText.character(at: atIndex - 1)
                let prevCharScalar = Unicode.Scalar(prevChar)!
                let isWhitespace = CharacterSet.whitespacesAndNewlines.contains(prevCharScalar)
                guard isWhitespace else { continue }
            }

            // Check if @ is inside backticks (code)
            let beforeAt = nsText.substring(to: atIndex)
            let backtickCount = beforeAt.filter { $0 == "`" }.count
            if backtickCount % 2 != 0 {
                continue // Inside code block
            }

            // Check if this matches an actual skill (case-insensitive)
            // and isn't already selected
            if let skill = skills.first(where: { $0.name.lowercased() == skillName.lowercased() }) {
                if !selectedSkills.contains(where: { $0.name.lowercased() == skillName.lowercased() }) {
                    return skill
                }
            }
        }

        return nil
    }

    /// Handle a completed @skillname mention - keep text and add chip
    private func selectCompletedSkillMention(_ skill: Skill, in currentText: String) {
        // Keep the @skillname text in the input (don't remove it)
        // The text already contains @skillname + space, so just leave it

        // Add skill to selected skills (avoid duplicates)
        if !selectedSkills.contains(where: { $0.name == skill.name }) {
            selectedSkills.append(skill)
        }

        // Dismiss popup if showing
        dismissSkillMentionPopup()

        // Notify via callback
        onSkillSelect?(skill)
    }

    /// Select a skill from the mention popup - complete the @mention and add chip
    private func selectSkillFromMention(_ skill: Skill) {
        // Replace the partial @query with full @skillname + space
        if let atIndex = text.lastIndex(of: "@") {
            let beforeAt = String(text[..<atIndex])
            text = beforeAt + "@" + skill.name + " "
        }

        // Add skill to selected skills (avoid duplicates)
        if !selectedSkills.contains(where: { $0.name == skill.name }) {
            selectedSkills.append(skill)
        }

        // Dismiss popup
        dismissSkillMentionPopup()

        // Notify via callback
        onSkillSelect?(skill)
    }

    /// Dismiss the skill mention popup
    private func dismissSkillMentionPopup() {
        withAnimation(.tronStandard) {
            showSkillMentionPopup = false
            skillMentionQuery = ""
        }
    }

    /// Remove a skill from the selected skills
    private func removeSelectedSkill(_ skill: Skill) {
        selectedSkills.removeAll { $0.name == skill.name }
        onSkillRemove?(skill)
    }

    // MARK: - Skill Chips Row

    private var skillChipsRow: some View {
        SkillChipRow(
            skills: selectedSkills,
            onRemove: { skill in
                removeSelectedSkill(skill)
            },
            onTap: { skill in
                onSkillDetailTap?(skill)
            }
        )
    }

    // MARK: - Action Button

    private var actionButton: some View {
        Button {
            if isProcessing {
                onAbort()
            } else {
                onSend()
            }
        } label: {
            Group {
                if isProcessing {
                    TronIconView(icon: .abort, size: 32, color: .tronError)
                } else {
                    TronIconView(
                        icon: .send,
                        size: 32,
                        color: canSend ? .tronEmerald : .tronTextDisabled
                    )
                }
            }
            .frame(width: 36, height: 36)
        }
        .disabled(!isProcessing && !canSend)
        .animation(.tronFast, value: isProcessing)
        .animation(.tronFast, value: canSend)
    }

    // MARK: - Glass Action Button (iOS 26 Liquid Glass)

    private var actionButtonGlass: some View {
        Button {
            if isProcessing {
                onAbort()
            } else {
                onSend()
            }
        } label: {
            Group {
                if isProcessing {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.red)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(canSend ? .white : .white.opacity(0.3))
                }
            }
            .frame(width: 40, height: 40)
            .contentShape(Circle())
        }
        .matchedGeometryEffect(id: "actionButtonMorph", in: actionButtonNamespace)
        .glassEffect(
            .regular.tint(canSend && !isProcessing ? Color.tronEmeraldDark : Color.tronPhthaloGreen.opacity(0.35)).interactive(),
            in: .circle
        )
        .disabled(!isProcessing && !canSend)
        .animation(.easeInOut(duration: 0.2), value: isProcessing)
        .animation(.easeInOut(duration: 0.2), value: canSend)
    }

    private var actionButtonDock: some View {
        Circle()
            .fill(Color.clear)
            .frame(width: actionButtonSize, height: actionButtonSize)
            .matchedGeometryEffect(id: "actionButtonMorph", in: actionButtonNamespace)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var modelPillDock: some View {
        ModelPillLabel(modelName: modelName, includeGlassEffect: true)
            .matchedGeometryEffect(id: "modelPillMorph", in: modelPillNamespace)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var tokenStatsPillDock: some View {
        tokenStatsPill
            .matchedGeometryEffect(id: "tokenPillMorph", in: tokenPillNamespace)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Mic button dock - morph origin point (matchedGeometryEffect added at call site)
    private var micButtonDock: some View {
        Circle()
            .fill(Color.clear)
            .frame(width: actionButtonSize, height: actionButtonSize)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Attachment button dock - morph origin point (matchedGeometryEffect added at call site)
    private var attachmentButtonDock: some View {
        Circle()
            .fill(Color.clear)
            .frame(width: actionButtonSize, height: actionButtonSize)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var trailingDock: some View {
        HStack(spacing: 12) {
            if !shouldShowActionButton {
                actionButtonDock
            }
            if !shouldShowMicButton {
                micButtonDock
            }
        }
        .padding(.trailing, 4)
    }

    // MARK: - Mic Button

    private var micButtonGlass: some View {
        Button {
            onMicTap()
        } label: {
            Group {
                if isTranscribing {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.8)
                } else if isRecording {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.red)
                } else {
                    Image(systemName: audioMonitor.isRecordingAvailable ? "mic.fill" : "mic.slash.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isMicDisabled ? Color.tronEmerald.opacity(0.3) : Color.tronEmerald)
                }
            }
            .frame(width: actionButtonSize, height: actionButtonSize)
            .contentShape(Circle())
        }
        .glassEffect(
            .regular.tint(micGlassTint).interactive(),
            in: .circle
        )
        .disabled(isMicDisabled)
        .animation(.easeInOut(duration: 0.2), value: isRecording)
        .animation(.easeInOut(duration: 0.2), value: isTranscribing)
        .onAppear {
            updateMicPulse(shouldPulse: shouldPulseMicTint)
        }
        .onChange(of: isRecording) { _, _ in
            updateMicPulse(shouldPulse: shouldPulseMicTint)
        }
        .onChange(of: isTranscribing) { _, _ in
            updateMicPulse(shouldPulse: shouldPulseMicTint)
        }
    }

    private var shouldPulseMicTint: Bool {
        isRecording && !isTranscribing
    }

    private var micGlassTint: Color {
        if shouldPulseMicTint {
            return Color.red.opacity(isMicPulsing ? 0.45 : 0.25)
        }
        return Color.tronPhthaloGreen.opacity(0.35)
    }

    private func updateMicPulse(shouldPulse: Bool) {
        guard shouldPulse else {
            isMicPulsing = false
            return
        }
        isMicPulsing = false
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
            isMicPulsing = true
        }
    }

    private var isMicDisabled: Bool {
        // Disable if audio recording is unavailable (phone call, etc.)
        if !audioMonitor.isRecordingAvailable {
            return true
        }
        if isTranscribing {
            return true
        }
        if isRecording {
            return false
        }
        return isProcessing
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private var shouldShowStatusPills: Bool {
        effectiveShowTokenPill || (effectiveShowModelPill && !modelName.isEmpty)
    }

    // MARK: - Pill Visibility
    // Pills are always visible when there's data to show - no animation sequencing needed
    // This ensures pills appear immediately on session load and re-entry

    /// Whether model pill should be visible
    private var effectiveShowModelPill: Bool {
        !modelName.isEmpty
    }

    /// Whether token/context pill should be visible
    private var effectiveShowTokenPill: Bool {
        true // Always visible - shows context stats
    }

    /// Whether reasoning pill should be visible
    private var effectiveShowReasoningPill: Bool {
        currentModelInfo?.supportsReasoning == true
    }

    private var shouldShowModelPillDock: Bool {
        !effectiveShowModelPill && !modelName.isEmpty
    }

    private var shouldShowTokenPillDock: Bool {
        !effectiveShowTokenPill
    }

    private var shouldShowMicButton: Bool {
        showMicButton // Controlled by entrance animation
    }

    private var shouldShowTrailingDock: Bool {
        !shouldShowActionButton || !shouldShowMicButton
    }

    private var shouldShowActionButton: Bool {
        isProcessing || canSend
    }

    private var textFieldTrailingPadding: CGFloat {
        let basePadding: CGFloat = 14
        var totalPadding = basePadding
        if !shouldShowActionButton {
            totalPadding += actionButtonSize + 8
        }
        if !shouldShowMicButton {
            totalPadding += actionButtonSize + 8
        }
        return totalPadding
    }

    private var modelPillAnimation: Animation {
        .spring(response: 0.42, dampingFraction: 0.82)
    }

    private var tokenPillAnimation: Animation {
        .spring(response: 0.3, dampingFraction: 0.9)
    }

    private var micButtonAnimation: Animation {
        .spring(response: 0.32, dampingFraction: 0.86)
    }

    /// Animation for attachment button morph from left (same spring as mic button)
    private var attachmentButtonAnimation: Animation {
        .spring(response: 0.32, dampingFraction: 0.86)
    }

    /// Animation for reasoning pill morph
    private var reasoningPillAnimation: Animation {
        .spring(response: 0.4, dampingFraction: 0.8)
    }

    /// Trigger reasoning pill animation when switching to a model that supports reasoning
    /// NOTE: Now just delegates to coordinator - pills are data-driven via effectiveShowReasoningPill
    func triggerReasoningPillAnimation() {
        animationCoordinator?.updateReasoningSupport(true)
    }

    /// Hide reasoning pill when switching away from a reasoning model
    /// NOTE: Now just delegates to coordinator - pills are data-driven via effectiveShowReasoningPill
    func hideReasoningPill() {
        animationCoordinator?.updateReasoningSupport(false)
    }
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

// MARK: - iOS 26 Menu Workaround Notifications

extension Notification.Name {
    /// iOS 26 Menu bug: State mutations in button actions break gesture handling
    /// Workaround: Post notification, handle via onReceive in parent view
    static let modelPickerAction = Notification.Name("modelPickerAction")
    static let attachmentMenuAction = Notification.Name("attachmentMenuAction")
    static let reasoningLevelAction = Notification.Name("reasoningLevelAction")
}

// MARK: - Wrapping HStack Layout

/// A horizontal stack that wraps items to new rows when they exceed available width
/// Items wrap from bottom to top (newest rows appear at top)
@available(iOS 16.0, *)
struct WrappingHStack: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        let width = rows.map { $0.width }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)

        // Place rows from bottom to top (so overflow rows appear above)
        var y = bounds.maxY
        for row in rows.reversed() {
            y -= row.height
            var x = bounds.minX

            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y -= lineSpacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var currentRow = Row()
        let maxWidth = proposal.width ?? .infinity

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)

            // Check if item fits in current row
            let newWidth = currentRow.width + (currentRow.indices.isEmpty ? 0 : spacing) + size.width
            if newWidth > maxWidth && !currentRow.indices.isEmpty {
                // Start new row
                rows.append(currentRow)
                currentRow = Row()
            }

            // Add item to current row
            currentRow.indices.append(index)
            currentRow.width += (currentRow.indices.count > 1 ? spacing : 0) + size.width
            currentRow.height = max(currentRow.height, size.height)
        }

        // Add final row
        if !currentRow.indices.isEmpty {
            rows.append(currentRow)
        }

        return rows
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }
}

// MARK: - Line Break for WrappingHStack

/// Invisible full-width element that forces a line break in WrappingHStack
struct LineBreak: View {
    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 0)
    }
}
