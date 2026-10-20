import SwiftUI
import TronMobileCore

struct ChatPendingAttachmentStrip: View {
    let attachments: [PendingAttachment]
    let reduceMotion: Bool
    let submissionTransitionActive: Bool
    let onRemove: (String) -> Void

    @State private var presentedAttachments: [PendingAttachment]
    @State private var reconciliationTask: Task<Void, Never>?
    /// Every chip this strip has shown: a rejected send's restored chips slide
    /// back in without ticking, as do drafts restored on open.
    @State private var shownAttachmentIDs: Set<String>

    init(
        attachments: [PendingAttachment],
        reduceMotion: Bool,
        submissionTransitionActive: Bool,
        onRemove: @escaping (String) -> Void
    ) {
        self.attachments = attachments
        self.reduceMotion = reduceMotion
        self.submissionTransitionActive = submissionTransitionActive
        self.onRemove = onRemove
        _presentedAttachments = State(initialValue: attachments)
        _shownAttachmentIDs = State(initialValue: Set(attachments.map(\.id)))
    }

    var body: some View {
        // Keep the collection mounted across zero ↔ one. Scaling a newly
        // inserted full-width scroll view pulls its leading chip toward the
        // screen center; only each chip's own center may own that transform.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(presentedAttachments) { attachment in
                    PendingAttachmentChip(attachment: attachment) {
                        onRemove(attachment.id)
                    }
                    .transition(ChatContentTransitionPolicy.attachmentTransition(
                        reduceMotion: reduceMotion
                    ))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
            .chatSecondaryScrollContent()
        }
        .scrollClipDisabled()
        .frame(height: presentedAttachments.isEmpty ? 0 : nil, alignment: .top)
        .padding(.bottom, presentedAttachments.isEmpty ? 0 : 10)
        .onChange(of: attachments) { _, target in
            reconcile(to: target)
        }
        .onDisappear {
            reconciliationTask?.cancel()
            reconciliationTask = nil
        }
    }

    private func reconcile(to target: [PendingAttachment]) {
        reconciliationTask?.cancel()
        reconciliationTask = nil

        // `ComposerDraftCoordinator` mints `local:` IDs for this device's own
        // picks, pastes, captures and files, `restored-` IDs for saved drafts.
        let newlyImported = target.filter { $0.id.hasPrefix("local:") && !shownAttachmentIDs.contains($0.id) }.count
        shownAttachmentIDs.formUnion(target.map(\.id))

        if submissionTransitionActive {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { presentedAttachments = target }
            return
        }

        if reduceMotion {
            // Without the cascade every chip fades in at once: one tick.
            if newlyImported > 0 { TronHaptics.shared.play(.attachmentAdded) }
            withAnimation(ChatMotion.attachmentArrive(reduceMotion: true)) {
                presentedAttachments = target
            }
            return
        }

        let targetIDs = Set(target.map(\.id))
        let targetByID = Dictionary(uniqueKeysWithValues: target.map { ($0.id, $0) })
        for index in presentedAttachments.indices {
            if let updated = targetByID[presentedAttachments[index].id] {
                presentedAttachments[index] = updated
            }
        }

        let insertionIDs = ChatContentTransitionPolicy.attachmentInsertionIDs(
            current: presentedAttachments.map(\.id),
            target: target.map(\.id)
        )
        let animation = ChatMotion.attachmentArrive(reduceMotion: false)
        withAnimation(animation) {
            presentedAttachments.removeAll { !targetIDs.contains($0.id) }
            if insertionIDs.isEmpty {
                presentedAttachments = target
            }
        }

        guard !insertionIDs.isEmpty else { return }
        // One tick per new chip as the cascade begins, capped and spaced.
        if newlyImported > 0 { TronHaptics.shared.playCascade(.attachmentAdded, count: newlyImported) }
        reconciliationTask = Task { @MainActor in
            for (rank, id) in insertionIDs.enumerated() {
                if rank > 0 {
                    try? await Task.sleep(for: .seconds(
                        ChatContentTransitionPolicy.attachmentStaggerInterval
                    ))
                }
                guard !Task.isCancelled,
                      let attachment = targetByID[id],
                      !presentedAttachments.contains(where: { $0.id == id }) else { continue }
                let targetIndex = target.firstIndex(where: { $0.id == id }) ?? target.endIndex
                let precedingIDs = Set(target[..<targetIndex].map(\.id))
                let insertionIndex = presentedAttachments.prefix {
                    precedingIDs.contains($0.id)
                }.count
                withAnimation(animation) {
                    presentedAttachments.insert(
                        attachment,
                        at: min(insertionIndex, presentedAttachments.endIndex)
                    )
                }
            }
            guard !Task.isCancelled else { return }
            withAnimation(animation) { presentedAttachments = target }
            reconciliationTask = nil
        }
    }
}
