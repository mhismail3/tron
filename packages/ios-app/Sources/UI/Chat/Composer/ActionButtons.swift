import SwiftUI

// MARK: - Attachment Menu

enum AttachmentMenuAction: String, CaseIterable, Identifiable, Equatable {
    case camera
    case photoLibrary
    case files
    case recentInputs

    var id: String { rawValue }

    static func availableActions(
        for tool: AttachmentSupport,
        includeRecentInputs: Bool = false
    ) -> [AttachmentMenuAction] {
        var actions: [AttachmentMenuAction] = []
        if tool.supportsImages {
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
    var disabledReason: String? = nil
    let attachmentSupport: AttachmentSupport
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
            .contentShape(Circle())
            .opacity(menuDisabled ? 0.5 : 1.0)
            .overlay {
                Menu {
                    ForEach(AttachmentMenuAction.availableActions(
                        for: attachmentSupport,
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
        .accessibilityHint(
            menuDisabled
                ? (disabledReason ?? "Attachments are unavailable while the agent is active.")
                : ""
        )
    }
}

// MARK: - Trailing Composer Action

enum ComposerTrailingMode: Equatable {
    case stopAgent
    case stopRecording
    case transcribing
    case send
    case record

    init(
        showStop: Bool,
        hasContent: Bool,
        canRecord: Bool,
        isRecording: Bool,
        isTranscribing: Bool
    ) {
        if showStop {
            self = .stopAgent
        } else if isRecording {
            self = .stopRecording
        } else if isTranscribing {
            self = .transcribing
        } else if hasContent || !canRecord {
            self = .send
        } else {
            self = .record
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .stopAgent: return "Stop agent"
        case .stopRecording: return "Stop recording"
        case .transcribing: return "Transcribing"
        case .send: return "Send message"
        case .record: return "Record voice input"
        }
    }

    func accessibilityHint(micDisabled: Bool, blockedReason: String? = nil) -> String {
        switch self {
        case .transcribing:
            return "Wait for transcription to finish."
        case .record where micDisabled:
            return blockedReason
                ?? "Voice input is unavailable while the agent is active or disconnected."
        case .send:
            return blockedReason ?? ""
        case .stopAgent, .stopRecording, .record:
            return ""
        }
    }
}

struct ComposerTrailingButton: View {
    let mode: ComposerTrailingMode
    let canSend: Bool
    let micDisabled: Bool
    var blockedReason: String? = nil
    let onSend: () -> Void
    let onAbort: () -> Void
    let onMicTap: () -> Void
    let buttonSize: CGFloat

    private var isDisabled: Bool {
        switch mode {
        case .transcribing:
            return true
        case .record:
            return micDisabled
        case .send:
            return !canSend
        case .stopAgent, .stopRecording:
            return false
        }
    }

    private var accessibilityLabel: String {
        mode.accessibilityLabel
    }

    var body: some View {
        Button(action: performAction) {
            Group {
                switch mode {
                case .stopAgent, .stopRecording:
                    Image(systemName: "stop.fill")
                        .font(TronTypography.buttonSM)
                        .foregroundStyle(.red)
                case .transcribing:
                    ProgressView()
                        .tint(.tronEmerald)
                        .scaleEffect(0.8)
                case .send:
                    Image(systemName: "arrow.up.circle.fill")
                        .font(TronTypography.button)
                        .foregroundStyle(isDisabled ? Color.tronEmerald.opacity(0.3) : Color.tronEmerald)
                case .record:
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
        .animation(.easeInOut(duration: 0.2), value: mode)
        .animation(.easeInOut(duration: 0.2), value: canSend)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(
            mode.accessibilityHint(
                micDisabled: micDisabled,
                blockedReason: blockedReason
            )
        )
    }

    private func performAction() {
        switch mode {
        case .stopAgent:
            onAbort()
        case .stopRecording, .record:
            onMicTap()
        case .send:
            onSend()
        case .transcribing:
            break
        }
    }

}
