import SwiftUI
import PhotosUI

// MARK: - Glass Action Button (Send/Abort)

@available(iOS 26.0, *)
struct GlassActionButton: View {
    /// Show stop icon (red) when true, send arrow when false.
    let showStop: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onAbort: () -> Void
    let namespace: Namespace.ID
    let buttonSize: CGFloat

    var body: some View {
        Button {
            if showStop {
                onAbort()
            } else {
                onSend()
            }
        } label: {
            Group {
                if showStop {
                    Image(systemName: "stop.fill")
                        .font(TronTypography.button)
                        .foregroundStyle(.red)
                } else {
                    Image(systemName: "arrow.up")
                        .font(TronTypography.button)
                        .foregroundStyle(canSend ? .white : .tronTextDisabled)
                }
            }
            .frame(width: buttonSize, height: buttonSize)
            .contentShape(Circle())
        }
        .matchedGeometryEffect(id: "actionButtonMorph", in: namespace)
        .glassEffect(
            .regular.tint(canSend && !showStop ? Color.tronEmerald.opacity(0.65) : Color.tronPhthaloGreen.opacity(0.25)).interactive(),
            in: .circle
        )
        .disabled(!showStop && !canSend)
        .animation(.easeInOut(duration: 0.2), value: showStop)
        .animation(.easeInOut(duration: 0.2), value: canSend)
        .accessibilityLabel(showStop ? "Stop agent" : "Send message")
    }
}

// MARK: - Action Button Dock (Morph Origin)

struct ActionButtonDock: View {
    let namespace: Namespace.ID
    let buttonSize: CGFloat

    var body: some View {
        Circle()
            .fill(Color.clear)
            .frame(width: buttonSize, height: buttonSize)
            .matchedGeometryEffect(id: "actionButtonMorph", in: namespace)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Glass Mic Button

@available(iOS 26.0, *)
struct GlassMicButton: View {
    let isRecording: Bool
    let isTranscribing: Bool
    let isProcessing: Bool
    let onMicTap: () -> Void
    let buttonSize: CGFloat
    let audioMonitor: AudioAvailabilityMonitor

    @Environment(\.interactionPolicy) private var interactionPolicy

    @State private var isMicPulsing = false

    private var isMicDisabled: Bool {
        // Disable if audio recording is unavailable (phone call, etc.)
        if !audioMonitor.isRecordingAvailable {
            return true
        }
        if isTranscribing {
            return true
        }
        if isRecording {
            // Allow tapping to stop/commit a recording that's already in flight, even if
            // the connection dropped mid-recording.
            return false
        }
        // New-recording block: server transcription requires an active connection.
        if !(interactionPolicy?.canRecordAudio ?? false) {
            return true
        }
        return isProcessing
    }

    private var shouldPulseMicTint: Bool {
        isRecording && !isTranscribing
    }

    private var micGlassTint: Color {
        if shouldPulseMicTint {
            return Color.red.opacity(isMicPulsing ? 0.45 : 0.25)
        }
        return Color.tronPhthaloGreen.opacity(0.25)
    }

    var body: some View {
        Button {
            onMicTap()
        } label: {
            Group {
                if isTranscribing {
                    ProgressView()
                        .tint(.tronEmerald)
                        .scaleEffect(0.8)
                } else if isRecording {
                    Image(systemName: "stop.fill")
                        .font(TronTypography.buttonSM)
                        .foregroundStyle(.red)
                } else {
                    Image(systemName: audioMonitor.isRecordingAvailable ? "mic.fill" : "mic.slash.fill")
                        .font(TronTypography.buttonSM)
                        .foregroundStyle(isMicDisabled ? Color.tronEmerald.opacity(0.3) : Color.tronEmerald)
                }
            }
            .frame(width: buttonSize, height: buttonSize)
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
        .accessibilityLabel(isRecording ? "Stop recording" : isTranscribing ? "Transcribing" : "Record audio")
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
}

// MARK: - Mic Button Dock (Morph Origin)

struct MicButtonDock: View {
    let buttonSize: CGFloat

    var body: some View {
        Circle()
            .fill(Color.clear)
            .frame(width: buttonSize, height: buttonSize)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Glass Circle Button Style (iOS 26.1 Menu fix)

/// Custom ButtonStyle that applies glassEffect internally - fixes Menu morphing animation glitch
/// See: https://juniperphoton.substack.com/p/adopting-liquid-glass-experiences
@available(iOS 26.0, *)
struct GlassCircleButtonStyle: ButtonStyle {
    let size: CGFloat
    let tint: Color
    let isDisabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        // Use explicit Circle as base to ensure correct bounds during Menu transitions
        Circle()
            .fill(.clear)
            .frame(width: size, height: size)
            .overlay {
                configuration.label
            }
            .glassEffect(.regular.tint(tint).interactive(), in: .circle)
            .opacity(isDisabled ? 0.5 : 1.0)
    }
}

// MARK: - Glass Attachment Button

@available(iOS 26.0, *)
struct GlassAttachmentButton: View {
    let isProcessing: Bool
    let buttonSize: CGFloat
    let attachmentCapability: AttachmentCapability

    // Sheet bindings passed from parent
    @Binding var showCamera: Bool
    @Binding var showingImagePicker: Bool
    @Binding var showFilePicker: Bool

    // Keyboard observer to prevent Menu opening during keyboard animation
    private let keyboardObserver = KeyboardObserver.shared

    /// Disable Menu during keyboard animation to prevent mispositioned popups
    private var isMenuDisabled: Bool {
        isProcessing || keyboardObserver.isAnimating
    }

    var body: some View {
        // Separate visual (glass button) from interaction (invisible Menu overlay)
        // This avoids the iOS 26 Menu + glassEffect transition bug
        Image(systemName: "plus")
            .font(TronTypography.buttonSM)
            .foregroundStyle(isMenuDisabled ? Color.tronEmerald.opacity(0.3) : Color.tronEmerald)
            .frame(width: buttonSize, height: buttonSize)
            .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.25)).interactive(), in: .circle)
            .opacity(isMenuDisabled ? 0.5 : 1.0)
            .accessibilityLabel("Add attachment")
            .overlay {
                // Invisible Menu overlay handles interaction only
                Menu {
                    if attachmentCapability.supportsImages {
                        Button { NotificationCenter.default.post(name: .attachmentMenuAction, object: "camera") } label: {
                            Label("Take Photo", systemImage: "camera")
                        }

                        Button { NotificationCenter.default.post(name: .attachmentMenuAction, object: "photos") } label: {
                            Label("Photo Library", systemImage: "photo.on.rectangle")
                        }
                    }

                    Button { NotificationCenter.default.post(name: .attachmentMenuAction, object: "files") } label: {
                        Label("Choose File", systemImage: "folder")
                    }

                } label: {
                    Color.clear
                        .frame(width: buttonSize, height: buttonSize)
                        .contentShape(Circle())
                }
                .disabled(isMenuDisabled)
            }
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
}

// MARK: - Attachment Button Dock (Morph Origin)

struct AttachmentButtonDock: View {
    let buttonSize: CGFloat

    var body: some View {
        Circle()
            .fill(Color.clear)
            .frame(width: buttonSize, height: buttonSize)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
