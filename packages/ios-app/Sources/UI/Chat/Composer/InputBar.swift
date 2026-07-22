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
    @State private var showRecentInputs = false

    private let actionButtonSize: CGFloat = 40

    // MARK: - Computed Properties

    private var canSend: Bool {
        config.canSend(hasContent: state.hasContent)
    }

    /// Show stop button while the agent is active.
    private var showStop: Bool {
        config.agentPhase.isActive
    }

    private var shouldShowRecentInputsMenuAction: Bool {
        RecentInputHistoryPresentation.shouldShowMenuAction(
            inputHistory: config.inputHistory,
            agentPhase: config.agentPhase,
            readOnly: config.readOnly
        )
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 10) {
            if !state.attachments.isEmpty {
                attachmentArea
                    .padding(.horizontal, 16)
                    .transition(.opacity)
            }

            // One composer surface owns the attachment action, text, context
            // briefing progress, and trailing state action.
            HStack(alignment: .bottom, spacing: 4) {
                if !config.readOnly {
                    // Reserve the attachment action's layout inside the glass.
                    // The native Menu itself is overlaid after the material so
                    // rebuilding its label cannot replace the glass owner.
                    Color.clear
                        .frame(width: actionButtonSize, height: actionButtonSize)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                inputField

                if let onContextTap = actions.onContextTap {
                    ContextProgressButton(
                        contextPercentage: config.contextPercentage,
                        modelName: config.currentModelInfo?.formattedModelName,
                        isCompacting: config.isCompacting,
                        onTap: onContextTap
                    )
                }

                if !config.readOnly {
                    ComposerTrailingButton(
                        showStop: showStop,
                        canSend: canSend,
                        onSend: actions.onSend,
                        onAbort: actions.onAbort,
                        buttonSize: actionButtonSize
                    )
                    .help(config.sendBlockReason?.description ?? "")
                }
            }
            .frame(minHeight: actionButtonSize)
            .padding(.horizontal, 4)
            .glassEffect(
                .regular
                    .tint(Color.tronPhthaloGreen.opacity(0.25))
                    .interactive(!config.readOnly),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .overlay(alignment: .bottomLeading) {
                if !config.readOnly {
                    ComposerAttachmentButton(
                        isDisabled: config.agentPhase.isActive || config.readOnly,
                        attachmentSupport: config.attachmentSupport,
                        includeRecentInputs: shouldShowRecentInputsMenuAction,
                        onSelect: presentAttachmentAction,
                        buttonSize: actionButtonSize
                    )
                    .padding(.leading, 4)
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
                tool: config.attachmentSupport,
                onDocumentPicked: addDocumentAttachment,
                onSizeExceeded: handleDocumentSizeExceeded
            )
        }
        .sheet(isPresented: $showRecentInputs) {
            if let inputHistory = config.inputHistory {
                RecentInputHistorySheet(historyStore: inputHistory) { selected in
                    actions.onHistoryNavigate?(selected)
                }
            }
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
    }

    // MARK: - Attachment Area

    @ViewBuilder
    private var attachmentArea: some View {
        ContentAreaView(
            attachments: state.attachments,
            attachmentSupport: config.attachmentSupport,
            onRemoveAttachment: actions.onRemoveAttachment
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Text Field

    private var inputField: some View {
        ZStack(alignment: .leading) {
            if state.text.isEmpty && !isFocused {
                HStack(spacing: 7) {
                    if config.placeholderShowsProgress {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.tronEmerald.opacity(0.62))
                            .frame(width: 14, height: 14)
                            .accessibilityHidden(true)
                    }

                    Text(config.placeholderText)
                        .font(TronTypography.input)
                        .foregroundStyle(.tronEmerald.opacity(0.5))
                        .contentTransition(.opacity)
                }
                .padding(.leading, 2)
                .padding(.vertical, 10)
                .id("\(config.placeholderText)-\(config.placeholderShowsProgress)")
                .accessibilityIdentifier("message-input-placeholder")
            }

            TextField("", text: $state.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(TronTypography.input)
                .foregroundStyle(config.readOnly ? .tronEmerald.opacity(0.5) : .tronEmerald)
                .padding(.horizontal, 2)
                .padding(.vertical, 10)
                .lineLimit(1...8)
                .focused($isFocused)
                .disabled(config.readOnly)
                .accessibilityLabel("Message input")
                .onSubmit {
                    guard canSend else { return }
                    actions.onSend()
                }
                .onKeyPress(.tab) {
                    resignInputFocusForKeyboardTraversal()
                }
        }
        .frame(minHeight: actionButtonSize)
        .animation(.easeOut(duration: 0.18), value: config.placeholderText)
        .animation(.easeOut(duration: 0.18), value: config.placeholderShowsProgress)
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
        case .recentInputs:
            isFocused = false
            showRecentInputs = true
        }
    }

    private func addCameraImageAttachment(_ capturedImage: UIImage) {
        Task {
            let jpegData = capturedImage.jpegData(compressionQuality: 1.0) ?? Data()
            guard let attachment = await AttachmentImagePreparer.prepare(
                data: jpegData,
                declaredMimeType: "image/jpeg",
                limits: config.providerImageLimits
            ) else {
                await MainActor.run {
                    actions.onAttachmentError("Could not attach photo", "The captured photo could not be processed.")
                }
                return
            }
            await MainActor.run {
                actions.onAddAttachment(attachment)
            }
        }
    }

    private func addDocumentAttachment(data: Data, mimeType: String, fileName: String?) {
        if mimeType.hasPrefix("image/") {
            Task {
                guard let attachment = await AttachmentImagePreparer.prepare(
                    data: data,
                    declaredMimeType: mimeType,
                    fileName: fileName,
                    limits: config.providerImageLimits
                ) else {
                    await MainActor.run {
                        actions.onAttachmentError("Could not attach image", "The selected image could not be processed.")
                    }
                    return
                }
                await MainActor.run {
                    actions.onAddAttachment(attachment)
                }
            }
        } else {
            let attachment = Attachment(
                type: AttachmentType.from(mimeType: mimeType),
                data: data,
                mimeType: mimeType,
                fileName: fileName
            )
            actions.onAddAttachment(attachment)
        }
    }

    private func handleDocumentSizeExceeded(actualSize: Int, maxSize: Int) {
        let actualMB = actualSize / (1024 * 1024)
        let maxMB = maxSize / (1024 * 1024)
        logger.warning("File too large: \(actualMB)MB exceeds \(maxMB)MB limit", category: .chat)
        actions.onAttachmentError("File is too large", "\(actualMB)MB exceeds the \(maxMB)MB limit.")
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
                contextPercentage: 42,
                currentModelInfo: nil,
                inputHistory: nil,
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
