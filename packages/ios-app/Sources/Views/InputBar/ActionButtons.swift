import SwiftUI
import PhotosUI

// MARK: - Glass Action Button (Send/Abort)

@available(iOS 26.0, *)
struct GlassActionButton: View {
    let isProcessing: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onAbort: () -> Void
    let namespace: Namespace.ID
    let buttonSize: CGFloat

    var body: some View {
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
            .frame(width: buttonSize, height: buttonSize)
            .contentShape(Circle())
        }
        .matchedGeometryEffect(id: "actionButtonMorph", in: namespace)
        .glassEffect(
            .regular.tint(canSend && !isProcessing ? Color.tronEmeraldDark : Color.tronPhthaloGreen.opacity(0.35)).interactive(),
            in: .circle
        )
        .disabled(!isProcessing && !canSend)
        .animation(.easeInOut(duration: 0.2), value: isProcessing)
        .animation(.easeInOut(duration: 0.2), value: canSend)
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
    @ObservedObject var audioMonitor: AudioAvailabilityMonitor

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
            return false
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
        return Color.tronPhthaloGreen.opacity(0.35)
    }

    var body: some View {
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

// MARK: - Glass Attachment Button

@available(iOS 26.0, *)
struct GlassAttachmentButton: View {
    let isProcessing: Bool
    let hasSkillsAvailable: Bool
    let buttonSize: CGFloat
    let skillStore: SkillStore?

    // Sheet bindings passed from parent
    @Binding var showCamera: Bool
    @Binding var showingImagePicker: Bool
    @Binding var showFilePicker: Bool
    @Binding var showSkillMentionPopup: Bool
    @Binding var skillMentionQuery: String

    var body: some View {
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

                Button { NotificationCenter.default.post(name: .attachmentMenuAction, object: "draftPlan") } label: {
                    Label("Draft a Plan", systemImage: "list.clipboard")
                }
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isProcessing ? Color.tronEmerald.opacity(0.3) : Color.tronEmerald)
                    .frame(width: buttonSize, height: buttonSize)
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
            case "draftPlan":
                // Post notification for ChatView to handle plan skill selection
                NotificationCenter.default.post(name: .draftPlanRequested, object: nil)
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

// MARK: - Legacy Action Button (Non-Glass)

struct LegacyActionButton: View {
    let isProcessing: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onAbort: () -> Void

    var body: some View {
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
}
