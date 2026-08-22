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

struct QueuedMessageManagementCommit: Equatable, Sendable {
    let expectedRevision: Int
    let items: [SessionSnapshot.QueuedMessage]
}

enum QueuedMessageManagementPolicy {
    static let capability = "queue-management.v1"

    static func availability(
        queueManagementCapability: Bool,
        queueRevision: Int?,
        hasAuthoritativeItems: Bool
    ) -> QueuedMessageManagementAvailability {
        guard queueManagementCapability else { return .requiresGatewayUpdate }
        return queueRevision != nil && hasAuthoritativeItems ? .available : .invalidProjection
    }

    /// Queue mutations must be prepared from one immutable installed commit.
    /// In particular, a capability-only replacement can revoke management
    /// while an editor is still presenting the previous commit.
    static func installedCommit(
        for installed: InstalledChatTranscript?
    ) -> QueuedMessageManagementCommit? {
        guard let installed,
              installed.tag.queueManagementCapability,
              installed.supportsQueueManagement,
              let expectedRevision = installed.queueRevision else { return nil }
        return QueuedMessageManagementCommit(
            expectedRevision: expectedRevision,
            items: installed.queuedMessages
        )
    }

    static func mutationCommit(
        for installed: InstalledChatTranscript?,
        mutation: (inout [SessionSnapshot.QueuedMessage]) throws -> Void
    ) throws -> QueuedMessageManagementCommit? {
        guard let installedCommit = installedCommit(for: installed) else { return nil }
        var items = installedCommit.items
        try mutation(&items)
        return QueuedMessageManagementCommit(
            expectedRevision: installedCommit.expectedRevision,
            items: items
        )
    }
}

struct QueuedMessageAttachmentChip: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable { case photo, file }

    let id: String
    let kind: Kind

    var iconName: String {
        switch kind {
        case .photo: "photo.fill"
        case .file: "doc.fill"
        }
    }
}

enum QueuedMessageAttachmentPresentation {
    static func chips(for message: SessionSnapshot.QueuedMessage) -> [QueuedMessageAttachmentChip] {
        chips(
            attachmentCount: message.attachmentCount,
            photoCount: message.photoCount,
            fileAttachmentCount: message.fileAttachmentCount
        )
    }

    static func chips(for attachments: [PendingAttachment]) -> [QueuedMessageAttachmentChip] {
        // Match the Gateway's bounded typed-count projection exactly: photos
        // precede files, and slot IDs remain stable when the source attachment
        // order differs between optimistic and canonical states.
        let photos = attachments.filter { $0.mimeType.hasPrefix("image/") }
        let files = attachments.filter { !$0.mimeType.hasPrefix("image/") }
        return photos.enumerated().map { index, _ in
            QueuedMessageAttachmentChip(id: "photo-\(index)", kind: .photo)
        } + files.enumerated().map { index, _ in
            QueuedMessageAttachmentChip(id: "file-\(index)", kind: .file)
        }
    }

    static func chips(
        attachmentCount: Int,
        photoCount: Int?,
        fileAttachmentCount: Int?
    ) -> [QueuedMessageAttachmentChip] {
        let typedCountsAvailable = photoCount != nil || fileAttachmentCount != nil
        let photos = max(0, photoCount ?? 0)
        let files = max(0, fileAttachmentCount ?? (typedCountsAvailable ? 0 : attachmentCount))
        return (0..<photos).map { .init(id: "photo-\($0)", kind: .photo) }
            + (0..<files).map { .init(id: "file-\($0)", kind: .file) }
    }

    static func accessibilityLabel(for message: SessionSnapshot.QueuedMessage) -> String {
        accessibilityLabel(chips: chips(for: message))
    }

    static func accessibilityLabel(chips: [QueuedMessageAttachmentChip]) -> String {
        let photos = chips.count { $0.kind == .photo }
        let files = chips.count { $0.kind == .file }
        return [
            photos > 0 ? "\(photos) \(photos == 1 ? "photo" : "photos")" : nil,
            files > 0 ? "\(files) \(files == 1 ? "file" : "files")" : nil,
        ].compactMap(\.self).joined(separator: ", ")
    }
}

