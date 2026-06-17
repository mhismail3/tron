import SwiftUI
import PhotosUI

// MARK: - Glass Action Button (Send/Abort)

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

// MARK: - Glass Circle Button Style (iOS 26.1 Menu fix)

/// Custom ButtonStyle that applies glassEffect internally - fixes Menu morphing animation glitch
/// See: https://juniperphoton.substack.com/p/adopting-liquid-glass-experiences
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

enum AttachmentMenuAction: String, CaseIterable, Identifiable, Equatable {
    case camera
    case photoLibrary
    case files
    case recentInputs

    var id: String { rawValue }

    static func availableActions(
        for capability: AttachmentCapability,
        includeRecentInputs: Bool = false
    ) -> [AttachmentMenuAction] {
        var actions: [AttachmentMenuAction] = []
        if capability.supportsImages {
            actions += [.camera, .photoLibrary]
        }
        actions.append(.files)
        if includeRecentInputs {
            actions.append(.recentInputs)
        }
        return actions
    }

    var title: String {
        switch self {
        case .camera:
            return "Camera"
        case .photoLibrary:
            return "Photos"
        case .files:
            return "Files"
        case .recentInputs:
            return RecentInputHistoryPresentation.title
        }
    }

    var systemImage: String {
        switch self {
        case .camera:
            return "camera"
        case .photoLibrary:
            return "photo.on.rectangle"
        case .files:
            return "folder"
        case .recentInputs:
            return "clock.arrow.circlepath"
        }
    }
}

struct GlassAttachmentButton: View {
    let isDisabled: Bool
    let attachmentCapability: AttachmentCapability
    let includeRecentInputs: Bool
    let onSelect: (AttachmentMenuAction) -> Void
    let buttonSize: CGFloat

    private var menuDisabled: Bool {
        isDisabled || KeyboardObserver.shared.isAnimating
    }

    var body: some View {
        Image(systemName: "plus")
            .font(TronTypography.buttonSM)
            .foregroundStyle(menuDisabled ? Color.tronEmerald.opacity(0.3) : Color.tronEmerald)
            .frame(width: buttonSize, height: buttonSize)
            .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.25)).interactive(), in: .circle)
            .opacity(menuDisabled ? 0.5 : 1.0)
            .overlay {
                Menu {
                    ForEach(AttachmentMenuAction.availableActions(
                        for: attachmentCapability,
                        includeRecentInputs: includeRecentInputs
                    )) { action in
                        Button {
                            NotificationCenter.default.post(name: .attachmentMenuAction, object: action)
                        } label: {
                            Label(action.title, systemImage: action.systemImage)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                } label: {
                    Color.clear
                        .frame(width: buttonSize, height: buttonSize)
                        .contentShape(Circle())
                }
                .controlSize(.small)
                .disabled(menuDisabled)
            }
            .onReceive(NotificationCenter.default.publisher(for: .attachmentMenuAction)) { notification in
                guard let action = notification.object as? AttachmentMenuAction else { return }
                onSelect(action)
            }
            .accessibilityLabel("Add attachment")
            .accessibilityHint(menuDisabled ? "Attachments are unavailable while the agent is active." : "")
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

// MARK: - Glass Mic Button

struct GlassMicButton: View {
    let isRecording: Bool
    let isTranscribing: Bool
    let isDisabled: Bool
    let onMicTap: () -> Void
    let buttonSize: CGFloat

    @State private var isPulsing = false

    private var glassTint: Color {
        if isRecording {
            return Color.red.opacity(isPulsing ? 0.45 : 0.25)
        }
        return Color.tronPhthaloGreen.opacity(0.25)
    }

    var body: some View {
        Button(action: onMicTap) {
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
                    Image(systemName: "mic.fill")
                        .font(TronTypography.buttonSM)
                        .foregroundStyle(isDisabled ? Color.tronEmerald.opacity(0.3) : Color.tronEmerald)
                }
            }
            .frame(width: buttonSize, height: buttonSize)
            .contentShape(Circle())
        }
        .glassEffect(.regular.tint(glassTint).interactive(), in: .circle)
        .disabled(isDisabled && !isRecording)
        .animation(.easeInOut(duration: 0.2), value: isRecording)
        .animation(.easeInOut(duration: 0.2), value: isTranscribing)
        .onAppear { updatePulse() }
        .onChange(of: isRecording) { _, _ in updatePulse() }
        .accessibilityLabel(isRecording ? "Stop recording" : isTranscribing ? "Transcribing" : "Record voice input")
        .accessibilityHint(isDisabled ? "Voice input is unavailable while the agent is active or disconnected." : "")
    }

    private func updatePulse() {
        guard isRecording else {
            isPulsing = false
            return
        }
        isPulsing = false
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
            isPulsing = true
        }
    }
}
