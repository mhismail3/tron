import SwiftUI

struct QueuedMessageEditorRoute: Identifiable, Hashable {
    let id: String
}

enum QueuedMessageManagementAvailability: Equatable, Sendable {
    case available
    case requiresGatewayUpdate
    case invalidProjection

    var isManageable: Bool { self == .available }
}

enum QueuedMessageManagementPolicy {
    static let capability = "queue-management.v1"

    static func availability(
        capabilities: [String],
        queueRevision: Int?,
        hasAuthoritativeItems: Bool
    ) -> QueuedMessageManagementAvailability {
        if queueRevision != nil, hasAuthoritativeItems { return .available }
        return capabilities.contains(capability) ? .invalidProjection : .requiresGatewayUpdate
    }
}

struct QueuedMessageRow: View {
    let message: SessionSnapshot.QueuedMessage
    let position: Int
    let total: Int
    let managementAvailability: QueuedMessageManagementAvailability
    let isMutating: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onClear: () -> Void
    let canMoveEarlier: Bool
    let canMoveLater: Bool
    let onMove: (Int) -> Void

    private var isManageable: Bool { managementAvailability.isManageable }

    private var accent: Color {
        message.behavior == .steer ? .tronEmerald : .tronPurple
    }

    private var title: String {
        message.behavior == .steer ? "Steer next" : "Follow up"
    }

    private var deliveryDetail: String {
        message.behavior == .steer ? "After the current turn" : "After current work"
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            card.fixedSize(horizontal: true, vertical: false)
            card
        }
        .frame(maxWidth: UserPromptTextLayoutPolicy.maximumWidth, alignment: .trailing)
        .contextMenu {
            if isManageable && !isMutating {
                Button("Edit message", systemImage: "pencil", action: onEdit)
                if canMoveEarlier {
                    Button("Move earlier", systemImage: "arrow.up") { onMove(-1) }
                }
                if canMoveLater {
                    Button("Move later", systemImage: "arrow.down") { onMove(1) }
                }
                Button("Remove from queue", systemImage: "trash", role: .destructive, action: onDelete)
                if total > 1 {
                    Button("Clear entire queue", systemImage: "trash.slash", role: .destructive, action: onClear)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: message.behavior == .steer
                    ? "arrow.turn.up.right"
                    : "text.line.last.and.arrowtriangle.forward")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .bold))
                    .foregroundStyle(accent)
                    .frame(width: 28, height: 28)
                    .background(accent.opacity(0.13), in: Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                        .foregroundStyle(Color.tronTextPrimary)
                    Text("\(deliveryDetail) · \(position) of \(total)")
                        .font(TronTypography.caption)
                        .foregroundStyle(Color.tronTextSecondary)
                }
                .fixedSize(horizontal: false, vertical: true)

