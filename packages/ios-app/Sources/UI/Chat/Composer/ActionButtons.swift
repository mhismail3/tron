import SwiftUI

// MARK: - Attachment Menu

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
            return "Take Photo"
        case .photoLibrary:
            return "Select Photos"
        case .files:
            return "Attach Files"
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

struct ComposerAttachmentButton: View {
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
                        .contentShape(Rectangle())
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

// MARK: - Trailing Composer Action

struct ComposerTrailingButton: View {
    let showStop: Bool
    let canSend: Bool
    let isRecording: Bool
    let isTranscribing: Bool
    let micDisabled: Bool
    let onSend: () -> Void
    let onAbort: () -> Void
    let onMicTap: () -> Void
    let buttonSize: CGFloat

    private var isDisabled: Bool {
        !showStop && !canSend && micDisabled && !isRecording
    }

    private var accessibilityLabel: String {
        if showStop { return "Stop agent" }
        if canSend { return "Send message" }
        if isRecording { return "Stop recording" }
        if isTranscribing { return "Transcribing" }
        return "Record voice input"
    }

    private var accessibilityHint: String {
        if isDisabled {
            return "Voice input is unavailable while the agent is active or disconnected."
        }
        return ""
    }

    var body: some View {
        Button(action: performAction) {
            Group {
                if showStop {
                    Image(systemName: "stop.fill")
                        .font(TronTypography.buttonSM)
                        .foregroundStyle(.red)
                } else if canSend {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(TronTypography.button)
                        .foregroundStyle(.tronEmerald)
                } else if isTranscribing {
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .contentTransition(.symbolEffect(.replace))
        .animation(.easeInOut(duration: 0.2), value: showStop)
        .animation(.easeInOut(duration: 0.2), value: canSend)
        .animation(.easeInOut(duration: 0.2), value: isRecording)
        .animation(.easeInOut(duration: 0.2), value: isTranscribing)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    private func performAction() {
        if showStop {
            onAbort()
        } else if canSend {
            onSend()
        } else {
            onMicTap()
        }
    }

}
