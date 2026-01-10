import SwiftUI
import PhotosUI

// MARK: - Input Bar (iOS 26 Liquid Glass)

@available(iOS 26.0, *)
struct InputBar: View {
    @Binding var text: String
    let isProcessing: Bool
    let isRecording: Bool
    let isTranscribing: Bool
    @Binding var attachedImages: [ImageContent]
    @Binding var selectedImages: [PhotosPickerItem]
    let onSend: () -> Void
    let onAbort: () -> Void
    let onMicTap: () -> Void
    let onRemoveImage: (ImageContent) -> Void
    var inputHistory: InputHistoryStore?
    var onHistoryNavigate: ((String) -> Void)?

    // Status bar info
    var modelName: String = ""
    var tokenUsage: TokenUsage?
    var contextPercentage: Int = 0
    var contextWindow: Int = 0  // From server via ChatViewModel.currentContextWindow

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
    @State private var showingImagePicker = false
    @State private var isMicPulsing = false
    @State private var showMicButton = false
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

    private let actionButtonSize: CGFloat = 40
    private let micDockInset: CGFloat = 18

    var body: some View {
        VStack(spacing: 10) {
            // Attached images preview
            if !attachedImages.isEmpty {
                attachedImagesRow
            }

            // Status pills row - floating liquid glass elements
            if shouldShowStatusPills {
                statusPillsRow
                    .padding(.horizontal, 16)
                    .transition(.opacity)
            }

            // Input row - floating liquid glass elements
            HStack(alignment: .bottom, spacing: 12) {
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
            .overlay(alignment: .topTrailing) {
                if shouldShowTokenPillDock {
                    tokenStatsPillDock
                }
            }
            .animation(.tronStandard, value: shouldShowActionButton)
            .animation(micButtonAnimation, value: shouldShowMicButton)
        }
        // iOS 26: No background - elements float with glass effects only
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
    }

    // MARK: - Status Pills Row (iOS 26 Liquid Glass)

    private var statusPillsRow: some View {
        HStack {
            // Model picker menu - popup style (replaces old button)
            if !modelName.isEmpty && showModelPill {
                ModelPickerMenu(
                    currentModel: modelName,
                    models: cachedModels,
                    isLoading: isLoadingModels,
                    onSelect: { model in
                        onModelSelect?(model)
                    }
                )
                .matchedGeometryEffect(id: "modelPillMorph", in: modelPillNamespace)
            }

            // Reasoning level picker (for OpenAI Codex models)
            // Animates out from model pill with a delay
            if let model = currentModelInfo, model.supportsReasoning == true, showReasoningPill {
                ReasoningLevelPicker(
                    model: model,
                    selectedLevel: Binding(
                        get: { reasoningLevel },
                        set: { newLevel in
                            onReasoningLevelChange?(newLevel)
                        }
                    )
                )
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
        let used = (tokenUsage?.inputTokens ?? 0) + (tokenUsage?.outputTokens ?? 0)
        return max(0, contextWindow - used)
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

    // MARK: - Attached Images Row

    private var attachedImagesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachedImages) { image in
                    AttachedImageThumbnail(
                        image: image,
                        onRemove: { onRemoveImage(image) }
                    )
                }
            }
            .padding(.horizontal)
        }
        .frame(height: 70)
    }

    // MARK: - Attachment Menu

    private var attachmentMenu: some View {
        Menu {
            PhotosPicker(
                selection: $selectedImages,
                maxSelectionCount: 5,
                matching: .images
            ) {
                Label("Photo Library", systemImage: TronIcon.photo.systemName)
            }

            Button {
                // Camera would go here - requires additional permissions
            } label: {
                Label("Camera", systemImage: TronIcon.camera.systemName)
            }
            .disabled(true) // Camera not implemented yet
        } label: {
            TronIconView(icon: .attach, size: 22, color: .tronTextSecondary)
                .frame(width: 36, height: 36)
        }
        .disabled(isProcessing)
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
                    Image(systemName: "mic.fill")
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
        if isTranscribing {
            return true
        }
        if isRecording {
            return false
        }
        return isProcessing
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedImages.isEmpty
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

    private func resetIntroState() {
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

            try? await Task.sleep(nanoseconds: 200_000_000)
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

// MARK: - Attached Image Thumbnail

struct AttachedImageThumbnail: View {
    let image: ImageContent
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let uiImage = UIImage(data: image.data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.tronSurfaceElevated)
                    .frame(width: 56, height: 56)
                    .overlay {
                        TronIconView(icon: .photo, size: 20, color: .tronTextMuted)
                    }
            }

            // Remove button
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .offset(x: 4, y: -4)
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
            attachedImages: .constant([]),
            selectedImages: .constant([]),
            onSend: {},
            onAbort: {},
            onMicTap: {},
            onRemoveImage: { _ in },
            inputHistory: nil,
            onHistoryNavigate: nil,
            modelName: "claude-sonnet-4-5-20260105",
            tokenUsage: TokenUsage(inputTokens: 50000, outputTokens: 10000, cacheReadTokens: nil, cacheCreationTokens: nil),
            contextPercentage: 30,
            contextWindow: 200_000,
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