enum QueuedMessageCardLayout {
    static let contentSpacing: CGFloat = 6
    static let arrowContainerSize: CGFloat = 24
    static let attachmentChipSize: CGFloat = 22
    static let attachmentChipCornerRadius: CGFloat = 6
}

struct QueuedMessageAttachmentChipRow: View {
    let chips: [QueuedMessageAttachmentChip]
    let accent: Color

    var body: some View {
        ToolChipFlowLayout(spacing: 4) {
            ForEach(chips) { chip in
                Image(systemName: chip.iconName)
                    .font(TronTypography.sans(size: 9, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(
                        width: QueuedMessageCardLayout.attachmentChipSize,
                        height: QueuedMessageCardLayout.attachmentChipSize
                    )
                    .background(
                        accent.opacity(0.13),
                        in: RoundedRectangle(
                            cornerRadius: QueuedMessageCardLayout.attachmentChipCornerRadius,
                            style: .continuous
                        )
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(QueuedMessageAttachmentPresentation.accessibilityLabel(chips: chips))
    }
}

struct QueuedMessageRow: View {
    let message: SessionSnapshot.QueuedMessage
    let position: Int
    let total: Int
    let managementAvailability: QueuedMessageManagementAvailability
    let isMutating: Bool
    let onEdit: () -> Void
    let onClear: () -> Void
    let canMoveEarlier: Bool
    let canMoveLater: Bool
    let onMove: (Int) -> Void

    private var isManageable: Bool { managementAvailability.isManageable }

    private var behavior: ChatPromptBehavior { ChatPromptBehavior(message.behavior) }

    private var accent: Color {
        behavior == .steer ? .tronEmerald : .tronPurple
    }

    private var deliveryDetail: String {
        behavior == .steer ? "After the current turn" : "After current work"
    }

    var body: some View {
        // Queue cards use the same single bounded layout as prompt bubbles;
        // switching between intrinsic and wrapped ViewThatFits branches after
        // a large queued prompt arrives causes a visible container flash.
        interactiveCard(
            card.fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: UserPromptTextLayoutPolicy.maximumWidth, alignment: .trailing)
        )
        .contextMenu {
            if isManageable && !isMutating {
                if canMoveEarlier {
                    Button("Move earlier", systemImage: "arrow.up") { onMove(-1) }
                }
                if canMoveLater {
                    Button("Move later", systemImage: "arrow.down") { onMove(1) }
                }
                if total > 1 {
                    Button("Clear entire queue", systemImage: "trash.slash", role: .destructive, action: onClear)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
    }

    private var card: some View {
        let attachmentChips = QueuedMessageAttachmentPresentation.chips(for: message)
        return ChatPromptCard(
            behavior: behavior,
            text: message.text,
            detail: "\(deliveryDetail) · \(position) of \(total)",
            isInteractive: isManageable,
            attachmentContent: {
                if !attachmentChips.isEmpty {
                    QueuedMessageAttachmentChipRow(chips: attachmentChips, accent: accent)
                }
            },
            statusContent: { trailingStatus }
        )
    }

    @ViewBuilder
    private func interactiveCard<Content: View>(_ content: Content) -> some View {
        if isManageable {
            Button(action: onEdit) { content }
                .buttonStyle(.plain)
                .disabled(isMutating)
                .accessibilityHint("Opens the queued message editor")
        } else {
            content
                .accessibilityHint(readOnlyExplanation)
        }
    }

    @ViewBuilder
    private var trailingStatus: some View {
        if isMutating {
            ProgressView()
                .controlSize(.mini)
                .tint(accent)
                .frame(width: 28, height: 28)
        } else if !isManageable {
            Image(systemName: "lock")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(Color.tronTextMuted)
                .frame(width: 28, height: 28)
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

                }
                .padding(18)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .destructive) {
                        onDelete()
                        dismiss()
                    } label: {
                        Image(systemName: "trash")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronError)
                    }
                    .accessibilityLabel("Remove queued message")
                    .disabled(isSaving)
                }
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
