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

    /// Binding to control focus (used to prevent keyboard after response)
    @Binding var shouldFocus: Bool

    @FocusState private var isFocused: Bool
    @ObservedObject private var audioMonitor = AudioAvailabilityMonitor.shared
    @State private var showingImagePicker = false
    @State private var showCamera = false
    @State private var showFilePicker = false
    @State private var isMicPulsing = false
    @State private var showMicButton = false
    @State private var showAttachmentButton = false
    @State private var showModelPill = false
    @State private var showTokenPill = false
    @State private var showReasoningPill = false
    @State private var introTask: Task<Void, Never>?
    @State private var reasoningPillTask: Task<Void, Never>?
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
            // Unified attachments preview (new model)
            if !attachments.isEmpty {
                attachmentsRow
            }


            // Status pills row - floating liquid glass elements
            if shouldShowStatusPills {
                statusPillsRow
                    .padding(.horizontal, 16)
                    .transition(.opacity)
            }

            // Input row - floating liquid glass elements
            HStack(alignment: .bottom, spacing: 12) {
                // Attachment button - liquid glass (morphs in from left)
                if showAttachmentButton {
                    attachmentButtonGlass
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }

                // Text field with glass background
                textFieldGlass

                // Send/Abort button - liquid glass
                if shouldShowActionButton {
                    actionButtonGlass
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }

                // Mic button - liquid glass
                if shouldShowMicButton {
                    micButtonGlass
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .overlay(alignment: .topLeading) {
                // Attachment button dock (left side)
                if !showAttachmentButton {
                    attachmentButtonDock
                }
            }
            .overlay(alignment: .topTrailing) {
                if shouldShowTokenPillDock {
                    tokenStatsPillDock
                }
            }
            .animation(attachmentButtonAnimation, value: showAttachmentButton)
            .animation(.tronStandard, value: shouldShowActionButton)
            .animation(micButtonAnimation, value: shouldShowMicButton)
        }
        // iOS 26: No background - elements float with glass effects only
        // Swipe down gesture to dismiss keyboard
        .simultaneousGesture(
            DragGesture(minimumDistance: 20, coordinateSpace: .local)
                .onEnded { value in
                    // Detect downward swipe (positive Y translation)
                    // and ensure it's more vertical than horizontal
                    let isDownwardSwipe = value.translation.height > 30
                    let isVertical = abs(value.translation.height) > abs(value.translation.width) * 1.5
                    if isDownwardSwipe && isVertical && isFocused {
                        isFocused = false
                    }
                }
        )
        // Sync focus state with parent control
        .onAppear {
            // Reset state to ensure fresh animation on each appearance
            resetIntroState()
            // Small delay to ensure view is fully attached before animating
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                playIntroSequence()
            }
        }
        .onDisappear {
            introTask?.cancel()
            introTask = nil
            reasoningPillTask?.cancel()
            reasoningPillTask = nil
            // Reset state for clean re-entry on next appearance
            resetIntroState()
        }
        .onChange(of: shouldFocus) { _, newValue in
            if newValue && !isProcessing {
                isFocused = true
            } else if !newValue {
                isFocused = false
            }
        }
        .onChange(of: isFocused) { _, newValue in
            shouldFocus = newValue
        }
        // Animate reasoning pill when model changes or first loads
        .onChange(of: currentModelInfo?.id) { oldModelId, newModelId in
            if currentModelInfo?.supportsReasoning == true {
                // Model supports reasoning - trigger animation
                // Works for both initial load and model switches
                triggerReasoningPillAnimation()
            } else if oldModelId != nil {
                // Only hide if we're switching away from a model (not initial nil state)
                hideReasoningPill()
            }
        }
        // Also check reasoning pill when model pill appears (handles initial load timing)
        .onChange(of: showModelPill) { _, isShowing in
            if isShowing && currentModelInfo?.supportsReasoning == true && !showReasoningPill {
                triggerReasoningPillAnimation()
            }
        }
        // Handle case where model info arrives after model pill is already shown
        .onChange(of: currentModelInfo?.supportsReasoning) { _, supportsReasoning in
            if supportsReasoning == true && showModelPill && !showReasoningPill {
                triggerReasoningPillAnimation()
            } else if supportsReasoning != true && showReasoningPill {
                hideReasoningPill()
            }
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
                    print("Failed to read document: \(error)")
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

    // MARK: - Status Pills Row (iOS 26 Liquid Glass)

    private var statusPillsRow: some View {
        HStack {
            // Model picker - iOS 26 fix: Use NotificationCenter to decouple from state
            // Order: Legacy (top) → Codex → Anthropic 4.5 (bottom, closest to thumb)
            if !modelName.isEmpty && showModelPill {
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
                            .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.4)), in: .capsule)
                    }
                    .contentShape(Capsule())
                }
            }

            // Reasoning level picker (for OpenAI Codex models)
            // iOS 26 fix: Inline Menu with NotificationCenter (same pattern as model picker)
            if currentModelInfo?.supportsReasoning == true, showReasoningPill {
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
                            .glassEffect(.regular.tint(reasoningLevelColor(reasoningLevel).opacity(0.4)), in: .capsule)
                    }
                    .contentShape(Capsule())
                }
                .matchedGeometryEffect(id: "reasoningPillMorph", in: reasoningPillNamespace)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.6, anchor: .leading).combined(with: .opacity),
                    removal: .scale(scale: 0.8).combined(with: .opacity)
                ))
            }

            Spacer()

            // Token stats pill with liquid glass
            if showTokenPill {
                tokenStatsPill
                    .matchedGeometryEffect(id: "tokenPillMorph", in: tokenPillNamespace)
            }
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
        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.4)), in: .capsule)
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
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isProcessing ? Color.tronEmerald.opacity(0.3) : Color.tronEmerald)
                .frame(width: actionButtonSize, height: actionButtonSize)
                .background {
                    Circle()
                        .fill(.clear)
                        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.3)).interactive(), in: .circle)
                }
                .contentShape(Circle())
        }
        .matchedGeometryEffect(id: "attachmentButtonMorph", in: attachmentButtonNamespace)
        .disabled(isProcessing)
        // iOS 26 Menu workaround: Handle attachment actions via NotificationCenter
        .onReceive(NotificationCenter.default.publisher(for: .attachmentMenuAction)) { notification in
            guard let action = notification.object as? String else { return }
            switch action {
            case "camera": showCamera = true
            case "photos": showingImagePicker = true
            case "files": showFilePicker = true
            default: break
            }
        }
    }

    // MARK: - Simplified Text Field (without history navigation)

    private var textFieldSimplified: some View {
        TextField("Message...", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.subheadline)
            .foregroundStyle(.tronTextPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.tronSurfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .lineLimit(1...8)
            .focused($isFocused)
            .disabled(isProcessing)
            .onSubmit {
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    onSend()
                }
            }
    }

    // MARK: - Glass Text Field (iOS 26 Liquid Glass)

    private var textFieldGlass: some View {
        TextField("Message...", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.9))
            .padding(.leading, 14)
            .padding(.trailing, textFieldTrailingPadding)
            .padding(.vertical, 10)
            .frame(minHeight: 40)
            .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.3)), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .lineLimit(1...8)
            .focused($isFocused)
            .disabled(isProcessing)
            .onSubmit {
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    onSend()
                }
            }
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

                TextField("Message...", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(.tronTextPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.tronSurfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .lineLimit(1...8)
                    .focused($isFocused)
                    .disabled(isProcessing)
                    .onSubmit {
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            onSend()
                        }
                    }
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
            .regular.tint(canSend && !isProcessing ? Color.tronEmeraldDark : Color.tronPhthaloGreen.opacity(0.3)).interactive(),
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

    private var micButtonDock: some View {
        Circle()
            .fill(Color.clear)
            .frame(width: actionButtonSize, height: actionButtonSize)
            .matchedGeometryEffect(id: "micButtonMorph", in: micButtonNamespace)
            .offset(x: -micDockInset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var attachmentButtonDock: some View {
        Circle()
            .fill(Color.clear)
            .frame(width: actionButtonSize, height: actionButtonSize)
            .matchedGeometryEffect(id: "attachmentButtonMorph", in: attachmentButtonNamespace)
            .offset(x: attachmentDockInset)
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
        .matchedGeometryEffect(id: "micButtonMorph", in: micButtonNamespace)
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
        return Color.tronPhthaloGreen.opacity(0.3)
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
        showTokenPill || (showModelPill && !modelName.isEmpty)
    }

    private var shouldShowModelPillDock: Bool {
        !showModelPill && !modelName.isEmpty
    }

    private var shouldShowTokenPillDock: Bool {
        !showTokenPill
    }

    private var shouldShowMicButton: Bool {
        showMicButton
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

    private func resetIntroState() {
        showAttachmentButton = false
        showModelPill = false
        showTokenPill = false
        showReasoningPill = false
        showMicButton = false
    }

    private func playIntroSequence() {
        introTask?.cancel()
        reasoningPillTask?.cancel()
        resetIntroState()

        introTask = Task { @MainActor in
            // Attachment button morphs in from left with 350ms delay
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(attachmentButtonAnimation) {
                showAttachmentButton = true
            }

            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(modelPillAnimation) {
                showModelPill = true
            }

            // Show reasoning pill after model pill if current model supports it
            if currentModelInfo?.supportsReasoning == true {
                try? await Task.sleep(nanoseconds: 150_000_000) // 150ms delay
                guard !Task.isCancelled else { return }
                withAnimation(reasoningPillAnimation) {
                    showReasoningPill = true
                }
            }

            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(tokenPillAnimation) {
                showTokenPill = true
            }

            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(micButtonAnimation) {
                showMicButton = true
            }
        }
    }

    /// Animation for reasoning pill morph
    private var reasoningPillAnimation: Animation {
        .spring(response: 0.4, dampingFraction: 0.8)
    }

    /// Trigger reasoning pill animation when switching to a model that supports reasoning
    func triggerReasoningPillAnimation() {
        reasoningPillTask?.cancel()
        reasoningPillTask = Task { @MainActor in
            // Hide first if already showing
            if showReasoningPill {
                withAnimation(reasoningPillAnimation) {
                    showReasoningPill = false
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            // Wait a beat then show
            try? await Task.sleep(nanoseconds: 250_000_000) // 250ms delay after model change
            guard !Task.isCancelled else { return }

            if currentModelInfo?.supportsReasoning == true {
                withAnimation(reasoningPillAnimation) {
                    showReasoningPill = true
                }
            }
        }
    }

    /// Hide reasoning pill when switching away from a reasoning model
    func hideReasoningPill() {
        reasoningPillTask?.cancel()
        withAnimation(reasoningPillAnimation) {
            showReasoningPill = false
        }
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
            shouldFocus: .constant(false)
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
