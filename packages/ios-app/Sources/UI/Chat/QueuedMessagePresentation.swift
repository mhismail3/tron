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

/// One-shot suspension point for projection installers that encounter the one
/// locally admitted queue mutation. Every waiter is resumed on command outcome
/// or lifecycle retirement; cancellation removes only that caller's waiter.
@MainActor
final class ChatQueueMutationResolutionOwner {
    typealias Token = UInt64

    enum Resolution: Equatable, Sendable {
        case commandCompleted
        case retired
    }

    enum WaitError: Error, Equatable {
        case waiterLimitReached
    }

    private struct Waiter {
        let id: UInt64
        let token: Token
        let continuation: CheckedContinuation<Resolution, Error>
    }

    static let maximumWaiters = 32

    private(set) var activeToken: Token?
    private(set) var waiterCount = 0
    private var nextToken: Token = 0
    private var nextWaiterID: UInt64 = 0
    private var waiters: [Waiter] = []

    func begin() -> Token? {
        guard activeToken == nil else { return nil }
        nextToken &+= 1
        activeToken = nextToken
        return nextToken
    }

    func isActive(_ token: Token) -> Bool {
        activeToken == token
    }

    func wait(for token: Token) async throws -> Resolution {
        guard activeToken == token else { return .retired }
        nextWaiterID &+= 1
        let waiterID = nextWaiterID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard activeToken == token else {
                    continuation.resume(returning: .retired)
                    return
                }
                if waiters.count >= Self.maximumWaiters {
                    continuation.resume(throwing: WaitError.waiterLimitReached)
                    return
                }
                waiters.append(.init(id: waiterID, token: token, continuation: continuation))
                waiterCount = waiters.count
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(id: waiterID)
            }
        }
    }

    @discardableResult
    func resolve(_ token: Token, as resolution: Resolution) -> Bool {
        guard activeToken == token else { return false }
        activeToken = nil
        let pending = waiters.filter { $0.token == token }
        waiters.removeAll { $0.token == token }
        waiterCount = waiters.count
        for waiter in pending {
            waiter.continuation.resume(returning: resolution)
        }
        return true
    }

    func retire() {
        guard let activeToken else { return }
        _ = resolve(activeToken, as: .retired)
    }

    private func cancelWaiter(id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiterCount = waiters.count
        waiter.continuation.resume(throwing: CancellationError())
    }
}

enum ChatQueueMutationProjectionPolicy {
    enum Outcome: Equatable, Sendable {
        case success
        case failure
    }

    /// Defers only evidence whose suppression meaning depends on the unresolved
    /// local command. Ordinary transcript streaming continues to install.
    static func shouldDefer(
        affectedOperationIDs: Set<String>,
        receiptOperationID: String?,
        fallbackHandoffWithoutExclusions: String?,
        fallbackHandoffWithExclusions: String?
    ) -> Bool {
        guard !affectedOperationIDs.isEmpty else { return false }
        if let receiptOperationID,
           affectedOperationIDs.contains(receiptOperationID) {
            return true
        }
        return fallbackHandoffWithoutExclusions != nil
            && fallbackHandoffWithExclusions == nil
    }

    /// A successful local edit/removal retires the affected lineage. Failure
    /// restores the pre-command settlement interpretation of the deferred fact.
    static func exclusions(
        for outcome: Outcome,
        affectedOperationIDs: Set<String>
    ) -> Set<String> {
        outcome == .success ? affectedOperationIDs : []
    }

    /// Newer queue authority retires mutation controls only after the command
    /// outcome is known. A frame racing ahead of the response cannot discard
    /// the lineage exclusions needed to interpret that response correctly.
    static func shouldRetirePresentationState(
        commandIsPending: Bool,
        expectedRevision: Int?,
        installedRevision: Int?
    ) -> Bool {
        guard !commandIsPending,
              let expectedRevision,
              let installedRevision else { return false }
        return installedRevision > expectedRevision
    }
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

    /// Returns only operations whose content/behavior changed or whose row was
    /// removed. Pure reordering preserves causal settlement lineage.
    static func changedOperationIDs(
        from previous: [SessionSnapshot.QueuedMessage],
        to next: [SessionSnapshot.QueuedMessage]
    ) -> Set<String> {
        guard Set(previous.map(\.id)).count == previous.count,
              Set(next.map(\.id)).count == next.count else {
            return Set(previous.map(\.id))
        }
        let nextByID = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) })
        return Set(previous.compactMap { item in
            nextByID[item.id] == item ? nil : item.id
        })
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
