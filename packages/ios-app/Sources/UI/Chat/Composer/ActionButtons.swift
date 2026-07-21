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
            .contentShape(Circle())
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

// MARK: - Trailing Composer Action

enum ComposerTrailingMode: Equatable {
    case stopAgent
    case send

    init(showStop: Bool) {
        self = showStop ? .stopAgent : .send
    }

    var accessibilityLabel: String {
        switch self {
        case .stopAgent: return "Stop agent"
        case .send: return "Send message"
        }
    }
}

struct ComposerTrailingButton: View {
    let showStop: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onAbort: () -> Void
    let buttonSize: CGFloat

    private var mode: ComposerTrailingMode {
        ComposerTrailingMode(showStop: showStop)
    }

    private var isDisabled: Bool {
        mode == .send && !canSend
    }

    private var accessibilityLabel: String {
        mode.accessibilityLabel
    }

    var body: some View {
        Button(action: performAction) {
            Group {
                switch mode {
                case .stopAgent:
                    Image(systemName: "stop.fill")
                        .font(TronTypography.buttonSM)
                        .foregroundStyle(.red)
                case .send:
                    Image(systemName: "arrow.up.circle.fill")
                        .font(TronTypography.button)
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
        .accessibilityLabel(accessibilityLabel)
    }

    private func performAction() {
        switch mode {
        case .stopAgent:
            onAbort()
        case .send:
            onSend()
        }
    }

}
