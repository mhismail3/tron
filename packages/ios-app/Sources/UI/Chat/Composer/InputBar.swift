import SwiftUI
import PhotosUI

// ARCHITECTURE: coordinates keyboard handling, attachment picking, and send
// flow for the primitive prompt composer.

// MARK: - Input Bar (iOS 26 Liquid Glass)

struct InputBar: View {
    // MARK: - Consolidated Input (State/Config/Actions pattern)

    /// Mutable input state (text, attachments, etc.)
    @Bindable var state: InputBarState

    /// Read-only configuration (processing state, model info, etc.)
    let config: InputBarConfig

    /// Action callbacks (send, abort, attachment, etc.)
    let actions: InputBarActions

    // MARK: - Private State

    @FocusState private var isFocused: Bool
    @State private var showCamera = false
    @State private var showFilePicker = false
    @State private var showingImagePicker = false
    @State private var hasAppeared = false
    @State private var showAttachmentButton = false

    // Namespaces for morph animations
    @Namespace private var actionButtonNamespace
    @Namespace private var attachmentButtonNamespace

    private let actionButtonSize: CGFloat = 40

    // MARK: - Computed Properties

    private var canSend: Bool {
        guard config.agentPhase.isIdle else { return false }
        return state.hasContent && config.sendBlockReason == nil
    }

    /// Show stop button while the agent is active.
    private var showStop: Bool {
        config.agentPhase.isActive
    }

    private var shouldShowActionButton: Bool {
        if config.agentPhase.isActive {
            return true
        }
        return canSend
    }

    private var shouldShowStatusPills: Bool { true }

    private var micDisabled: Bool {
        if config.isRecording { return false }
        return config.readOnly || config.agentPhase.isActive || config.isTranscribing || !config.isConnected
    }

    private var textFieldTrailingPadding: CGFloat {
        let basePadding: CGFloat = 14
        var totalPadding = basePadding
        if !shouldShowActionButton {
            totalPadding += actionButtonSize + 8
        }
        return totalPadding
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 10) {
            // Content area: attachments and status pills
            contentArea
                .padding(.horizontal, 16)
                .transition(.opacity)

            // Input row - floating liquid glass elements
            HStack(alignment: .bottom, spacing: 12) {
                // Attachment button
                if showAttachmentButton {
                    GlassAttachmentButton(
                        isDisabled: config.agentPhase.isActive || config.readOnly,
                        attachmentCapability: config.attachmentCapability,
                        onSelect: presentAttachmentAction,
                        buttonSize: actionButtonSize
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
                    // Explain the disabled state. Visible on long-press
                    // / hover via `.help()`; always read by VoiceOver via
                    // `.accessibilityHint()`.
                    .help(config.sendBlockReason?.description ?? "")
                    .accessibilityHint(config.sendBlockReason?.description ?? "")
                }

                if !config.readOnly {
                    GlassMicButton(
                        isRecording: config.isRecording,
                        isTranscribing: config.isTranscribing,
                        isDisabled: micDisabled,
                        onMicTap: {
                            isFocused = false
                            actions.onMicTap()
                        },
                        buttonSize: actionButtonSize
                    )
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
            .animation(.tronStandard, value: shouldShowActionButton)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        // Focus management — no blockFocusUntil; user can tap to refocus after the turn.
        .animation(nil, value: isFocused)
        .sheet(isPresented: $showCamera) {
            CameraCaptureSheet(onImageCaptured: addCameraImageAttachment)
        }
        .sheet(isPresented: $showFilePicker) {
            DocumentPicker(
                capability: config.attachmentCapability,
                onDocumentPicked: addDocumentAttachment,
                onSizeExceeded: handleDocumentSizeExceeded
            )
        }
        .photosPicker(
            isPresented: $showingImagePicker,
            selection: $state.selectedImages,
            maxSelectionCount: 5,
            matching: .images
        )
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
        // Entrance animation — staggered morph-ins for attachment/status.
        // All timings/springs live in TronAnimationTiming so the
        // cumulative timeline can be tweaked in one place.
        .onAppear {
            showAttachmentButton = false
            hasAppeared = false

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: TronAnimationTiming.inputBarAttachmentDelayNanos)
                withAnimation(TronAnimationTiming.inputBarButtonSpring) {
                    showAttachmentButton = true
                }
                try? await Task.sleep(nanoseconds: TronAnimationTiming.inputBarFinalDelayNanos)
                withAnimation(TronAnimationTiming.inputBarFinalSpring) {
                    hasAppeared = true
                }
            }
        }
        .onDisappear {
            showAttachmentButton = false
            hasAppeared = false
        }
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        HStack(alignment: .bottom, spacing: 12) {
            if !state.attachments.isEmpty {
                ContentAreaView(
                    attachments: state.attachments,
                    attachmentCapability: config.attachmentCapability,
                    onRemoveAttachment: actions.onRemoveAttachment
                )
            }

            Spacer(minLength: 0)

            ContextStatusPill(
                contextPercentage: config.contextPercentage,
                modelName: config.currentModelInfo?.name,
                hasAppeared: hasAppeared,
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
                .onKeyPress(.tab) {
                    resignInputFocusForKeyboardTraversal()
                }
        }
        .frame(minHeight: actionButtonSize)
        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.25)).interactive(), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(.tronStandard, value: shouldShowActionButton)
    }

    private func resignInputFocusForKeyboardTraversal() -> KeyPress.Result {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            return .ignored
        }

        isFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        return .handled
    }

    private func presentAttachmentAction(_ action: AttachmentMenuAction) {
        switch action {
        case .camera:
            showCamera = true
        case .photoLibrary:
            showingImagePicker = true
        case .files:
            showFilePicker = true
        }
    }

    private func addCameraImageAttachment(_ capturedImage: UIImage) {
        Task {
            // Camera always produces JPEG.
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

    private func addDocumentAttachment(url: URL, mimeType: String, fileName: String?) {
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

    private func handleDocumentSizeExceeded(actualSize: Int, maxSize: Int) {
        let actualMB = actualSize / (1024 * 1024)
        let maxMB = maxSize / (1024 * 1024)
        logger.warning("File too large: \(actualMB)MB exceeds \(maxMB)MB limit", category: .chat)
    }

}

// MARK: - iOS 26 Menu Action Notifications

extension Notification.Name {
    /// iOS 26 Menu bug: State mutations in button actions break gesture handling
    static let attachmentMenuAction = Notification.Name("attachmentMenuAction")
    static let modelPickerAction = Notification.Name("modelPickerAction")
    static let reasoningLevelAction = Notification.Name("reasoningLevelAction")
}

// MARK: - Preview

#if DEBUG
#Preview {
    @Previewable @State var previewState = InputBarState()

    VStack {
        Spacer()
        InputBar(
            state: previewState,
            config: InputBarConfig(
                tokenUsage: TokenUsage(inputTokens: 50000, outputTokens: 10000, cacheReadTokens: nil, cacheCreationTokens: nil),
                contextPercentage: 30,
                contextWindow: 200_000,
                lastTurnInputTokens: 60000,
                currentModelInfo: nil,
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
