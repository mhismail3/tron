import SwiftUI
import TronMobileCore

struct ChatPendingAttachmentStrip: View {
    let attachments: [PendingAttachment]
    let reduceMotion: Bool
    let submissionTransitionActive: Bool
    let onRemove: (String) -> Void

    @State private var presentedAttachments: [PendingAttachment]
    @State private var reconciliationTask: Task<Void, Never>?

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

        if submissionTransitionActive {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { presentedAttachments = target }
            return
        }

        if reduceMotion {
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