                managementControls
            }

            if !message.text.isEmpty {
                UserPromptText(text: message.text)
                    .padding(.leading, 38)
            }

            if message.attachmentCount > 0 {
                Label(
                    "\(message.attachmentCount) \(message.attachmentCount == 1 ? "attachment" : "attachments")",
                    systemImage: "paperclip"
                )
                .font(TronTypography.caption)
                .foregroundStyle(Color.tronTextSecondary)
                .padding(.leading, 38)
            }
        }
        .padding(12)
        .background(accent.opacity(0.07), in: shape)
        .overlay(shape.stroke(accent.opacity(0.28), lineWidth: 0.75))
    }

    @ViewBuilder
    private var managementControls: some View {
        if isMutating {
            ProgressView()
                .controlSize(.mini)
                .tint(accent)
                .frame(width: 44, height: 44)
        } else if isManageable {
            HStack(spacing: 2) {
                queueActionButton(
                    icon: "pencil",
                    label: "Edit queued message",
                    color: Color.tronTextSecondary,
                    action: onEdit
                )
                queueActionButton(
                    icon: "trash",
                    label: "Remove from queue",
                    color: Color.tronError,
                    action: onDelete
                )
                if canMoveEarlier || canMoveLater || total > 1 {
                    Menu {
                        if canMoveEarlier {
                            Button("Move earlier", systemImage: "arrow.up") { onMove(-1) }
                        }
                        if canMoveLater {
                            Button("Move later", systemImage: "arrow.down") { onMove(1) }
                        }
                        if total > 1 {
                            Button("Clear entire queue", systemImage: "trash.slash", role: .destructive, action: onClear)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                            .foregroundStyle(Color.tronTextSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .accessibilityLabel("More queued message actions")
                }
            }
        } else {
            Menu {
                Button(readOnlyExplanation, systemImage: "lock") {}
                    .disabled(true)
            } label: {
                Image(systemName: "lock")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(Color.tronTextMuted)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .accessibilityLabel("Queued message is read only")
            .accessibilityHint(readOnlyExplanation)
        }
    }

    private var readOnlyExplanation: String {
        switch managementAvailability {
        case .available:
            ""
        case .requiresGatewayUpdate:
            "Update Tron on Mac to edit or remove queued messages"
        case .invalidProjection:
            "Reconnect to Tron on Mac to restore queue editing"
        }
    }

    private func queueActionButton(
        icon: String,
        label: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct QueuedMessageEditorSheet: View {
    let message: SessionSnapshot.QueuedMessage
    let isSaving: Bool
    let onSave: (String, SessionSnapshot.QueuedMessage.Behavior) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var behavior: SessionSnapshot.QueuedMessage.Behavior

    init(
        message: SessionSnapshot.QueuedMessage,
        isSaving: Bool,
        onSave: @escaping (String, SessionSnapshot.QueuedMessage.Behavior) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.message = message
        self.isSaving = isSaving
        self.onSave = onSave
        self.onDelete = onDelete
        _text = State(initialValue: message.text)
        _behavior = State(initialValue: message.behavior)
    }

    private var canSave: Bool {
        !isSaving
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || message.attachmentCount > 0)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    TronSettingsGroup(
                        "Delivery",
                        detail: behavior == .steer
                            ? "Steering is delivered after the current assistant turn finishes its tool calls."
                            : "Follow-up waits until Tron finishes its current work.",
                        accent: behavior == .steer ? .tronEmerald : .tronPurple
                    ) {
                        HStack(spacing: 10) {
                            deliveryChoice(
                                .steer,
                                title: "Steer next",
                                icon: "arrow.turn.up.right",
                                accent: .tronEmerald
                            )
                            deliveryChoice(
                                .followUp,
                                title: "Follow up",
                                icon: "text.line.last.and.arrowtriangle.forward",
                                accent: .tronPurple
                            )
                        }
                        .padding(12)
                    }

                    TronSettingsGroup("Message", accent: .tronTeal) {
                        VStack(alignment: .leading, spacing: 12) {
                            TextEditor(text: $text)
                                .font(TronTypography.body)
                                .frame(minHeight: 160)
                                .tronTextEditor()
                                .accessibilityLabel("Queued message")

                            if message.attachmentCount > 0 {
                                Label(
                                    "Attachments stay with this queued message.",
                                    systemImage: "paperclip"
                                )
                                .font(TronTypography.caption)
                                .foregroundStyle(Color.tronTextSecondary)
                            }
                        }
                        .padding(12)
                    }

                    Button(role: .destructive) {
                        onDelete()
                        dismiss()
                    } label: {
                        Label("Remove from Queue", systemImage: "trash")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                            .foregroundStyle(Color.tronError)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .contentShape(Rectangle())
                    }
                    .disabled(isSaving)
                    .background(Color.tronError.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.tronError.opacity(0.28), lineWidth: 0.75)
                    }
                }
                .padding(18)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: "Queued Message", accent: behavior == .steer ? .tronEmerald : .tronPurple)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onSave(text, behavior)
                        dismiss()
                    } label: {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "checkmark")
                                .font(TronTypography.buttonSM)
                                .foregroundStyle(behavior == .steer ? Color.tronEmerald : Color.tronPurple)
                        }
                    }
                    .accessibilityLabel("Save queued message")
                    .disabled(!canSave)
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(isSaving)
        .tint(behavior == .steer ? Color.tronEmerald : Color.tronPurple)
    }

    private func deliveryChoice(
        _ value: SessionSnapshot.QueuedMessage.Behavior,
        title: String,
        icon: String,
        accent: Color
    ) -> some View {
        let selected = behavior == value
        return Button {
            behavior = value
        } label: {
            VStack(spacing: 7) {
                Image(systemName: selected ? "checkmark.circle.fill" : icon)
                    .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .semibold))
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(selected ? accent : Color.tronTextSecondary)
            .frame(maxWidth: .infinity, minHeight: 70)
            .contentShape(Rectangle())
        }
        .background(
            (selected ? accent.opacity(0.14) : Color.tronSlate.opacity(0.06)),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(selected ? accent.opacity(0.45) : Color.tronSlate.opacity(0.16), lineWidth: 0.75)
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
