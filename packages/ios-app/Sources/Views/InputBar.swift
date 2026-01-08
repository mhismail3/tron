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

    // Model picker integration
    var cachedModels: [ModelInfo] = []
    var isLoadingModels: Bool = false
    var onModelSelect: ((ModelInfo) -> Void)?

    /// Binding to control focus (used to prevent keyboard after response)
    @Binding var shouldFocus: Bool

    @FocusState private var isFocused: Bool
    @State private var showingImagePicker = false
    @State private var isMicPulsing = false

    var body: some View {
        VStack(spacing: 10) {
            // Attached images preview
            if !attachedImages.isEmpty {
                attachedImagesRow
            }

            // Status pills row - floating liquid glass elements
            if !modelName.isEmpty || tokenUsage != nil {
                statusPillsRow
                    .padding(.horizontal, 16)
            }

            // Input row - floating liquid glass elements
            HStack(alignment: .bottom, spacing: 12) {
                // Text field with glass background
                textFieldGlass

                // Mic button - liquid glass
                micButtonGlass

                // Send/Abort button - liquid glass
                actionButtonGlass
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        // iOS 26: No background - elements float with glass effects only
        // Sync focus state with parent control
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
    }

    // MARK: - Status Pills Row (iOS 26 Liquid Glass)

    private var statusPillsRow: some View {
        HStack {
            // Model picker menu - popup style (replaces old button)
            if !modelName.isEmpty {
                ModelPickerMenu(
                    currentModel: modelName,
                    models: cachedModels,
                    isLoading: isLoadingModels,
                    onSelect: { model in
                        onModelSelect?(model)
                    }
                )
            }

            Spacer()

            // Token stats pill with liquid glass
            if tokenUsage != nil || contextPercentage > 0 {
                HStack(spacing: 8) {
                    // Input tokens
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 8))
                        Text(tokenUsage?.formattedInput ?? "0")
                    }

                    // Output tokens
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 8))
                        Text(tokenUsage?.formattedOutput ?? "0")
                    }

                    // Context percentage
                    Text("\(contextPercentage)%")
                        .foregroundStyle(contextPercentageColor)
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.4)), in: .capsule)
            }
        }
    }

    private var contextPercentageColor: Color {
        if contextPercentage >= 95 {
            return .red
        } else if contextPercentage >= 80 {
            return .orange
        }
        return .primary.opacity(0.6)
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
            .padding(.horizontal, 14)
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
        .glassEffect(
            .regular.tint(canSend && !isProcessing ? Color.tronEmerald : Color.tronPhthaloGreen.opacity(0.3)).interactive(),
            in: .circle
        )
        .disabled(!isProcessing && !canSend)
        .animation(.easeInOut(duration: 0.2), value: isProcessing)
        .animation(.easeInOut(duration: 0.2), value: canSend)
    }

    // MARK: - Mic Button

    private var micButtonGlass: some View {
        ZStack {
            if isRecording && !isTranscribing {
                Circle()
                    .stroke(Color.red.opacity(0.45), lineWidth: 1.5)
                    .scaleEffect(isMicPulsing ? 1.6 : 1.0)
                    .opacity(isMicPulsing ? 0.0 : 0.55)
                    .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: isMicPulsing)
            }

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
                            .foregroundStyle(isMicDisabled ? .white.opacity(0.3) : .white)
                    }
                }
                .frame(width: 40, height: 40)
                .contentShape(Circle())
            }
            .glassEffect(
                .regular.tint(isRecording ? Color.red.opacity(0.35) : Color.tronPhthaloGreen.opacity(0.3)).interactive(),
                in: .circle
            )
            .disabled(isMicDisabled)
            .animation(.easeInOut(duration: 0.2), value: isRecording)
            .animation(.easeInOut(duration: 0.2), value: isTranscribing)
        }
        .onAppear {
            isMicPulsing = isRecording
        }
        .onChange(of: isRecording) { _, newValue in
            isMicPulsing = newValue
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
            cachedModels: [],
            isLoadingModels: false,
            onModelSelect: nil,
            shouldFocus: .constant(false)
        )
    }
    .preferredColorScheme(.dark)
}
